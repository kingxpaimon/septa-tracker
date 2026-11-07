import Foundation
import CoreLocation
import Combine

/// Asks for permission (the map's user-location dot and button handle display) and
/// provides one-shot location lookups for trip planning. Use from the main thread.
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus

    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<CLLocation, Error>] = []

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    func requestPermissionIfNeeded() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    /// The current location, reusing a fix from the last minute if there is one.
    /// Throws if permission is denied or no fix can be obtained.
    func currentLocation() async throws -> CLLocation {
        if let recent = manager.location, recent.timestamp.timeIntervalSinceNow > -60 {
            return recent
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiting.append(continuation)
            if waiting.count == 1 { manager.requestLocation() }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let pending = waiting
        waiting = []
        pending.forEach { $0.resume(returning: location) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let pending = waiting
        waiting = []
        pending.forEach { $0.resume(throwing: error) }
    }
}
