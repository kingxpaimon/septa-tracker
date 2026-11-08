import XCTest
@testable import SEPTATracker

/// Nearby departures (on MiniSEPTA.zip, see PlannerTests for the network), alert timing,
/// and the diagnostic snapshot.
final class NearbyAndAlertsTests: XCTestCase {
    private let A = GeoPoint(latitude: 39.95, longitude: -75.20)
    private let C = GeoPoint(latitude: 39.95, longitude: -75.18)
    private let D = GeoPoint(latitude: 39.952, longitude: -75.18)
    private let monday = ServiceDay(year: 2026, month: 11, day: 9)

    private func router() throws -> TripRouter {
        TripRouter(timetable: try Timetable.build(fromSEPTAZip: fixture("MiniSEPTA", "zip")))
    }
    private func at(_ h: Int, _ m: Int, _ day: ServiceDay? = nil) -> Date {
        (day ?? monday).start.addingTimeInterval(TimeInterval(h * 3600 + m * 60))
    }

    func testDeparturesAtStop() throws {
        let lines = try router().departures(near: A, at: at(7, 55), radius: 100)
        XCTAssertEqual(lines.count, 1)
        let line = try XCTUnwrap(lines.first)
        XCTAssertEqual(line.displayName, "10X")
        XCTAssertEqual(line.headsign, "Charlie")
        XCTAssertEqual(line.stopName, "Alpha St & 1st, North")
        XCTAssertEqual(line.departures.map(\.tripID), ["B800", "B810"])
        XCTAssertEqual(line.departures.first?.time, at(8, 0))
        XCTAssertFalse(line.departures[0].isLive)
        XCTAssertEqual(line.color, "#004F9F")
    }

    func testNoDeparturesAtLastStop() throws {
        // C is the 10X's last stop; D (220 m away) is the rail stop.
        let lines = try router().departures(near: C, at: at(7, 55), radius: 300)
        XCTAssertEqual(lines.map(\.displayName), ["Test"], "only the train; buses end at C")
        XCTAssertTrue(lines[0].isRail)
        XCTAssertEqual(lines[0].stopName, "Delta Rail")
        XCTAssertEqual(lines[0].walkMeters, 222 * 1.25, accuracy: 5)
    }

    func testWindowAndAfterMidnight() throws {
        let r = try router()
        XCTAssertTrue(r.departures(near: A, at: at(10, 0), radius: 100).isEmpty, "nothing until the 24:10 trip")
        // Monday's 24:10 trip is Tuesday 00:10.
        let late = r.departures(near: A, at: at(23, 50), radius: 100)
        XCTAssertEqual(late.first?.departures.first?.tripID, "BLATE")
        XCTAssertEqual(late.first?.departures.first?.time, at(0, 10, monday.adding(days: 1)))
    }

    func testLiveDelaysAndCancellations() throws {
        let r = try router()
        let bus = try GTFSRealtime.parseTripUpdates(fixture("MiniTripUpdates-Bus", "pb"))
        let rail = try GTFSRealtime.parseTripUpdates(fixture("MiniTripUpdates-Rail", "pb"))
        let live = r.liveDelays(bus: bus, rail: rail, now: at(7, 50))

        let busLine = try XCTUnwrap(r.departures(near: A, at: at(7, 55), live: live, radius: 100).first)
        XCTAssertEqual(busLine.departures.map(\.tripID), ["B800"], "B810 is canceled")
        XCTAssertEqual(busLine.departures[0].time, at(8, 5))
        XCTAssertEqual(busLine.departures[0].delaySeconds, 300)

        let train = try XCTUnwrap(r.departures(near: D, at: at(7, 55), live: live, radius: 100).first)
        XCTAssertEqual(train.departures.map(\.tripID), ["TST103_X", "TST101_X"], "TST101 is 25 min late, now after TST103")
        XCTAssertEqual(train.departures[1].scheduled, at(8, 20))
        XCTAssertEqual(train.departures[1].time, at(8, 45))
    }

    func testAlertTiming() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(AlertTiming.fireDate(event: now.addingTimeInterval(600), leadMinutes: 5, now: now), now.addingTimeInterval(300))
        XCTAssertEqual(AlertTiming.fireDate(event: now.addingTimeInterval(120), leadMinutes: 5, now: now), now.addingTimeInterval(1),
                       "lead window already started: deliver right away")
        XCTAssertNil(AlertTiming.fireDate(event: now.addingTimeInterval(-1), leadMinutes: 5, now: now))
        let alert = TripAlert(id: "x", kind: .departure, title: "10X to Charlie", message: "Leaves Alpha St",
                              eventTime: now, leadMinutes: 5, tripID: "B800")
        XCTAssertEqual(AlertTiming.body(for: alert), "Leaves Alpha St in 5 min")
        XCTAssertEqual(alert.fireDate, now.addingTimeInterval(-300))
    }

    func testDiagnosticReportKeepsNearbyVehiclesOnly() throws {
        func v(_ label: String, _ lat: Double) -> Vehicle {
            Vehicle(id: "bus-21-\(label)", mode: .bus, route: "21", label: label, latitude: lat, longitude: -75.16,
                    heading: nil, destination: "69th St", direction: nil, nextStop: nil, minutesLate: 3, reportedAt: nil)
        }
        let report = DiagnosticReport.make(note: "bus missing", user: (GeoPoint(latitude: 39.95, longitude: -75.16), 8),
                                           vehicles: [v("near", 39.951), v("far", 40.05)], waitingCount: 4,
                                           feedUpdatedAt: nil, feedErrors: [], ride: nil, appVersion: "1.0",
                                           now: Date(timeIntervalSince1970: 1_794_200_000))
        XCTAssertEqual(report.nearbyVehicles.map(\.label), ["near"])
        let json = String(decoding: try report.jsonData(), as: UTF8.self)
        XCTAssertTrue(json.contains("\"note\" : \"bus missing\""))
        XCTAssertTrue(json.contains("2026-11-"), "ISO-8601 dates")
    }

    private func fixture(_ name: String, _ ext: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: ext), "Missing fixture \(name).\(ext)")
        return try Data(contentsOf: url)
    }
}
