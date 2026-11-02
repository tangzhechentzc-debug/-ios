import CoreLocation
import Foundation

struct LocationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct PairingProgress {
    let state: String
    let code: String?
    let message: String?
}

@MainActor
protocol PhoneLocationServing: AnyObject {
    func hasPairing() throws -> Bool
    func startPairing() async throws
    func pairingProgress() async throws -> PairingProgress
    func cancelPairing() async
    func connect(recoveryNeeded: Bool) async throws
    func apply(_ coordinate: CLLocationCoordinate2D) async throws
    func clear() async throws
    func confirmRestore() async throws
    func status() async throws -> String
}

@MainActor
protocol SessionKeeping: AnyObject {
    func start() async throws
    func stop()
}
