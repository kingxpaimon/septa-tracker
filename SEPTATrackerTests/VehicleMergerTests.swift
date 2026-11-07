import XCTest
@testable import SEPTATracker

/// GTFS-realtime decoding and merging, against feeds captured together from
/// www3.septa.org on 2026-11-07 ~23:17 UTC (Fixtures/Merge-*). The .pb files are
/// subsets of the real feeds: whole entities were dropped, none were edited.
final class VehicleMergerTests: XCTestCase {

    // MARK: - GTFS-realtime decoding

    func testDecodesBusVehiclePositions() throws {
        let positions = try GTFSRealtime.parseVehiclePositions(fixture("Merge-BusVehiclePositions", "pb"))
        XCTAssertEqual(positions.count, 8)

        let bus = try XCTUnwrap(positions.first { $0.vehicleID == "8633" })
        XCTAssertEqual(bus.label, "8633")
        XCTAssertEqual(bus.tripID, "869405")
        XCTAssertEqual(bus.routeID, "16")
        XCTAssertEqual(bus.latitude, 39.972992, accuracy: 1e-5)
        XCTAssertEqual(bus.longitude, -75.159164, accuracy: 1e-5)
        XCTAssertEqual(try XCTUnwrap(bus.bearing), 190.22, accuracy: 0.01)
        XCTAssertEqual(bus.timestamp, Date(timeIntervalSince1970: 1_794_093_418))

        let outOfService = try XCTUnwrap(positions.first { $0.vehicleID == "1218" })
        XCTAssertNil(outOfService.tripID)
        XCTAssertNil(outOfService.routeID)
    }

    func testDecodesRailVehiclePositions() throws {
        let positions = try GTFSRealtime.parseVehiclePositions(fixture("Merge-RailVehiclePositions", "pb"))
        XCTAssertEqual(positions.count, 5)
        let train = try XCTUnwrap(positions.first { $0.tripID == "TRE1727_20261018_SID189800" })
        XCTAssertEqual(train.vehicleID, "856,855,738,717")
        XCTAssertEqual(train.routeID, "TRE")
        XCTAssertEqual(train.trainNumber, "1727")
    }

    func testTrainNumberFromTripID() {
        func number(_ trip: String?) -> String? {
            RealtimeVehiclePosition(vehicleID: "x", label: nil, tripID: trip, routeID: nil,
                                    latitude: 0, longitude: 0, bearing: nil, timestamp: nil).trainNumber
        }
        XCTAssertEqual(number("PAO9566_20261019_SID189798"), "9566")
        XCTAssertNil(number("875385"))
        XCTAssertNil(number("PAO_2026"))
        XCTAssertNil(number(nil))
    }

    func testRejectsTruncatedData() throws {
        var data = try fixture("Merge-BusVehiclePositions", "pb")
        data.removeLast(10)
        XCTAssertThrowsError(try GTFSRealtime.parseVehiclePositions(data))
        XCTAssertThrowsError(try GTFSRealtime.parseVehiclePositions(Data("{}".utf8)))
    }

    // MARK: - Bus/trolley merge

    private func mergedSurface() throws -> [Vehicle] {
        let entries = try SEPTAClient.parseTransitViewAllEntries(fixture("Merge-TransitViewAll", "json"))
        let positions = try GTFSRealtime.parseVehiclePositions(fixture("Merge-BusVehiclePositions", "pb"))
        return VehicleMerger.mergeSurface(transitView: entries, realtime: positions)
    }

    func testSurfaceMergeVehicleSet() throws {
        let vehicles = try mergedSurface()
        XCTAssertEqual(Set(vehicles.map(\.id)), [
            "bus-16-8633", "bus-33-7373", "bus-D1_BUS-3084", "trolley-T1-8484", "bus-5-3513",
            "bus-124-3630", "bus-52-3401",   // GTFS-RT only, in service
            // 1218 is in GTFS-RT without a trip (not in service): excluded.
        ])
    }

