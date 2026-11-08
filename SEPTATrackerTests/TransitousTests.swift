import XCTest
@testable import SEPTATracker

/// Transitous client against a real response captured 2026-11-07 ~8:05 pm Eastern
/// (63rd & Lansdowne → Temple University). The first two itineraries were kept and
/// turn-by-turn `steps` removed to keep the file small. Nothing else was edited.
final class TransitousTests: XCTestCase {

    func testParsesItineraries() throws {
        let routes = try TransitousClient.parseRoutes(fixture())
        XCTAssertEqual(routes.count, 2)
        let route = routes[0]
        XCTAssertEqual(route.duration, 2580)
        XCTAssertEqual(route.durationText, "43 min")
        XCTAssertEqual(route.segments.count, 5, "walk, ride, walk, ride, walk")
        XCTAssertEqual(route.walkingDuration, 420)
    }

    func testTrolleyRideWithLivePrediction() throws {
        let ride = try XCTUnwrap(TransitousClient.parseRoutes(fixture())[0].rides.first)
        XCTAssertEqual(ride.lineShortName, "T1")
        XCTAssertEqual(ride.vehicleType, "TRAM")
        XCTAssertFalse(ride.isRail)
        XCTAssertTrue(ride.isSEPTA)
        XCTAssertEqual(ride.headsign, "13th St")
        XCTAssertEqual(ride.departureStopName, "63rd St & Jefferson St")
        XCTAssertEqual(ride.lineColor, "#5a960a")
        XCTAssertEqual(ride.stopCount, 34)
        XCTAssertEqual(ride.tripID, "968699", "SEPTA trip_id extracted from Transitous tripId")
        XCTAssertEqual(ride.liveDelaySeconds, 120, "realTime departure 01:12Z vs scheduled 01:10Z")
        XCTAssertEqual(ride.departureTime, TransitousClient.date("2026-11-08T01:12:00Z"))
    }

    func testRegionalRailRide() throws {
        let ride = try XCTUnwrap(TransitousClient.parseRoutes(fixture())[0].rides.last)
        XCTAssertTrue(ride.isRail)
        XCTAssertNil(ride.lineShortName)
        XCTAssertEqual(ride.lineName, "Lansdale/Doylestown Line")
        XCTAssertEqual(ride.displayName, "Lansdale/Doylestown Line")
        XCTAssertEqual(ride.routeShortName, "LAN")
        XCTAssertEqual(ride.trainNumber, "3562")
        XCTAssertEqual(ride.tripID, "LAN3562_20261018_SID189800")
        XCTAssertNil(ride.liveDelaySeconds, "Transitous had no live data for SEPTA rail")
    }

    func testAlertsBecomeWarnings() throws {
        let routes = try TransitousClient.parseRoutes(fixture())
        XCTAssertTrue(routes[0].warnings.contains { $0.hasPrefix("T1: Shuttle Busing Between 33rd Street Station") })
        XCTAssertEqual(routes[1].warnings.count, 4)
    }

    func testRequestURLAndUserAgent() {
        let url = TransitousClient.url(from: GeoPoint(latitude: 39.9781, longitude: -75.2468),
                                       to: GeoPoint(latitude: 39.9814, longitude: -75.1495),
                                       time: Date(timeIntervalSince1970: 1_794_200_400))
        XCTAssertEqual(url.host, "api.transitous.org")
        XCTAssertEqual(url.path, "/api/v1/plan")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "fromPlace" }?.value, "39.9781,-75.2468")
        XCTAssertEqual(query.first { $0.name == "time" }?.value, "2026-11-09T05:00:00Z")
        XCTAssertNil(query.first { $0.name == "arriveBy" })
        let arriveURL = TransitousClient.url(from: GeoPoint(latitude: 0, longitude: 0), to: GeoPoint(latitude: 0, longitude: 0),
                                             time: Date(timeIntervalSince1970: 1_794_200_400), arriveBy: true)
        let arriveQuery = URLComponents(url: arriveURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(arriveQuery.first { $0.name == "arriveBy" }?.value, "true")
        XCTAssertTrue(TransitousClient.userAgent.hasPrefix("SEPTA-Live/"))
        XCTAssertTrue(TransitousClient.userAgent.contains("https://github.com/kingxpaimon/septa-tracker"))
    }

    func testDecodesRouteGeometry() throws {
        let route = try TransitousClient.parseRoutes(fixture())[0]
        let trolley = try XCTUnwrap(route.rides.first)
        XCTAssertEqual(trolley.path.count, 193, "matches legGeometry.length")
        XCTAssertEqual(trolley.path.first?.latitude ?? 0, 39.97835, accuracy: 1e-6)
        XCTAssertEqual(trolley.path.last?.longitude ?? 0, -75.16256, accuracy: 1e-6)
        XCTAssertEqual(route.rides.last?.path.count, 217)
        guard case .walk(let firstWalk) = route.segments[0] else { return XCTFail("expected walk") }
        XCTAssertEqual(firstWalk.path.count, 2)
        XCTAssertEqual(route.allPoints.count, 2 + 193 + 61 + 217 + 2)
    }

    func testPolylineDecoding() {
        // Google's documented example (precision 5).
        let points = Polyline.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@")
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[0].latitude, 38.5, accuracy: 1e-9)
        XCTAssertEqual(points[0].longitude, -120.2, accuracy: 1e-9)
        XCTAssertEqual(points[2].latitude, 43.252, accuracy: 1e-9)
        XCTAssertEqual(points[2].longitude, -126.453, accuracy: 1e-9)
        XCTAssertTrue(Polyline.decode("").isEmpty)
        XCTAssertEqual(Polyline.decode("_p~iF~ps|U_ulL").count, 1, "truncated pair dropped")
    }

    func testHelpers() {
        XCTAssertEqual(TransitousClient.septaTripID("20261107_20:08_us-pa-SEPTA-Bus_968699"), "968699")
        XCTAssertNil(TransitousClient.septaTripID("20261107_us-nj-NJT_123"))
        XCTAssertEqual(TransitousClient.trainNumber("NOR2469"), "2469")
        XCTAssertNil(TransitousClient.trainNumber(""))
        XCTAssertThrowsError(try TransitousClient.parseRoutes(Data("[]".utf8)))
        XCTAssertEqual(try TransitousClient.parseRoutes(Data("{}".utf8)).count, 0)
    }

    private func fixture() throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "Transitous-Plan", withExtension: "json"))
        return try Data(contentsOf: url)
    }
}
