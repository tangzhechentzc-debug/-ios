import CoreLocation
import MapKit
import Observation
import SwiftUI
import UserNotifications

enum SimulationPhase: String {
    case idle, active, unknown, awaitingRestore
}

@MainActor @Observable
final class PhoneLocationModel {
    var latitudeText = ""
    var longitudeText = ""
    var inputSystem: CoordinateSystem = .wgs84
    var selected: CLLocationCoordinate2D?
    var camera: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737),
        latitudinalMeters: 20_000, longitudinalMeters: 20_000))
    var query = ""
    var searchResults: [MKMapItem] = []
    var searching = false
    var searchError: String?
    var busy = false
    var hasPairing = false
    var connectionReady = false
    var connectionText = "尚未检查定位服务"
    var phase: SimulationPhase = .idle
    var status = "选择地点后开始模拟"
    var error: String?
    var pairing = false
    var pairingCode: String?
    var pairingMessage = "通过系统开发者模式与这台 iPhone 配对。"

    @ObservationIgnored private let service: any PhoneLocationServing
    @ObservationIgnored private let activity: any SessionKeeping
    @ObservationIgnored private let journal: RecoveryJournal
    @ObservationIgnored private var pairingTask: Task<Void, Never>?
    @ObservationIgnored private var search: MKLocalSearch?

    init(service: any PhoneLocationServing, activity: any SessionKeeping, journal: RecoveryJournal) {
        self.service = service
        self.activity = activity
        self.journal = journal
        if journal.needsRecovery {
            phase = .unknown
            status = "上次会话未确认停止，请先连接并停止模拟"
        }
        do { hasPairing = try service.hasPairing() }
        catch { self.error = error.localizedDescription }
    }

    var needsRecovery: Bool { phase != .idle || journal.needsRecovery }
    var canApply: Bool { !busy && !pairing && hasPairing && (phase == .idle || phase == .active) && parsedCoordinate != nil }
    var canStop: Bool { !busy && !pairing && hasPairing }

    var parsedCoordinate: CLLocationCoordinate2D? {
        guard let latitude = Double(latitudeText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let longitude = Double(longitudeText.trimmingCharacters(in: .whitespacesAndNewlines)),
              latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        let point = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return inputSystem == .gcj02 ? Coordinates.gcjToWGS(point) : point
    }

    func select(_ coordinate: CLLocationCoordinate2D, recenter: Bool = false) {
        selected = coordinate
        let display = inputSystem == .gcj02 ? Coordinates.wgsToGCJ(coordinate) : coordinate
        latitudeText = String(format: "%.7f", locale: Locale(identifier: "en_US_POSIX"), display.latitude)
        longitudeText = String(format: "%.7f", locale: Locale(identifier: "en_US_POSIX"), display.longitude)
        if recenter {
            camera = .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 4_000, longitudinalMeters: 4_000))
        }
    }

    func showInput() {
        guard let point = parsedCoordinate else {
            error = "请输入有效经纬度：纬度 −90～90，经度 −180～180。"
            return
        }
        error = nil
        select(point, recenter: true)
    }

    func searchPlaces() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        search?.cancel()
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        if let selected {
            request.region = MKCoordinateRegion(center: selected, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
        }
        let current = MKLocalSearch(request: request)
        search = current
        searching = true
        searchError = nil
        do {
            let result = try await current.start()
            guard search === current else { return }
            searchResults = result.mapItems
            if searchResults.isEmpty { searchError = "未找到地点，请补充城市或街道名称。" }
        } catch {
            guard search === current else { return }
            searchResults = []
            searchError = "搜索失败，请检查网络或直接输入坐标。"
        }
        if search === current { searching = false }
    }

    func checkConnection() async {
        guard !busy, !pairing, hasPairing, !needsRecovery else { return }
        busy = true
        error = nil
        connectionReady = false
        connectionText = "正在查找本机并检查定位服务…"
        defer { busy = false }
        do {
            try await service.connect(recoveryNeeded: needsRecovery)
            connectionReady = true
            connectionText = "定位服务已连接"
        } catch {
            connectionText = "连接检查失败"
            self.error = error.localizedDescription
            if needsRecovery { markUnknown() }
        }
    }

    func apply() async {
        guard canApply, let coordinate = parsedCoordinate else { return }
        select(coordinate)
        busy = true
        error = nil
        status = "正在连接并发送位置…"
        defer { busy = false }
        do {
            try await activity.start()
            if !connectionReady {
                try await service.connect(recoveryNeeded: needsRecovery)
                connectionReady = true
                connectionText = "定位服务已连接"
            }
            try journal.markBeforeSending()
            phase = .unknown
            try await service.apply(coordinate)
            phase = .active
            status = "正在模拟，请到 Apple 地图检查当前位置蓝点"
        } catch {
            connectionReady = false
            self.error = error.localizedDescription
            if journal.needsRecovery { markUnknown() }
            else {
                phase = .idle
                status = "未能启动模拟"
                activity.stop()
            }
        }
    }

    func stop() async {
        guard canStop else { return }
        busy = true
        error = nil
        status = "正在停止模拟…"
        defer { busy = false }
        do {
            try journal.markBeforeSending()
            if !connectionReady {
                try await service.connect(recoveryNeeded: true)
                connectionReady = true
            }
            try await service.clear()
            connectionReady = false
            connectionText = "停止请求已发送，定位会话已关闭"
            phase = .awaitingRestore
            status = "请在 Apple 地图核对当前位置蓝点。真实位置恢复后点“已确认恢复”；未恢复可再次停止。"
            activity.stop()
        } catch {
            connectionReady = false
            markUnknown()
            self.error = error.localizedDescription
        }
    }

    func confirmRestore() async {
        guard !busy, !pairing, phase == .awaitingRestore else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await service.confirmRestore()
            try journal.clearAfterRestorationConfirmation()
            phase = .idle
            status = "已记录你确认的真实位置恢复结果"
        } catch {
            self.error = error.localizedDescription
        }
    }

    func foregrounded() async {
        guard !busy, !pairing, phase == .active else { return }
        do {
            if try await service.status() != "active" { markUnknown() }
        } catch { markUnknown() }
    }

    func backgrounded() {
        if phase == .idle {
            connectionReady = false
            connectionText = "返回后需重新检查定位服务"
        }
    }

    func markUnknown() {
        guard needsRecovery else { return }
        phase = .unknown
        connectionReady = false
        status = "会话状态未知，请保持隧道连接并点击停止模拟"
    }

    func startPairing() async {
        guard !busy, !pairing, !needsRecovery else { return }
        busy = true
        connectionReady = false
        connectionText = "配对流程结束后需重新检查定位服务"
        error = nil
        pairingCode = nil
        pairingMessage = "正在启动本机配对…"
        defer { busy = false }
        do {
            try await activity.start()
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            try await service.startPairing()
            pairing = true
            pairingMessage = "打开设置 → 隐私与安全性 → 开发者模式，选择 ChangeLocation。"
            pairingTask = Task { [weak self] in
                guard let self else { return }
                do {
                    while !Task.isCancelled {
                        let update = try await self.service.pairingProgress()
                        if let code = update.code, code != self.pairingCode {
                            self.pairingCode = code
                            self.pairingMessage = "在系统配对页面输入下方配对码。它与手机解锁密码不同。"
                            let content = UNMutableNotificationContent()
                            content.title = "定位助手配对码"
                            content.body = code
                            content.sound = .default
                            try? await UNUserNotificationCenter.current().add(
                                UNNotificationRequest(identifier: "device-pairing-code", content: content, trigger: nil))
                        }
                        if update.state == "complete" {
                            self.hasPairing = true
                            self.connectionReady = false
                            self.pairingMessage = "配对已保存至本机钥匙串。请连接 LocalDevVPN，再检查定位服务。"
                            self.finishPairing()
                            return
                        }
                        if update.state == "failed" {
                            throw LocationFailure(message: update.message ?? "配对未完成，请重试。")
                        }
                        try await Task.sleep(for: .milliseconds(500))
                    }
                } catch is CancellationError {
                    return
                } catch {
                    self.error = error.localizedDescription
                    await self.service.cancelPairing()
                    self.finishPairing()
                }
            }
        } catch {
            self.error = error.localizedDescription
            activity.stop()
        }
    }

    func cancelPairing() async {
        pairingTask?.cancel()
        await service.cancelPairing()
        pairingMessage = "配对已取消，可以重新开始。"
        finishPairing()
    }

    private func finishPairing() {
        pairing = false
        pairingCode = nil
        activity.stop()
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["device-pairing-code"])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["device-pairing-code"])
    }
}
