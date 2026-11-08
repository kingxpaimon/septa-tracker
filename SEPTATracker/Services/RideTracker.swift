import Foundation
import CoreLocation
import Combine

/// App-side wrapper around `RideDetector`: feeds it phone fixes and vehicle refreshes,
/// publishes the current ride, and moves the ridden vehicle's marker to the phone.
@MainActor
final class RideTracker: ObservableObject {
    @Published private(set) var ride: RideDetector.Ride?
    private var detector = RideDetector()
    private var latestFix: UserFix?

    func observe(_ location: CLLocation) {
        let fix = UserFix(time: location.timestamp,
                          point: GeoPoint(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude),
                          speed: location.speed >= 0 ? location.speed : nil,
                          accuracy: location.horizontalAccuracy)
        latestFix = fix
        detector.add(fix)
    }

    func observe(vehicles: [Vehicle], now: Date = Date()) {
        let updated = detector.update(vehicles: vehicles, now: now)
        if updated != ride { ride = updated }
    }

    /// "Not on this vehicle."
    func reject() {
        detector.reject()
        ride = nil
    }

    func reset() {
        detector.reset()
        latestFix = nil
        ride = nil
    }

    /// The ridden vehicle placed at the phone's fresh position (SEPTA's report is often
    /// 30–90 s old). Other vehicles are returned unchanged.
    func adjusted(_ vehicle: Vehicle, now: Date = Date()) -> Vehicle {
        guard let ride, ride.vehicleID == vehicle.id, let fix = latestFix,
              now.timeIntervalSince(fix.time) < 30 else { return vehicle }
        var copy = vehicle
        copy.latitude = fix.point.latitude
        copy.longitude = fix.point.longitude
        copy.reportedAt = fix.time
        return copy
    }
}
