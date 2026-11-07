import XCTest
@testable import SEPTATracker

/// Google Routes request building and response parsing.
///
/// NOTE: `GoogleRoutes-Synthetic.json` is hand-written from the Routes API documentation,
/// not captured from the API (no key was available). SEPTA line names in it ("31",
/// "Trenton Line") are guesses at how Google names them. Replace it with a real response.
final class GoogleRoutesTests: XCTestCase {

    func testParsesRoutesAndCollapsesWalking() throws {
        let routes = try GoogleRoutesClient.parseRoutes(fixture("GoogleRoutes-Synthetic"))
        XCTAssertEqual(routes.count, 2)

        let route = routes[0]
        XCTAssertEqual(route.duration, 2280)
        XCTAssertEqual(route.durationText, "38 mins")
        XCTAssertEqual(route.distanceText, "5.7 mi")
        XCTAssertEqual(route.fareText, "$2.50")
        XCTAssertEqual(route.segments.count, 4, "walk, ride, walk, ride")
        guard case .walk(let firstWalk) = route.segments[0] else { return XCTFail("expected walk first") }
        XCTAssertEqual(firstWalk.duration, 255)
        XCTAssertEqual(firstWalk.distanceMeters, 330)
        XCTAssertEqual(route.walkingDuration, 325)
    }

    func testParsesRideDetails() throws {
        let route = try GoogleRoutesClient.parseRoutes(fixture("GoogleRoutes-Synthetic"))[0]
        let bus = try XCTUnwrap(route.rides.first)
        XCTAssertEqual(bus.displayName, "31")
        XCTAssertEqual(bus.lineName, "Route 31")
        XCTAssertEqual(bus.vehicleType, "BUS")
        XCTAssertFalse(bus.isRail)
        XCTAssertTrue(bus.isSEPTA)
        XCTAssertEqual(bus.headsign, "15th-Market")
        XCTAssertEqual(bus.departureStopName, "Lansdowne Av & 63rd St")
        XCTAssertEqual(bus.departureStop, GeoPoint(latitude: 39.9781, longitude: -75.2468))
        XCTAssertEqual(bus.departureTimeText, "6:19 PM")
        XCTAssertEqual(bus.stopCount, 18)
        XCTAssertEqual(bus.duration, 1260)
        XCTAssertEqual(route.firstDeparture, Date(timeIntervalSince1970: 1_794_093_540))

        let train = try XCTUnwrap(route.rides.last)
        XCTAssertTrue(train.isRail)
        XCTAssertEqual(train.displayName, "Trenton Line")
        XCTAssertEqual(route.lastArrival, Date(timeIntervalSince1970: 1_794_095_730), "fractional seconds parse")
    }

    func testEmptyResponseMeansNoRoutes() throws {
        XCTAssertEqual(try GoogleRoutesClient.parseRoutes(Data("{}".utf8)).count, 0)
        XCTAssertThrowsError(try GoogleRoutesClient.parseRoutes(Data("[]".utf8)))
    }

    func testErrorMessage() {
        let body = #"{"error":{"code":403,"message":"API key not valid.","status":"PERMISSION_DENIED"}}"#
        XCTAssertEqual(GoogleRoutesClient.errorMessage(in: Data(body.utf8)), "API key not valid.")
    }

    func testDurationParsing() {
        XCTAssertEqual(GoogleRoutesClient.seconds("1234s"), 1234)
        XCTAssertEqual(GoogleRoutesClient.seconds("1.5s"), 1.5)
        XCTAssertNil(GoogleRoutesClient.seconds("1234"))
        XCTAssertNil(GoogleRoutesClient.seconds(nil))
    }

    func testRequestBody() throws {
        let data = try GoogleRoutesClient.requestBody(
            from: GeoPoint(latitude: 39.95, longitude: -75.16),
            to: GeoPoint(latitude: 40.0, longitude: -75.2),
            departure: Date(timeIntervalSince1970: 1_794_093_540),
            preference: .lessWalking
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["travelMode"] as? String, "TRANSIT")
        XCTAssertEqual(body["computeAlternativeRoutes"] as? Bool, true)
        XCTAssertEqual(body["departureTime"] as? String, "2026-11-07T23:19:00Z")
        XCTAssertEqual((body["transitPreferences"] as? [String: Any])?["routingPreference"] as? String, "LESS_WALKING")
        let origin = (body["origin"] as? [String: Any])?["location"] as? [String: Any]
        let latLng = origin?["latLng"] as? [String: Any]
        XCTAssertEqual(latLng?["latitude"] as? Double, 39.95)

        let fastest = try JSONSerialization.jsonObject(with: GoogleRoutesClient.requestBody(
            from: GeoPoint(latitude: 0, longitude: 0), to: GeoPoint(latitude: 0, longitude: 0),
            departure: nil, preference: .fastest)) as? [String: Any]
        XCTAssertNil(fastest?["transitPreferences"])
        XCTAssertNil(fastest?["departureTime"])
    }

    func testFieldMaskHasNoPolylines() {
        XCTAssertFalse(GoogleRoutesClient.fieldMask.contains("polyline"))
    }

    // MARK: - Live matching

    func testMatchesBusRideToLiveVehicles() throws {
        let ride = try XCTUnwrap(GoogleRoutesClient.parseRoutes(fixture("GoogleRoutes-Synthetic"))[0].rides.first)
        let vehicles = try SEPTAClient.parseTransitViewAll(fixture("TransitViewAll"))
        let info = try XCTUnwrap(LiveLineMatcher.liveInfo(for: ride, in: vehicles))
        XCTAssertEqual(info.route, "31")
        XCTAssertEqual(info.vehicleCount, 2)
        XCTAssertEqual(info.nearest?.label, "3694")
        XCTAssertEqual(try XCTUnwrap(info.nearestDistanceMeters), 2100, accuracy: 100)
    }

    func testMatchesRailRideByLineName() throws {
        let ride = try XCTUnwrap(GoogleRoutesClient.parseRoutes(fixture("GoogleRoutes-Synthetic"))[0].rides.last)
        let trains = try SEPTAClient.parseTrainView(fixture("TrainView"))
        let info = try XCTUnwrap(LiveLineMatcher.liveInfo(for: ride, in: trains))
        XCTAssertEqual(info.route, "Trenton")
        XCTAssertEqual(info.vehicleCount, 1)
    }

    func testNoMatchForOtherAgencies() throws {
        let ride = TransitRoute.Ride(
            lineName: "Route 31", lineShortName: "31", lineColor: nil, lineTextColor: nil,
            vehicleType: "BUS", vehicleName: "Bus", agencyNames: ["NJ Transit"], headsign: nil,
            departureStopName: nil, departureStop: nil, arrivalStopName: nil, departureTime: nil,
            arrivalTime: nil, departureTimeText: nil, arrivalTimeText: nil, stopCount: nil, duration: nil)
        let vehicles = try SEPTAClient.parseTransitViewAll(fixture("TransitViewAll"))
        XCTAssertNil(LiveLineMatcher.liveInfo(for: ride, in: vehicles))
    }

    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json"), "Missing fixture \(name).json")
        return try Data(contentsOf: url)
    }
}
