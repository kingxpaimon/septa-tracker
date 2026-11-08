import XCTest
@testable import SEPTATracker

/// Parser tests against trimmed, unedited responses captured from
/// www3.septa.org on 2026-11-07 (see Fixtures/). Entries were dropped to keep
/// the files small; no field was changed.
final class SEPTAClientParsingTests: XCTestCase {

    // MARK: - TransitViewAll

    func testTransitViewAllParsesEveryVehicleOnce() throws {
        let vehicles = try SEPTAClient.parseTransitViewAll(fixture("TransitViewAll"))
        // 15 entries in the fixture; T1 #8486 and route 33 #7386 each appear twice.
        XCTAssertEqual(vehicles.count, 13)
        XCTAssertEqual(Set(vehicles.map(\.id)).count, vehicles.count, "IDs must be unique")
    }

    func testTransitViewAllReadsFields() throws {
        let vehicles = try SEPTAClient.parseTransitViewAll(fixture("TransitViewAll"))
        let bus = try XCTUnwrap(vehicles.first { $0.id == "bus-31-3686" })

        XCTAssertEqual(bus.mode, .bus)
        XCTAssertEqual(bus.route, "31")
        XCTAssertEqual(bus.label, "3686")
        XCTAssertEqual(bus.latitude, 39.977975, accuracy: 1e-9)
        XCTAssertEqual(bus.longitude, -75.273299, accuracy: 1e-9)
        XCTAssertEqual(bus.heading, 328)
        XCTAssertEqual(bus.destination, "76th-City")
        XCTAssertEqual(bus.direction, "WestBound")
        XCTAssertEqual(bus.nextStop, "Lansdowne Av & 63rd St - MBFS")
        XCTAssertEqual(bus.minutesLate, -10)
        XCTAssertEqual(bus.lateDescription, "10 min early")
        XCTAssertEqual(bus.reportedAt, Date(timeIntervalSince1970: 1_794_092_353))
    }

    func testTransitViewAllNullNextStopIsNil() throws {
        let vehicles = try SEPTAClient.parseTransitViewAll(fixture("TransitViewAll"))
        let trolley = try XCTUnwrap(vehicles.first { $0.id == "trolley-T1-8433" })
        XCTAssertNil(trolley.nextStop)
        XCTAssertEqual(trolley.minutesLate, -7)
    }

    func testTransitViewAll998MeansNoEstimate() throws {
        let vehicles = try SEPTAClient.parseTransitViewAll(fixture("TransitViewAll"))
        let bus = try XCTUnwrap(vehicles.first { $0.id == "bus-26-3323" })
        XCTAssertNil(bus.minutesLate)
        XCTAssertEqual(bus.lateDescription, "No estimate")
    }

    /// Without GTFS-RT, the duplicate with non-zero lateness wins: in captured data the
    /// `late: 0` entry was always the next, not-yet-started trip.
    func testTransitViewAllDuplicatePrefersEntryWithLateness() throws {
        let vehicles = try SEPTAClient.parseTransitViewAll(fixture("TransitViewAll"))
        let trolley = try XCTUnwrap(vehicles.first { $0.id == "trolley-T1-8486" })
        XCTAssertEqual(trolley.nextStop, "Drexel Station at 30th St")
        XCTAssertEqual(trolley.minutesLate, 15)
        XCTAssertEqual(trolley.tripID, "968663")
    }

    func testTransitViewAllEntriesKeepsDuplicates() throws {
        let entries = try SEPTAClient.parseTransitViewAllEntries(fixture("TransitViewAll"))
        XCTAssertEqual(entries.count, 15)
    }

    func testTransitViewAllModeByRoute() throws {
        let vehicles = try SEPTAClient.parseTransitViewAll(fixture("TransitViewAll"))
        let modes = Dictionary(vehicles.map { ($0.route, $0.mode) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(modes["T1"], .trolley)
        XCTAssertEqual(modes["G1"], .trolley)
        XCTAssertEqual(modes["M1"], .trolley)
        XCTAssertEqual(modes["D1_BUS"], .bus)
        XCTAssertEqual(modes["31"], .bus)
    }

    func testTransitViewAllRejectsNonObject() {
        XCTAssertThrowsError(try SEPTAClient.parseTransitViewAll(Data("[]".utf8)))
        XCTAssertThrowsError(try SEPTAClient.parseTransitViewAll(Data(#"{"other": 1}"#.utf8)))
    }

    func testTransitViewAllSkipsUnusableCoordinates() throws {
        let json = #"{"routes":[{"17":[{"lat":"0","lng":"0","label":"1"},{"lat":null,"lng":"-75.1","label":"2"},{"lat":"39.95","lng":"-75.16","label":"3"}]}]}"#
        let vehicles = try SEPTAClient.parseTransitViewAll(Data(json.utf8))
        XCTAssertEqual(vehicles.map(\.label), ["3"])
    }

    // MARK: - TrainView

    func testTrainViewParsesEveryTrain() throws {
        let trains = try SEPTAClient.parseTrainView(fixture("TrainView"))
        XCTAssertEqual(trains.count, 4)
        XCTAssertTrue(trains.allSatisfy { $0.mode == .regionalRail })
    }

    func testTrainViewReadsFields() throws {
        let trains = try SEPTAClient.parseTrainView(fixture("TrainView"))
        let train = try XCTUnwrap(trains.first)

        XCTAssertEqual(train.id, "regionalRail-1725")
        XCTAssertEqual(train.label, "1725")
        XCTAssertEqual(train.route, "Trenton")
        XCTAssertEqual(train.latitude, 40.0223635, accuracy: 1e-9)
        XCTAssertEqual(train.longitude, -75.040422333333, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(train.heading), 54.355894574966, accuracy: 1e-9)
        XCTAssertEqual(train.destination, "Trenton")
        XCTAssertEqual(train.nextStop, "Tacony")
        XCTAssertEqual(train.minutesLate, 1)
        XCTAssertNil(train.direction)
        XCTAssertNil(train.reportedAt)
    }

    func testTrainViewRejectsNonArray() {
        XCTAssertThrowsError(try SEPTAClient.parseTrainView(Data("{}".utf8)))
    }

    // MARK: - Helpers

    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json"), "Missing fixture \(name).json")
        return try Data(contentsOf: url)
    }
}
