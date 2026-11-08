import XCTest
@testable import SEPTATracker

/// Ride detection on simulated tracks. The phone moves east along latitude 39.95; SEPTA
/// vehicles report every 30 s, and the app refreshes every 20 s.
final class RideDetectorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_794_200_000)
    private let lat = 39.95
    private let startLon = -75.20
    private let metersPerDegreeLon = 111_320 * cos(39.95 * .pi / 180)

    /// Phone position after `seconds` at `speed` m/s (stops at `stopAt`, if given).
    private func userPoint(_ seconds: Double, speed: Double, stopAt: Double? = nil) -> GeoPoint {
        let moving = min(seconds, stopAt ?? .infinity)
        return GeoPoint(latitude: lat, longitude: startLon + moving * speed / metersPerDegreeLon)
    }

    private func vehicle(_ id: String, at p: GeoPoint, reported: Date?, mode: TransitMode = .bus,
                         northMeters: Double = 0, late: Int? = 2) -> Vehicle {
        Vehicle(id: "\(mode.rawValue)-21-\(id)", mode: mode, route: "21", label: id,
                latitude: p.latitude + northMeters / 111_000, longitude: p.longitude,
                heading: 90, destination: nil, direction: nil, nextStop: nil, minutesLate: late, reportedAt: reported)
    }

    /// Runs a simulation: fixes every 2 s, refresh every 20 s. `vehicles(reportTime)` builds the
    /// vehicle list from the latest 30 s report boundary (minus `feedLag`).
    @discardableResult
    private func simulate(_ d: inout RideDetector, from: Double = 0, until: Double, speed: Double, stopAt: Double? = nil,
                          feedLag: Double = 10, vehicles: (Double) -> [Vehicle]) -> [(Double, RideDetector.Ride?)] {
        var log: [(Double, RideDetector.Ride?)] = []
        var t = from
        while t <= until {
            let moving = stopAt.map { t < $0 } ?? true
            d.add(UserFix(time: t0.addingTimeInterval(t), point: userPoint(t, speed: speed, stopAt: stopAt),
                          speed: moving ? speed : 0, accuracy: 10))
            if Int(t) % 20 == 0 && t > from {
                let report = max(0, (t / 30).rounded(.down) * 30 - feedLag)
                log.append((t, d.update(vehicles: vehicles(report), now: t0.addingTimeInterval(t))))
            }
            t += 2
        }
        return log
    }

    func testConfirmsRideAfterSeveralReports() {
        var d = RideDetector()
        let log = simulate(&d, until: 200, speed: 8) { r in
            [self.vehicle("3686", at: self.userPoint(r, speed: 8), reported: self.t0.addingTimeInterval(r), northMeters: 30)]
        }
        let firstRide = log.first { $0.1 != nil }
        XCTAssertNotNil(firstRide, "should detect the ride")
        XCTAssertGreaterThanOrEqual(firstRide?.0 ?? 0, 60, "needs reports spanning at least a minute")
        XCTAssertEqual(d.ride?.label, "3686")
        XCTAssertEqual(d.ride?.minutesLate, 2)
        XCTAssertNotNil(d.ride?.feedLagSeconds)
    }

    func testWalkingNextToABusIsNotARide() {
        var d = RideDetector()
        simulate(&d, until: 240, speed: 1.4) { r in
            [self.vehicle("3686", at: self.userPoint(r, speed: 1.4), reported: self.t0.addingTimeInterval(r))]
        }
        XCTAssertNil(d.ride)
    }

    func testDrivingPastBusesOnAnotherStreetIsNotARide() {
        var d = RideDetector()
        simulate(&d, until: 240, speed: 12) { r in
            [self.vehicle("3686", at: self.userPoint(r, speed: 12), reported: self.t0.addingTimeInterval(r), northMeters: 600)]
        }
        XCTAssertNil(d.ride)
    }

    func testBunchedBusesStayAmbiguous() {
        var d = RideDetector()
        simulate(&d, until: 240, speed: 8) { r in
            let p = self.userPoint(r, speed: 8)
            return [self.vehicle("3686", at: p, reported: self.t0.addingTimeInterval(r), northMeters: 20),
                    self.vehicle("3694", at: p, reported: self.t0.addingTimeInterval(r), northMeters: -40)]
        }
        XCTAssertNil(d.ride, "can't tell which of two adjacent buses you're on")
    }

    func testLaggingFeedStillMatches() {
        var d = RideDetector()
        // SEPTA's report is 60 s old: the bus marker is ~480 m behind the phone, but it was
        // exactly where the phone was when the report was taken.
        simulate(&d, until: 240, speed: 8, feedLag: 60) { r in
            [self.vehicle("3686", at: self.userPoint(r, speed: 8), reported: self.t0.addingTimeInterval(r))]
        }
        XCTAssertEqual(d.ride?.label, "3686")
        XCTAssertGreaterThan(d.ride?.feedOffsetMeters ?? 0, 300)
    }

    func testRideEndsAfterGettingOff() {
        var d = RideDetector()
        simulate(&d, until: 200, speed: 8) { r in
            [self.vehicle("3686", at: self.userPoint(r, speed: 8), reported: self.t0.addingTimeInterval(r))]
        }
        XCTAssertNotNil(d.ride)
        // The phone stops at t=200; the bus carries on.
        simulate(&d, from: 200, until: 500, speed: 8, stopAt: 200) { r in
            [self.vehicle("3686", at: self.userPoint(r, speed: 8), reported: self.t0.addingTimeInterval(r))]
        }
        XCTAssertNil(d.ride, "ride ends once the bus pulls away")
    }

    func testRejectedVehicleIsNotSuggestedAgain() {
        var d = RideDetector()
        let bus: (Double) -> [Vehicle] = { r in
            [self.vehicle("3686", at: self.userPoint(r, speed: 8), reported: self.t0.addingTimeInterval(r))]
        }
        simulate(&d, until: 200, speed: 8, vehicles: bus)
        XCTAssertNotNil(d.ride)
        d.reject()
        simulate(&d, from: 200, until: 400, speed: 8, vehicles: bus)
        XCTAssertNil(d.ride)
    }

    func testTrainWithoutReportTimeUsesWiderRadius() {
        // TrainView only (no timestamp): compared with the phone's current position, with extra
        // slack. Here the train's reported position trails the phone by ~15 s (300 m at 20 m/s).
        var d = RideDetector()
        var t = 0.0
        while t <= 200 {
            d.add(UserFix(time: t0.addingTimeInterval(t), point: userPoint(t, speed: 20), speed: 20, accuracy: 10))
            if Int(t) % 20 == 0 && t > 0 {
                d.update(vehicles: [vehicle("1725", at: userPoint(t - 15, speed: 20), reported: nil, mode: .regionalRail)],
                         now: t0.addingTimeInterval(t))
            }
            t += 2
        }
        XCTAssertEqual(d.ride?.mode, .regionalRail)
        XCTAssertNil(d.ride?.feedLagSeconds, "no report time to measure lag from")
    }

    func testPositionInterpolationAndBadFixes() {
        var d = RideDetector()
        d.add(UserFix(time: t0, point: GeoPoint(latitude: 39.95, longitude: -75.20), speed: 5, accuracy: 10))
        d.add(UserFix(time: t0.addingTimeInterval(10), point: GeoPoint(latitude: 39.96, longitude: -75.20), speed: 5, accuracy: 10))
        d.add(UserFix(time: t0.addingTimeInterval(12), point: GeoPoint(latitude: 40.5, longitude: -75.0), speed: 5, accuracy: 500))
        XCTAssertEqual(d.fixes.count, 2, "inaccurate fix ignored")
        XCTAssertEqual(d.position(at: t0.addingTimeInterval(5))?.latitude ?? 0, 39.955, accuracy: 1e-9)
        XCTAssertNil(d.position(at: t0.addingTimeInterval(-1)))
        XCTAssertNil(d.position(at: t0.addingTimeInterval(60)), "too far past the last fix")
    }
}
