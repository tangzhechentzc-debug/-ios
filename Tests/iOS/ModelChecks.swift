import CoreLocation
import Foundation

@MainActor
private final class FakePhoneService: PhoneLocationServing {
    var connectFails = false
    var applyFails = false
    var clearFails = false
    var confirmFails = false
    var reportedState = "active"
    var applyCount = 0
    var recoveryRequested = false
    var beforeApply: (() throws -> Void)?
    func hasPairing() throws -> Bool { true }
    func startPairing() async throws {}
    func pairingProgress() async throws -> PairingProgress { PairingProgress(state: "waiting", code: nil, message: nil) }
    func cancelPairing() async {}
    func connect(recoveryNeeded: Bool) async throws {
        recoveryRequested = recoveryNeeded
        if connectFails { throw LocationFailure(message: "test connection failed") }
    }
    func apply(_ coordinate: CLLocationCoordinate2D) async throws {
        applyCount += 1
        try beforeApply?()
        if applyFails { throw LocationFailure(message: "test apply failed") }
    }
    func clear() async throws {
        if clearFails { throw LocationFailure(message: "test clear failed") }
    }
    func confirmRestore() async throws {
        if confirmFails { throw LocationFailure(message: "test confirmation failed") }
    }
    func status() async throws -> String { reportedState }
}

@MainActor
private final class FakeActivity: SessionKeeping {
    var stopped = false
    var startFails = false
    func start() async throws {
        if startFails { throw LocationFailure(message: "test permission unavailable") }
        stopped = false
    }
    func stop() { stopped = true }
}

@main
private struct ModelChecks {
    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var count = 0

        func expect(_ condition: Bool, _ description: String) throws {
            guard condition else { throw LocationFailure(message: "FAIL: " + description) }
            count += 1
            print("PASS: " + description)
        }
        func make(_ name: String) -> (PhoneLocationModel, FakePhoneService, FakeActivity, RecoveryJournal) {
            let journal = RecoveryJournal(url: directory.appendingPathComponent(name))
            let service = FakePhoneService()
            let activity = FakeActivity()
            let model = PhoneLocationModel(service: service, activity: activity, journal: journal)
            model.latitudeText = "31.230400"
            model.longitudeText = "121.473700"
            return (model, service, activity, journal)
        }

        let (model, service, activity, journal) = make("apply")
        var markerPresentAtSend = false
        service.beforeApply = { markerPresentAtSend = journal.needsRecovery && model.phase == .unknown }
        await model.apply()
        try expect(markerPresentAtSend && model.phase == .active, "recovery marker exists before position is sent")
        service.applyFails = true
        await model.apply()
        try expect(model.phase == .unknown && journal.needsRecovery && !model.canApply,
                   "failed update preserves recovery obligation and blocks new simulation")
        service.clearFails = true
        await model.stop()
        try expect(model.phase == .unknown && journal.needsRecovery && service.recoveryRequested,
                   "failed reconnect/clear retains recovery marker")
        service.clearFails = false
        await model.stop()
        try expect(model.phase == .awaitingRestore && journal.needsRecovery && activity.stopped,
                   "stop delivery keeps recovery marker until real-position confirmation")
        try expect(model.canStop && !model.canApply && !model.connectionReady,
                   "unverified stop can be retried but cannot start a new simulation")
        service.confirmFails = true
        await model.confirmRestore()
        try expect(model.phase == .awaitingRestore && journal.needsRecovery,
                   "failed restoration confirmation retains recovery obligation")
        service.confirmFails = false
        await model.confirmRestore()
        try expect(model.phase == .idle && !journal.needsRecovery,
                   "explicit restoration confirmation clears recovery marker")

        let (firstFailure, failedService, _, failedJournal) = make("first-failure")
        failedService.applyFails = true
        await firstFailure.apply()
        try expect(firstFailure.phase == .unknown && failedJournal.needsRecovery,
                   "uncertain first set is recoverable after a crash")
        let reopened = PhoneLocationModel(service: failedService, activity: FakeActivity(), journal: failedJournal)
        try expect(reopened.phase == .unknown && reopened.canStop && !reopened.canApply,
                   "relaunch does not misreport prior simulation as stopped")

        let (noConnection, disconnected, noActivity, emptyJournal) = make("connect-failure")
        disconnected.connectFails = true
        await noConnection.apply()
        try expect(disconnected.applyCount == 0 && !emptyJournal.needsRecovery && noActivity.stopped,
                   "failed initial connection sends no position and leaves no false recovery marker")

        let (interrupted, interruptedService, _, interruptedJournal) = make("interrupted")
        await interrupted.apply()
        interruptedService.reportedState = "unknown"
        await interrupted.foregrounded()
        try expect(interrupted.phase == .unknown && interruptedJournal.needsRecovery,
                   "native session failure invalidates active UI state")

        let (invalid, invalidService, _, _) = make("invalid")
        for value in ["nan", "inf", "91", "-91", ""] {
            invalid.latitudeText = value
            await invalid.apply()
        }
        try expect(invalidService.applyCount == 0, "invalid latitude cannot reach native engine")
        invalid.latitudeText = "31.2304"
        invalid.longitudeText = "181"
        try expect(!invalid.canApply, "invalid longitude disables apply")

        let (conversion, _, _, _) = make("coordinates")
        conversion.inputSystem = .gcj02
        let wgs = CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)
        conversion.select(wgs)
        let parsed = conversion.parsedCoordinate!
        try expect(abs(parsed.latitude - wgs.latitude) < 1e-6 && abs(parsed.longitude - wgs.longitude) < 1e-6,
                   "map selection and GCJ input produce the original WGS coordinate")

        let (repair, _, repairActivity, _) = make("repair")
        await repair.checkConnection()
        repairActivity.startFails = true
        await repair.startPairing()
        try expect(!repair.connectionReady && !repair.busy,
                   "re-pairing invalidates prior connection even when setup fails")
        repairActivity.startFails = false
        await repair.checkConnection()
        repair.backgrounded()
        try expect(!repair.connectionReady, "backgrounding idle app invalidates cached connection readiness")

        let (retryLegacy, _, _, retryJournal) = make("legacy-stop")
        try expect(retryLegacy.canStop, "can retry recovery even if an older version already removed its marker")
        await retryLegacy.stop()
        try expect(retryLegacy.phase == .awaitingRestore && retryJournal.needsRecovery,
                   "retry stop creates durable recovery obligation")
        print("\(count) iOS model checks passed (macOS host, fake transport; no phone commands).")
    }
}
