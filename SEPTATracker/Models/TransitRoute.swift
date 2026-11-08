import Foundation

/// A latitude/longitude pair without CoreLocation, so routing code stays testable off-device.
struct GeoPoint: Hashable, Codable {
    var latitude: Double
    var longitude: Double

    /// Great-circle distance in meters (haversine).
    func distance(to other: GeoPoint) -> Double {
        let r = 6_371_000.0
        let dLat = (other.latitude - latitude) * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(latitude * .pi / 180) * cos(other.latitude * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }
}

/// One transit itinerary from the Google Routes API.
///
/// Google's terms forbid using Routes API content "in conjunction with a non-Google map",
/// and this app's map is MapKit. So routes are shown only as lists, on their own screen.
/// Nothing in here (stop coordinates included) should be drawn on the map.
struct TransitRoute: Identifiable, Hashable {
    let id: Int
    /// Total door-to-door time.
    let duration: TimeInterval?
    let durationText: String?
    let distanceText: String?
    let fareText: String?
    let segments: [Segment]
    let warnings: [String]

    enum Segment: Hashable {
        case walk(Walk)
        case ride(Ride)
    }

    /// Consecutive walking steps from Google, collapsed into one segment.
    struct Walk: Hashable {
        var duration: TimeInterval
        var distanceMeters: Int
        /// Line to draw on the map; empty when unknown (e.g. Google results, which can't be
        /// drawn on this app's Apple map anyway).
        var path: [GeoPoint] = []
    }

    struct Ride: Hashable {
        let lineName: String?
        let lineShortName: String?
        /// "#RRGGBB" from Google, when provided.
        let lineColor: String?
        let lineTextColor: String?
        /// Google vehicle type, e.g. "BUS", "TRAM", "HEAVY_RAIL", "COMMUTER_TRAIN".
        let vehicleType: String?
        let vehicleName: String?
        let agencyNames: [String]
        let headsign: String?
        let departureStopName: String?
        let departureStop: GeoPoint?
        let arrivalStopName: String?
        let departureTime: Date?
        let arrivalTime: Date?
        let departureTimeText: String?
        let arrivalTimeText: String?
        let stopCount: Int?
        let duration: TimeInterval?
        // Set by the on-device SEPTA planner (nil for Google results):
        /// SEPTA GTFS trip_id of the exact trip to board.
        var tripID: String? = nil
        /// Regional Rail train number, e.g. "1725".
        var trainNumber: String? = nil
        /// Live delay at the boarding stop from SEPTA's TripUpdates feed; nil = schedule only.
        var liveDelaySeconds: Int? = nil
        /// GTFS route_short_name ("21", "T1", "AIR").
        var routeShortName: String? = nil
        /// Line to draw on the map: street geometry from Transitous, or the stop-by-stop
        /// sequence from the on-device planner. Empty for Google.
        var path: [GeoPoint] = []

        /// Short label for chips: "21", "T1", or the line name for rail.
        var displayName: String {
            lineShortName ?? lineName ?? vehicleName ?? "Transit"
        }

        var isRail: Bool {
            ["HEAVY_RAIL", "COMMUTER_TRAIN", "RAIL", "HIGH_SPEED_TRAIN", "LONG_DISTANCE_TRAIN"]
                .contains(vehicleType ?? "")
        }

        var isSEPTA: Bool {
            agencyNames.contains { $0.localizedCaseInsensitiveContains("SEPTA") }
        }
    }

    var rides: [Ride] {
        segments.compactMap { if case .ride(let r) = $0 { return r } else { return nil } }
    }

    var walkingDuration: TimeInterval {
        segments.reduce(0) { total, segment in
            if case .walk(let w) = segment { return total + w.duration }
            return total
        }
    }

    /// Every point to draw, in order (for fitting the map).
    var allPoints: [GeoPoint] {
        segments.flatMap { segment -> [GeoPoint] in
            switch segment {
            case .walk(let w): return w.path
            case .ride(let r): return r.path
            }
        }
    }

    var firstDeparture: Date? { rides.first?.departureTime }
    var lastArrival: Date? { rides.last?.arrivalTime }
}
