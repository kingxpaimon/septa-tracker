import XCTest
@testable import SEPTATracker

/// On-device planner: zip/inflate, GTFS compilation, RAPTOR, live TripUpdates.
///
/// `MiniSEPTA.zip` is a hand-made network in SEPTA's bundle layout (an outer zip holding
/// deflated google_bus.zip and google_rail.zip):
///
///     A ──bus 10X── B ──── C   (walk ~220 m)   D ──rail TST── E
///     10X: B800 08:00→08:10, B810 08:10→08:20, BLATE 24:10→24:20 (weekdays, not 11/11)
///     TST: TST101 08:20→08:30, TST103 08:40→08:50 (weekdays)
///
/// `MiniTripUpdates-*.pb` are synthetic GTFS-RT feeds for it. `Real-TripUpdates-*.pb` are
/// unedited entities from SEPTA's live feeds (2026-11-07), used for decoding only.
final class PlannerTests: XCTestCase {

    private let A = GeoPoint(latitude: 39.95, longitude: -75.20)
    private let C = GeoPoint(latitude: 39.95, longitude: -75.18)
    private let E = GeoPoint(latitude: 39.97, longitude: -75.18)
    private let monday = ServiceDay(year: 2026, month: 11, day: 9)

    private func timetable() throws -> Timetable {
        try Timetable.build(fromSEPTAZip: fixture("MiniSEPTA", "zip"), now: Date(timeIntervalSince1970: 1_794_100_000))
    }

    private func at(_ day: ServiceDay, _ h: Int, _ m: Int) -> Date {
        day.start.addingTimeInterval(TimeInterval(h * 3600 + m * 60))
    }

    // MARK: Zip

    func testReadsNestedZip() throws {
        let outer = try ZipArchive(fixture("MiniSEPTA", "zip"))
        XCTAssertEqual(outer.entries.map(\.name).sorted(), ["google_bus.zip", "google_rail.zip"])
        let rail = try ZipArchive(bytes: try outer.contents(of: "google_rail.zip"))
        XCTAssertEqual(rail.entry(named: "stops.txt")?.method, 8, "deflated")
        let stops = String(decoding: try rail.contents(of: "stops.txt"), as: UTF8.self)
        XCTAssertTrue(stops.contains("Echo Rail"))
        XCTAssertThrowsError(try ZipArchive(Data("not a zip".utf8)))
    }

    // MARK: Compilation

    func testBuildsTimetable() throws {
        let tt = try timetable()
        XCTAssertEqual(tt.stopCount, 5, "parent station (location_type 1) dropped")
        XCTAssertEqual(tt.routeIDs, ["b:10X", "r:TST"])
        XCTAssertEqual(tt.tripIDs.count, 5)
        XCTAssertEqual(tt.patternCount, 2)
        XCTAssertEqual(tt.arrivals.count, 13)
        XCTAssertEqual(tt.validFrom, 20261101)
        XCTAssertEqual(tt.validTo, 20261231)
        XCTAssertEqual(tt.feedVersion, "mini1")
        XCTAssertEqual(tt.stopNames[0], "Alpha St & 1st, North", "quoted CSV field with a comma")

        // Out-of-order stop_times are sorted by stop_sequence.
        let b800 = try XCTUnwrap(tt.tripIDs.firstIndex(of: "b:B800"))
        let base = Int(tt.tripEventStart[b800])
        XCTAssertEqual([Int32](tt.departures[base..<(base + 3)]), [8 * 3600, 8 * 3600 + 300, 8 * 3600 + 600] as [Int32])

        // Only C↔D are within walking-transfer distance.
        XCTAssertEqual(tt.transferTo.count, 2)
    }

    func testCalendarExceptions() throws {
        let tt = try timetable()
        let wk = try XCTUnwrap(tt.serviceIDs.firstIndex(of: "b:WK"))
        XCTAssertTrue(tt.activeServices(on: 20261109, weekday: 0)[wk])
        XCTAssertFalse(tt.activeServices(on: 20261111, weekday: 2)[wk], "removed by calendar_dates")
        XCTAssertFalse(tt.activeServices(on: 20261114, weekday: 5)[wk], "Saturday")
    }

    func testSerializationRoundTrip() throws {
        let tt = try timetable()
        let back = try Timetable(serialized: tt.serialized())
        XCTAssertEqual(back.tripIDs, tt.tripIDs)
        XCTAssertEqual(back.arrivals, tt.arrivals)
        XCTAssertEqual(back.stopLat, tt.stopLat)
        XCTAssertEqual(back.transferSeconds, tt.transferSeconds)
        XCTAssertEqual(back.exceptionDate, tt.exceptionDate)
        XCTAssertEqual(back.validTo, tt.validTo)
        var corrupt = tt.serialized()
        corrupt.removeLast(100)
        XCTAssertThrowsError(try Timetable(serialized: corrupt))
    }

