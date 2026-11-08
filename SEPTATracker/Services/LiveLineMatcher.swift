import Foundation

/// Links a ride in a recommended route to live SEPTA vehicles.
///
/// - **Exact vehicle** (on-device SEPTA planner only): the ride carries SEPTA's trip_id,
///   and live buses/trolleys carry the trip they're running (TransitView `trip`, which
///   matched GTFS trip_ids in captured data). Trains are matched by train number.
/// - **Same line**: by name. For Google results, how Google names SEPTA lines is
///   unverified; for the SEPTA planner, GTFS short names ("21", "T1") match TransitView
///   route keys, and rail long names ("Airport Line") match TrainView lines minus " Line".
enum LiveLineMatcher {

    struct LiveInfo: Hashable {
        /// The value to put in `VehicleStore.selectedRoutes` to show this line on the map.
        let route: String
        let vehicleCount: Int
        /// The vehicle running this exact trip, when known.
        let tripVehicle: Vehicle?
        /// True when that vehicle is assigned to the trip but hasn't started it yet (it's
        /// typically waiting at the first stop). Only GTFS-RT reports these.
        var tripVehicleIsWaiting = false
        let tripVehicleDistanceMeters: Double?
        /// Otherwise: the live vehicle on the line nearest the boarding stop.
        let nearest: Vehicle?
        let nearestDistanceMeters: Double?
    }

    static func liveInfo(for ride: TransitRoute.Ride, in vehicles: [Vehicle], waiting: [Vehicle] = []) -> LiveInfo? {
        guard ride.isSEPTA || ride.agencyNames.isEmpty else { return nil }

        let candidates: [Vehicle]
        if ride.isRail {
            guard let name = ride.lineName.map(normalizedRailName) else { return nil }
            candidates = vehicles.filter { $0.mode == .regionalRail && normalizedRailName($0.route) == name }
        } else {
            guard let short = (ride.lineShortName ?? ride.routeShortName)?.uppercased() else { return nil }
            candidates = vehicles.filter { $0.mode != .regionalRail && $0.route.uppercased() == short }
        }

        var tripVehicle: Vehicle?
        if ride.isRail, let number = ride.trainNumber {
            tripVehicle = vehicles.first { $0.mode == .regionalRail && $0.label == number }
        } else if let trip = ride.tripID {
            tripVehicle = vehicles.first { $0.mode != .regionalRail && $0.tripID == trip }
        }
        var isWaiting = false
        if tripVehicle == nil, !ride.isRail, let trip = ride.tripID,
           let parked = waiting.first(where: { $0.tripID == trip }) {
            tripVehicle = parked
            isWaiting = true
        }

        guard let route = tripVehicle?.route ?? candidates.first?.route else { return nil }

        func distance(_ v: Vehicle) -> Double? {
            ride.departureStop?.distance(to: GeoPoint(latitude: v.latitude, longitude: v.longitude))
        }
        var nearest: Vehicle?
        var nearestDistance: Double?
        for vehicle in candidates {
            guard let d = distance(vehicle) else { break }
            if nearestDistance.map({ d < $0 }) ?? true {
                nearest = vehicle
                nearestDistance = d
            }
        }
        return LiveInfo(route: route, vehicleCount: max(candidates.count, tripVehicle == nil || isWaiting ? 0 : 1),
                        tripVehicle: tripVehicle, tripVehicleIsWaiting: isWaiting,
                        tripVehicleDistanceMeters: tripVehicle.flatMap(distance),
                        nearest: nearest, nearestDistanceMeters: nearestDistance)
    }

    static func normalizedRailName(_ name: String) -> String {
        var n = name.trimmingCharacters(in: .whitespaces).lowercased()
        if n.hasSuffix(" line") { n.removeLast(5) }
        return n
    }
}
