import Foundation
import CoreLocation

struct Vehicle: Identifiable, Hashable {
    /// Stable across refreshes so map selection survives a poll.
    let id: String
    let mode: TransitMode
    let route: String
    /// Vehicle number for buses/trolleys, train number for Regional Rail.
    let label: String
    let latitude: Double
    let longitude: Double
    /// Degrees clockwise from north, when reported.
    let heading: Double?
    let destination: String?
    let direction: String?
    let nextStop: String?
    /// Minutes behind schedule. Negative means early. Nil when SEPTA has no estimate.
    let minutesLate: Int?
    /// Seconds between the vehicle's last GPS report and the API response, when reported.
    let secondsSinceReport: Int?

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
