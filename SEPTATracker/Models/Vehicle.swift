import Foundation
import CoreLocation

struct Vehicle: Identifiable, Hashable {
    /// Stable across refreshes so map selection survives a poll.
    let id: String
    let mode: TransitMode
    let route: String
    /// Vehicle number for buses/trolleys, train number for Regional Rail.
    let label: String
    var latitude: Double
    var longitude: Double
    /// Degrees clockwise from north, when reported.
    var heading: Double?
    let destination: String?
    let direction: String?
    let nextStop: String?
    /// Minutes behind schedule. Negative means early. Nil when SEPTA has no estimate.
    let minutesLate: Int?
    /// When the vehicle last reported the position shown. TransitView sends this as
    /// `timestamp` (Unix seconds) and GTFS-realtime as `VehiclePosition.timestamp`.
    /// TrainView has no equivalent.
    var reportedAt: Date?
    /// The trip the vehicle is serving, when known (TransitView `trip`, GTFS-RT `trip_id`).
    var tripID: String? = nil
    /// Which feed the position came from.
    var positionSource: PositionSource = .septaJSON
    /// How full it is (TransitView `estimated_seat_availability`), when SEPTA knows.
    var occupancy: Occupancy? = nil
    // Regional Rail only (TrainView):
    /// Platform/track at the current or next station, e.g. "1N", "2C".
    var track: String? = nil
    var trackChanged: Bool = false
    /// Number of cars, from the consist list.
    var cars: Int? = nil
    /// "LOCAL", "EXPRESS", ...
    var service: String? = nil
    var currentStop: String? = nil

    enum Occupancy: String, Hashable {
        case empty = "EMPTY"
        case manySeats = "MANY_SEATS_AVAILABLE"
        case fewSeats = "FEW_SEATS_AVAILABLE"
        case standingRoom = "STANDING_ROOM_ONLY"
        case crushed = "CRUSHED_STANDING_ROOM_ONLY"
        case full = "FULL"

        var title: String {
            switch self {
            case .empty: return "Empty"
            case .manySeats: return "Many seats"
            case .fewSeats: return "Few seats"
            case .standingRoom: return "Standing room only"
            case .crushed: return "Very crowded"
            case .full: return "Full"
            }
        }

        /// 1 (empty) … 4 (full), for a small gauge.
        var level: Int {
            switch self {
            case .empty, .manySeats: return 1
            case .fewSeats: return 2
            case .standingRoom: return 3
            case .crushed, .full: return 4
            }
        }
    }

    enum PositionSource: String, Hashable {
        /// TransitViewAll or TrainView.
        case septaJSON
        /// SEPTA's GTFS-realtime VehiclePositions feed.
        case gtfsRealtime

        var title: String {
            switch self {
            case .septaJSON: return "SEPTA TransitView/TrainView"
            case .gtfsRealtime: return "SEPTA GTFS-realtime"
            }
        }
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var lateDescription: String {
        guard let minutesLate else { return "No estimate" }
        if minutesLate == 0 { return "On time" }
        if minutesLate < 0 { return "\(-minutesLate) min early" }
        return "\(minutesLate) min late"
    }
}