    func testDuplicateResolvedByRealtimeTrip() throws {
        let vehicles = try mergedSurface()
        let bus = try XCTUnwrap(vehicles.first { $0.id == "bus-16-8633" })
        XCTAssertEqual(bus.tripID, "869405")
        XCTAssertEqual(bus.minutesLate, 25)
        XCTAssertEqual(bus.destination, "15th-Market")
    }

    func testNewerRealtimePositionWins() throws {
        let vehicles = try mergedSurface()
        let bus = try XCTUnwrap(vehicles.first { $0.id == "bus-D1_BUS-3084" })
        XCTAssertEqual(bus.positionSource, .gtfsRealtime)
        XCTAssertEqual(bus.reportedAt, Date(timeIntervalSince1970: 1_794_093_418))
        XCTAssertEqual(bus.latitude, 39.918468, accuracy: 1e-5)
        XCTAssertNotNil(bus.heading, "TransitView heading is kept when GTFS-RT has no bearing")
    }

    func testNewerTransitViewPositionWins() throws {
        let vehicles = try mergedSurface()
        let trolley = try XCTUnwrap(vehicles.first { $0.id == "trolley-T1-8484" })
        XCTAssertEqual(trolley.positionSource, .septaJSON)
        XCTAssertEqual(trolley.latitude, 39.960997, accuracy: 1e-9)
        XCTAssertEqual(trolley.reportedAt, Date(timeIntervalSince1970: 1_794_093_422))
    }

    func testRouteMismatchKeepsTransitView() throws {
        // TransitView says route 5, GTFS-RT says route 25 for vehicle 3513.
        let vehicles = try mergedSurface()
        let bus = try XCTUnwrap(vehicles.first { $0.label == "3513" })
        XCTAssertEqual(bus.route, "5")
        XCTAssertEqual(bus.positionSource, .septaJSON)
    }

    func testRealtimeOnlyVehicleHasNoScheduleDetails() throws {
        let vehicles = try mergedSurface()
        let bus = try XCTUnwrap(vehicles.first { $0.id == "bus-124-3630" })
        XCTAssertEqual(bus.positionSource, .gtfsRealtime)
        XCTAssertEqual(bus.tripID, "840960")
        XCTAssertNil(bus.destination)
        XCTAssertNil(bus.minutesLate)
    }

    func testSurfaceMergeWithoutRealtimeFallsBack() throws {
        let entries = try SEPTAClient.parseTransitViewAllEntries(fixture("Merge-TransitViewAll", "json"))
        let vehicles = VehicleMerger.mergeSurface(transitView: entries, realtime: [])
        XCTAssertEqual(vehicles.count, 5)
        XCTAssertTrue(vehicles.allSatisfy { $0.positionSource == .septaJSON })
        // Heuristic picks the late entry, which matches what GTFS-RT says.
        XCTAssertEqual(vehicles.first { $0.id == "bus-33-7373" }?.tripID, "876678")
    }

    // MARK: - Rail merge

    func testRailMergeUsesRealtimePositionAndTimestamp() throws {
        let trains = try SEPTAClient.parseTrainView(fixture("Merge-TrainView", "json"))
        let positions = try GTFSRealtime.parseVehiclePositions(fixture("Merge-RailVehiclePositions", "pb"))
        let merged = VehicleMerger.mergeRail(trainView: trains, realtime: positions)

        XCTAssertEqual(merged.count, 3)
        XCTAssertTrue(merged.allSatisfy { $0.positionSource == .gtfsRealtime && $0.reportedAt != nil })

        // TrainView put 4459 ~6.5 km from the Roslyn/Ardsley stretch it reported; GTFS-RT agrees with the stops.
        let train = try XCTUnwrap(merged.first { $0.label == "4459" })
        XCTAssertEqual(train.latitude, 40.117622, accuracy: 1e-5)
        XCTAssertEqual(train.longitude, -75.147575, accuracy: 1e-5)
        XCTAssertEqual(train.nextStop, "Ardsley")
        XCTAssertEqual(train.route, "Warminster")
    }

    // MARK: - Helpers

    private func fixture(_ name: String, _ ext: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: ext), "Missing fixture \(name).\(ext)")
        return try Data(contentsOf: url)
    }
}
