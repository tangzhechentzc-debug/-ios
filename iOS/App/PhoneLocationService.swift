import CoreLocation
import Foundation

@MainActor
final class PhoneLocationService: PhoneLocationServing {
    private let engine: any EngineRequesting
    private let discovery = DeviceDiscovery()
    private let vault = PairingVault()

    init(engine: any EngineRequesting = NativeEngine()) { self.engine = engine }

    func hasPairing() throws -> Bool { try vault.read() != nil }

    func startPairing() async throws {
        #if targetEnvironment(simulator)
        throw LocationFailure(message: "本机配对需要实体 iPhone；模拟器仅用于界面检查。")
        #else
        let reply = try await engine.send(EngineRequest(op: "pair_start"))
        guard let name = reply.serviceName, let port = reply.port, let txt = reply.txt else {
            throw LocationFailure(message: "配对服务未返回有效的发现信息。")
        }
        do {
            try await discovery.publishPairing(name: name, port: port, txt: txt)
        } catch {
            _ = try? await engine.send(EngineRequest(op: "pair_cancel"))
            throw error
        }
        #endif
    }

    func pairingProgress() async throws -> PairingProgress {
        let reply = try await engine.send(EngineRequest(op: "pair_status"))
        if reply.pairingState == "complete" {
            guard let record = reply.pairingRecord else {
                throw LocationFailure(message: "配对没有返回可保存的记录，请重新配对。")
            }
            try vault.save(record)
            discovery.stopPublishing()
            _ = try? await engine.send(EngineRequest(op: "pair_cancel"))
        }
        return PairingProgress(state: reply.pairingState ?? "waiting", code: reply.pairingCode,
                               message: reply.message)
    }

    func cancelPairing() async {
        discovery.stopPublishing()
        _ = try? await engine.send(EngineRequest(op: "pair_cancel"))
    }

    func connect(recoveryNeeded: Bool) async throws {
        guard let record = try vault.read() else {
            throw LocationFailure(message: "请先在连接页面完成本机配对。")
        }
        let engine = self.engine
        let endpoint = try await discovery.resolvePairedDevice { endpoint in
            var request = EngineRequest(op: "match_service")
            request.pairingRecord = record
            request.serviceIdentifier = endpoint.serviceIdentifier
            request.authTag = endpoint.authTag
            return try await engine.send(request).matched == true
        }
        var request = EngineRequest(op: "connect")
        request.pairingRecord = record
        request.host = endpoint.host
        request.port = endpoint.port
        request.serviceIdentifier = endpoint.serviceIdentifier
        request.authTag = endpoint.authTag
        request.recoveryNeeded = recoveryNeeded
        _ = try await engine.send(request)
    }

    func apply(_ coordinate: CLLocationCoordinate2D) async throws {
        var request = EngineRequest(op: "apply")
        request.latitude = coordinate.latitude
        request.longitude = coordinate.longitude
        _ = try await engine.send(request)
    }

    func clear() async throws { _ = try await engine.send(EngineRequest(op: "clear")) }

    func confirmRestore() async throws { _ = try await engine.send(EngineRequest(op: "confirm_restore")) }

    func status() async throws -> String {
        try await engine.send(EngineRequest(op: "status")).state ?? "unknown"
    }
}
