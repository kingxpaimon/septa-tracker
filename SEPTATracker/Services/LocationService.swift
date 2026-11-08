import Foundation
import CoreLocation
import Combine

/// Asks for permission (the map's user-location dot and button handle display),
/// provides one-shot lookups for trip planning, and continuous fixes while ride
/// detection is on. "When in use" only: nothing runs in the background. Use from the main thread.
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    /// Latest fix while continuous updates are on.
    @Published private(set) var lastFix: CLLocation?
    private(set) var isUpdatingContinuously = false

    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<CLLocation, Error>] = []

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    /// Location is off for this app (or restricted by parental controls / MDM).
    var isDenied: Bool { authorizationStatus == .denied || authorizationStatus == .restricted }

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
            // While continuous updates run, the next fix answers; requestLocation would be redundant.
            if waiting.count == 1 && !isUpdatingContinuously { manager.requestLocation() }
        }
    }

    /// Continuous, high-accuracy fixes (for ride detection). Call `stopContinuousUpdates` when
    /// detection is turned off or the app leaves the foreground.
    func startContinuousUpdates() {
        guard !isUpdatingContinuously, !isDenied else { return }
        isUpdatingContinuously = true
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
        manager.activityType = .otherNavigation
        manager.startUpdatingLocation()
    }

    func stopContinuousUpdates() {
        guard isUpdatingContinuously else { return }
        isUpdatingContinuously = false
        manager.stopUpdatingLocation()
        lastFix = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        if isUpdatingContinuously { lastFix = location }
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
