import XCTest
@testable import SEPTATracker

/// Track/cars/crowding parsing (real fixtures), bunching, and "waiting at first stop".
final class RiderInsightsTests: XCTestCase {

    func testTrainDetailsFromTrainView() throws {
        let trains = try SEPTAClient.parseTrainView(fixture("TrainView", "json"))
        let train = try XCTUnwrap(trains.first { $0.label == "1725" })
        XCTAssertEqual(train.track, "1")
        XCTAssertFalse(train.trackChanged)
        XCTAssertEqual(train.cars, 5, "consist 124,123,50,403,408")
        XCTAssertEqual(train.service, "LOCAL")
        XCTAssertEqual(train.currentStop, "Bridesburg")
    }

    func testOccupancyFromTransitView() throws {
        let vehicles = try SEPTAClient.parseTransitViewAll(fixture("TransitViewAll", "json"))
        XCTAssertEqual(vehicles.first { $0.label == "3686" }?.occupancy, .manySeats)
        XCTAssertNil(vehicles.first { $0.label == "8433" }?.occupancy, "NOT_AVAILABLE → nil")
        XCTAssertEqual(Vehicle.Occupancy.crushed.level, 4)
    }

    private func bus(_ label: String, route: String = "45", direction: String? = "NorthBound", lat: Double) -> Vehicle {
        Vehicle(id: "bus-\(route)-\(label)", mode: .bus, route: route, label: label, latitude: lat, longitude: -75.16,
                heading: nil, destination: nil, direction: direction, nextStop: nil, minutesLate: nil, reportedAt: nil)
    }

    func testBunching() {
        let vehicles = [
            bus("A", lat: 39.9500),
            bus("B", lat: 39.9510),                         // ~111 m from A, same route+direction
            bus("C", lat: 39.9600),                         // ~1 km away
            bus("D", direction: "SouthBound", lat: 39.9501), // opposite direction
            bus("E", route: "47", lat: 39.9502),            // other route
            bus("F", direction: nil, lat: 39.9503),         // no direction
        ]
        let bunches = VehicleInsights.bunching(vehicles)
        XCTAssertEqual(Set(bunches.keys), ["bus-45-A", "bus-45-B"])
        XCTAssertEqual(bunches["bus-45-A"]?.otherLabel, "B")
        XCTAssertEqual(bunches["bus-45-A"]?.meters ?? 0, 111, accuracy: 2)
    }

    func testRealtimeOnlyVehiclesFromMergeFixtures() throws {
        let entries = try SEPTAClient.parseTransitViewAllEntries(fixture("Merge-TransitViewAll", "json"))
        let positions = try GTFSRealtime.parseVehiclePositions(fixture("Merge-BusVehiclePositions", "pb"))
        let waiting = VehicleMerger.realtimeOnly(transitView: entries, realtime: positions)
        XCTAssertEqual(Set(waiting.map(\.label)), ["3630", "3401"])
        XCTAssertEqual(waiting.first { $0.label == "3630" }?.tripID, "840960")
    }

    func testWaitingBusMatchesPlannedTrip() throws {
        let ride = TransitRoute.Ride(
            lineName: nil, lineShortName: "124", lineColor: nil, lineTextColor: nil, vehicleType: "BUS",
            vehicleName: "Bus", agencyNames: ["SEPTA"], headsign: nil, departureStopName: "Chesterbrook",
            departureStop: GeoPoint(latitude: 40.0732, longitude: -75.4305), arrivalStopName: nil,
            departureTime: nil, arrivalTime: nil, departureTimeText: nil, arrivalTimeText: nil,
            stopCount: nil, duration: nil, tripID: "840960", routeShortName: "124")
        let entries = try SEPTAClient.parseTransitViewAllEntries(fixture("Merge-TransitViewAll", "json"))
        let positions = try GTFSRealtime.parseVehiclePositions(fixture("Merge-BusVehiclePositions", "pb"))
        let waiting = VehicleMerger.realtimeOnly(transitView: entries, realtime: positions)

        XCTAssertNil(LiveLineMatcher.liveInfo(for: ride, in: []), "nothing without the waiting list")
        let info = try XCTUnwrap(LiveLineMatcher.liveInfo(for: ride, in: [], waiting: waiting))
        XCTAssertEqual(info.tripVehicle?.label, "3630")
        XCTAssertTrue(info.tripVehicleIsWaiting)
        XCTAssertEqual(info.vehicleCount, 0, "a waiting bus isn't counted as live on the line")
        XCTAssertLessThan(info.tripVehicleDistanceMeters ?? .infinity, 50)
    }

    private func fixture(_ name: String, _ ext: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: ext), "Missing fixture \(name).\(ext)")
        return try Data(contentsOf: url)
    }
}