    // MARK: Service days

    func testServiceDayStartsAtNoonMinus12h() {
        // Mon 2026-11-09, EST: noon 17:00Z − 12h = 05:00Z.
        XCTAssertEqual(monday.start, Date(timeIntervalSince1970: 1_794_200_400))
        XCTAssertEqual(monday.weekday, 0)
        XCTAssertEqual(monday.date, 20261109)
        // Sun 2026-11-01 (DST ends at 2am): noon EST − 12h = 05:00Z, i.e. 01:00 EDT, not midnight.
        XCTAssertEqual(ServiceDay(year: 2026, month: 11, day: 1).start, Date(timeIntervalSince1970: 1_793_509_200))
        XCTAssertEqual(ServiceDay(year: 2026, month: 11, day: 1).weekday, 6)
        XCTAssertEqual(monday.adding(days: -1).date, 20261108)
        XCTAssertEqual(ServiceDay(yyyymmdd: "20261109")?.start, monday.start)
    }

    // MARK: Routing

    func testPlansBusTransferRail() throws {
        let router = TripRouter(timetable: try timetable())
        let routes = router.plan(from: A, to: E, departAt: at(monday, 7, 55))
        XCTAssertGreaterThanOrEqual(routes.count, 2)

        let first = routes[0]
        XCTAssertEqual(first.rides.map(\.tripID), ["B800", "TST101_X"])
        XCTAssertEqual(first.rides[0].lineShortName, "10X")
        XCTAssertEqual(first.rides[0].lineColor, "#004F9F")
        XCTAssertEqual(first.rides[0].vehicleType, "BUS")
        XCTAssertEqual(first.rides[0].departureStopName, "Alpha St & 1st, North")
        XCTAssertEqual(first.rides[0].stopCount, 2)
        XCTAssertTrue(first.rides[1].isRail)
        XCTAssertEqual(first.rides[1].lineName, "Test Line")
        XCTAssertNil(first.rides[1].lineShortName)
        XCTAssertEqual(first.rides[1].trainNumber, "101")
        XCTAssertEqual(first.lastArrival, at(monday, 8, 30))
        XCTAssertNil(first.rides[0].liveDelaySeconds)
        // walk C→D between the rides
        XCTAssertTrue(first.segments.contains { if case .walk(let w) = $0 { return w.duration > 150 && w.duration < 300 } else { return false } })

        // Later alternative: the 08:10 bus misses the 08:20 train and takes the 08:40.
        let second = routes[1]
        XCTAssertEqual(second.rides.map(\.tripID), ["B810", "TST103_X"])
        XCTAssertEqual(second.lastArrival, at(monday, 8, 50))
    }

    func testAfterMidnightUsesPreviousServiceDay() throws {
        let router = TripRouter(timetable: try timetable())
        let tuesday = monday.adding(days: 1)
        let routes = router.plan(from: A, to: C, departAt: at(tuesday, 0, 5))
        let ride = try XCTUnwrap(routes.first?.rides.first)
        XCTAssertEqual(ride.tripID, "BLATE", "Monday's 24:10 trip runs at 00:10 Tuesday")
        XCTAssertEqual(ride.departureTime, at(tuesday, 0, 10))
    }

    func testNoServiceOnExceptionDate() throws {
        let router = TripRouter(timetable: try timetable())
        let wednesday = ServiceDay(year: 2026, month: 11, day: 11)
        let routes = router.plan(from: A, to: E, departAt: at(wednesday, 7, 55))
        let firstBus = try XCTUnwrap(routes.first?.rides.first?.departureTime)
        XCTAssertGreaterThanOrEqual(firstBus, wednesday.adding(days: 1).start, "no 10X on 11/11; next is Thursday")
    }

    // MARK: Live data

    func testRailDelayShiftsChoiceToNextTrain() throws {
        let router = TripRouter(timetable: try timetable())
        let rail = try GTFSRealtime.parseTripUpdates(fixture("MiniTripUpdates-Rail", "pb"))
        let live = router.liveDelays(bus: [], rail: rail, now: at(monday, 7, 50))
        XCTAssertEqual(live.matchedTrips, 1)
        let routes = router.plan(from: A, to: E, departAt: at(monday, 7, 55), live: live)
        // TST101 is 25 min late (08:45), so TST103 at 08:40 is better.
        XCTAssertEqual(routes[0].rides.last?.tripID, "TST103_X")
        XCTAssertEqual(routes[0].lastArrival, at(monday, 8, 50))
        let delayed = routes.flatMap(\.rides).first { $0.tripID == "TST101_X" }
        if let delayed {
            XCTAssertEqual(delayed.liveDelaySeconds, 1500)
            XCTAssertEqual(delayed.departureTime, at(monday, 8, 45))
        }
    }

