import Foundation

struct DeviceEndpoint: Sendable, Equatable {
    let host: String
    let port: Int
    let serviceIdentifier: String
    let authTag: String
}

@MainActor
final class DeviceDiscovery: NSObject, @preconcurrency NetServiceDelegate,
                             @preconcurrency NetServiceBrowserDelegate {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private var publication: NetService?
    private var publicationID: UUID?
    private var publicationWaiter: CheckedContinuation<Void, Error>?
    private var publicationTimeout: Task<Void, Never>?

    private var browser: NetServiceBrowser?
    private var discoveryID: UUID?
    private var discoveryWaiter: CheckedContinuation<DeviceEndpoint, Error>?
    private var discoveryTimeout: Task<Void, Never>?
    private var services: [ObjectIdentifier: NetService] = [:]
    private var matchTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var matcher: (@Sendable (DeviceEndpoint) async throws -> Bool)?

    func publishPairing(name: String, port: Int, txt: [String: String]) async throws {
        try Task.checkCancellation()
        stopPublishing()
        guard (1...65535).contains(port), !name.isEmpty else {
            throw Failure(message: "本机配对服务返回了无效的连接信息。")
        }
        let id = UUID()
        publicationID = id
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                publicationWaiter = continuation
                let service = NetService(domain: "local.",
                                         type: "_remotepairing-pairable-host._tcp.",
                                         name: name, port: Int32(port))
                publication = service
                service.delegate = self
                service.schedule(in: .main, forMode: .common)
                let data = NetService.data(fromTXTRecord: txt.mapValues { Data($0.utf8) })
                guard service.setTXTRecord(data) else {
                    finishPublication(.failure(Failure(message: "无法发布本机配对信息，请重试。")))
                    return
                }
                publicationTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    guard let self, self.publicationID == id else { return }
                    self.finishPublication(.failure(Failure(message: "发布配对服务超时。请允许本地网络访问后重试。")))
                }
                service.publish(options: .noAutoRename)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.publicationID == id else { return }
                self?.stopPublishing()
            }
        }
    }

    func stopPublishing() {
        publicationTimeout?.cancel()
        publicationTimeout = nil
        publication?.delegate = nil
        publication?.stop()
        publication?.remove(from: .main, forMode: .common)
        publication = nil
        publicationID = nil
        let waiter = publicationWaiter
        publicationWaiter = nil
        waiter?.resume(throwing: CancellationError())
    }

    func resolvePairedDevice(
        matching: @escaping @Sendable (DeviceEndpoint) async throws -> Bool
    ) async throws -> DeviceEndpoint {
        try Task.checkCancellation()
        cancelDiscovery()
        let id = UUID()
        discoveryID = id
        matcher = matching
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                discoveryWaiter = continuation
                let newBrowser = NetServiceBrowser()
                browser = newBrowser
                newBrowser.delegate = self
                newBrowser.schedule(in: .main, forMode: .common)
                discoveryTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    guard let self, self.discoveryID == id else { return }
                    self.finishDiscovery(.failure(Failure(message: "未发现这台已配对的 iPhone。请连接 Wi-Fi、开启 LocalDevVPN，并允许本地网络访问后重试。")))
                }
                newBrowser.searchForServices(ofType: "_remotepairing._tcp.", inDomain: "local.")
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.discoveryID == id else { return }
                self?.cancelDiscovery()
            }
        }
    }

    func cancelDiscovery() {
        finishDiscovery(.failure(CancellationError()))
    }

    private func finishPublication(_ result: Result<Void, Error>) {
        publicationTimeout?.cancel()
        publicationTimeout = nil
        let waiter = publicationWaiter
        publicationWaiter = nil
        if case .failure = result { stopPublishing() }
        waiter?.resume(with: result)
    }

    private func finishDiscovery(_ result: Result<DeviceEndpoint, Error>) {
        discoveryTimeout?.cancel()
        discoveryTimeout = nil
        browser?.delegate = nil
        browser?.stop()
        browser?.remove(from: .main, forMode: .common)
        browser = nil
        for service in services.values {
            service.delegate = nil
            service.stop()
            service.remove(from: .main, forMode: .common)
        }
        services.removeAll()
        matchTasks.values.forEach { $0.cancel() }
        matchTasks.removeAll()
        matcher = nil
        discoveryID = nil
        let waiter = discoveryWaiter
        discoveryWaiter = nil
        waiter?.resume(with: result)
    }

    private func evaluate(_ service: NetService) {
        let key = ObjectIdentifier(service)
        guard services[key] != nil, matchTasks[key] == nil,
              let id = discoveryID, let matcher,
              (1...65535).contains(service.port), let data = service.txtRecordData() else { return }
        let txt = NetService.dictionary(fromTXTRecord: data)
        guard let identifierData = txt["identifier"], let tagData = txt["authTag"],
              let identifier = String(data: identifierData, encoding: .utf8),
              let authTag = String(data: tagData, encoding: .utf8),
              !identifier.isEmpty, !authTag.isEmpty else { return }

        // LocalDevVPN maps this address to the phone itself. Bonjour supplies the
        // rotating port; the native engine authenticates its TXT identity twice.
        let endpoint = DeviceEndpoint(host: "10.7.0.1", port: service.port,
                                      serviceIdentifier: identifier, authTag: authTag)
        matchTasks[key] = Task { [weak self] in
            do {
                let matched = try await matcher(endpoint)
                guard !Task.isCancelled, let self, self.discoveryID == id,
                      self.services[key] === service else { return }
                if matched {
                    self.finishDiscovery(.success(endpoint))
                } else {
                    self.matchTasks.removeValue(forKey: key)
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.discoveryID == id else { return }
                self.finishDiscovery(.failure(error))
            }
        }
    }

    func netServiceDidPublish(_ sender: NetService) {
        guard sender === publication else { return }
        finishPublication(.success(()))
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        guard sender === publication else { return }
        finishPublication(.failure(Failure(message: "无法发布配对服务。请允许本地网络访问，并结束其他配对操作后重试。")))
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService,
                           moreComing: Bool) {
        guard browser === self.browser else { return }
        let key = ObjectIdentifier(service)
        services[key] = service
        service.delegate = self
        service.schedule(in: .main, forMode: .common)
        service.resolve(withTimeout: 8)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService,
                           moreComing: Bool) {
        guard browser === self.browser else { return }
        let key = ObjectIdentifier(service)
        matchTasks.removeValue(forKey: key)?.cancel()
        services.removeValue(forKey: key)?.stop()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        guard browser === self.browser else { return }
        finishDiscovery(.failure(Failure(message: "无法搜索本机服务。请在系统设置中允许本地网络访问。")))
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        evaluate(sender)
    }

    func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
        evaluate(sender)
    }
}
