import Foundation

/// Links a ride in a Google transit route to the live SEPTA vehicles on that line.
///
/// Matching is by name, and how Google names SEPTA lines is **unverified** (no real
/// Routes API response has been captured). Assumptions:
/// - Buses/trolleys: Google's `nameShort` ("21", "T1", "G1") equals the TransitView route key.
/// - Regional Rail: Google's line `name` ("Paoli/Thorndale Line") equals TrainView's `line`
///   ("Paoli/Thorndale") once a trailing " Line" is removed.
/// When nothing matches, the UI just shows no live info for that ride.
enum LiveLineMatcher {

    struct LiveInfo: Hashable {
        /// The value to put in `VehicleStore.selectedRoutes` to show this line on the map.
        let route: String
        let vehicleCount: Int
        /// The live vehicle nearest the ride's boarding stop, if Google gave the stop's location.
        let nearest: Vehicle?
        let nearestDistanceMeters: Double?
    }

    static func liveInfo(for ride: TransitRoute.Ride, in vehicles: [Vehicle]) -> LiveInfo? {
        guard ride.isSEPTA || ride.agencyNames.isEmpty else { return nil }

        let candidates: [Vehicle]
        if ride.isRail {
            guard let name = ride.lineName.map(normalizedRailName) else { return nil }
            candidates = vehicles.filter { $0.mode == .regionalRail && normalizedRailName($0.route) == name }
        } else {
            guard let short = ride.lineShortName?.uppercased() else { return nil }
            candidates = vehicles.filter { $0.mode != .regionalRail && $0.route.uppercased() == short }
        }
        guard let route = candidates.first?.route else { return nil }

        var nearest: Vehicle?
        var nearestDistance: Double?
        if let stop = ride.departureStop {
            for vehicle in candidates {
                let d = stop.distance(to: GeoPoint(latitude: vehicle.latitude, longitude: vehicle.longitude))
                if nearestDistance.map({ d < $0 }) ?? true {
                    nearest = vehicle
                    nearestDistance = d
                }
            }
        }
        return LiveInfo(route: route, vehicleCount: candidates.count, nearest: nearest, nearestDistanceMeters: nearestDistance)
    }

    static func normalizedRailName(_ name: String) -> String {
        var n = name.trimmingCharacters(in: .whitespaces).lowercased()
        if n.hasSuffix(" line") { n.removeLast(5) }
        return n
    }
}
