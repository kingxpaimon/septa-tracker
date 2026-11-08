import Foundation

/// Rider-facing observations derived from the live feed.
enum VehicleInsights {
    struct Bunch: Hashable {
        let otherID: Vehicle.ID
        let otherLabel: String
        let meters: Double
    }

    /// Buses/trolleys running close behind or ahead of another on the same route and in the
    /// same direction ("bunching"). When two buses travel together, the gap to the next one
    /// is usually long. In captures: 8 bunched pairs among 393 buses on a Saturday evening,
    /// 1 among 194 on a Sunday morning. Regional Rail is excluded (no direction field).
    static func bunching(_ vehicles: [Vehicle], within meters: Double = 400) -> [Vehicle.ID: Bunch] {
        var groups: [String: [Vehicle]] = [:]
        for v in vehicles where v.mode != .regionalRail {
            guard let direction = v.direction, !direction.isEmpty else { continue }
            groups["\(v.route)|\(direction)", default: []].append(v)
        }
        var result: [Vehicle.ID: Bunch] = [:]
        for group in groups.values where group.count > 1 {
            for v in group {
                var nearest: (Vehicle, Double)?
                for other in group where other.id != v.id {
                    let d = GeoPoint(latitude: v.latitude, longitude: v.longitude)
                        .distance(to: GeoPoint(latitude: other.latitude, longitude: other.longitude))
                    if d <= meters, nearest.map({ d < $0.1 }) ?? true { nearest = (other, d) }
                }
                if let (other, d) = nearest {
                    result[v.id] = Bunch(otherID: other.id, otherLabel: other.label, meters: d)
                }
            }
        }
        return result
    }
}
