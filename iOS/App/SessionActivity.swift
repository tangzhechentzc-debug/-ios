@preconcurrency import CoreLocation
import UIKit

@MainActor
final class SessionActivity: NSObject, SessionKeeping, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var permissionWaiter: CheckedContinuation<Void, Error>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    var onExpiration: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
    }

    func start() async throws {
        if manager.authorizationStatus == .notDetermined {
            try await withCheckedThrowingContinuation { continuation in
                permissionWaiter = continuation
                manager.requestWhenInUseAuthorization()
            }
        }
        guard manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways else {
            throw LocationFailure(message: "需要“使用 App 期间”定位权限，以便切换到地图或设置时保持会话。请在系统设置中允许。")
        }
        manager.startUpdatingLocation()
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "LocationSession") { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.endBackgroundTask()
                    self.onExpiration?()
                }
            }
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined else { return }
        let waiter = permissionWaiter
        permissionWaiter = nil
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            waiter?.resume()
        } else {
            waiter?.resume(throwing: LocationFailure(message: "未获得定位权限，无法保持后台会话。"))
            onExpiration?()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