    func testBusPredictionAndCancellation() throws {
        let router = TripRouter(timetable: try timetable())
        let bus = try GTFSRealtime.parseTripUpdates(fixture("MiniTripUpdates-Bus", "pb"))
        XCTAssertEqual(bus.count, 3)
        let live = router.liveDelays(bus: bus, rail: [], now: at(monday, 7, 50))
        XCTAssertEqual(live.matchedTrips, 2, "UNKNOWN trip ignored")

        let routes = router.plan(from: A, to: E, departAt: at(monday, 7, 55), live: live)
        let ride = try XCTUnwrap(routes.first?.rides.first)
        XCTAssertEqual(ride.tripID, "B800")
        XCTAssertEqual(ride.liveDelaySeconds, 300)
        XCTAssertEqual(ride.departureTime, at(monday, 8, 5), "delay carried to earlier stops")
        XCTAssertEqual(ride.arrivalTime, at(monday, 8, 15))
        XCTAssertEqual(routes.first?.rides.last?.tripID, "TST101_X", "still makes the 08:20 train")

        // B810 is canceled on Monday.
        let mondayEnd = monday.adding(days: 1).start
        XCTAssertFalse(routes.flatMap(\.rides).contains { $0.tripID == "B810" && ($0.departureTime ?? .distantFuture) < mondayEnd })
    }

    func testNegativeDelayDecodes() throws {
        let updates = try GTFSRealtime.parseTripUpdates(fixture("MiniTripUpdates-RailEarly", "pb"))
        XCTAssertEqual(updates.first?.stopUpdates.first?.arrivalDelay, -60)
    }

    func testDecodesRealSEPTATripUpdates() throws {
        let bus = try GTFSRealtime.parseTripUpdates(fixture("Real-TripUpdates-Bus", "pb"))
        XCTAssertEqual(bus.count, 3)
        XCTAssertEqual(bus[0].tripID, "874210")
        XCTAssertEqual(bus[0].routeID, "27")
        XCTAssertEqual(bus[0].startDate, "20261107")
        XCTAssertEqual(bus[0].vehicleID, "3854")
        XCTAssertEqual(bus[0].stopUpdates.count, 16)
        XCTAssertEqual(bus[0].stopUpdates[0].stopID, "515")
        XCTAssertEqual(bus[0].stopUpdates[0].stopSequence, 64)
        XCTAssertEqual(bus[0].stopUpdates[0].arrivalTime, 1_794_095_912)
        XCTAssertTrue(bus[2].canceled)

        let rail = try GTFSRealtime.parseTripUpdates(fixture("Real-TripUpdates-Rail", "pb"))
        XCTAssertEqual(rail.count, 2)
        XCTAssertEqual(rail[0].tripID, "PAO9566_20261019_SID189798")
        XCTAssertNil(rail[0].startDate)
        XCTAssertEqual(rail[0].stopUpdates.first?.arrivalDelay, 60)
        XCTAssertEqual(rail[0].stopUpdates.first?.stopSequence, 17)
    }

    // MARK: Exact-vehicle matching

    func testMatchesExactTripVehicle() throws {
        let router = TripRouter(timetable: try timetable())
        let ride = try XCTUnwrap(router.plan(from: A, to: E, departAt: at(monday, 7, 55)).first?.rides.first)
        let bus = Vehicle(id: "bus-10X-4001", mode: .bus, route: "10X", label: "4001", latitude: 39.95, longitude: -75.205,
                          heading: nil, destination: nil, direction: nil, nextStop: nil, minutesLate: 2, reportedAt: nil,
                          tripID: "B800")
        let other = Vehicle(id: "bus-10X-4002", mode: .bus, route: "10X", label: "4002", latitude: 39.95, longitude: -75.201,
                            heading: nil, destination: nil, direction: nil, nextStop: nil, minutesLate: 0, reportedAt: nil,
                            tripID: "B810")
        let info = try XCTUnwrap(LiveLineMatcher.liveInfo(for: ride, in: [other, bus]))
        XCTAssertEqual(info.tripVehicle?.label, "4001")
        XCTAssertEqual(info.nearest?.label, "4002")
        XCTAssertEqual(info.vehicleCount, 2)
        XCTAssertEqual(try XCTUnwrap(info.tripVehicleDistanceMeters), 427, accuracy: 10)
    }

    private func fixture(_ name: String, _ ext: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: ext), "Missing fixture \(name).\(ext)")
        return try Data(contentsOf: url)
    }
}
