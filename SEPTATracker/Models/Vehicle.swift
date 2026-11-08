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
