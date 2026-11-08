import Foundation

/// Combines SEPTA's JSON feeds (TransitView/TrainView) with its GTFS-realtime
/// VehiclePositions feeds. Both come from SEPTA; GTFS-RT is used to:
///
/// 1. Pick the right entry when TransitView lists a vehicle twice. GTFS-RT's `trip_id`
///    says which trip the vehicle is actually running.
/// 2. Use the freshest position. For buses/trolleys, whichever report has the newer
///    timestamp wins. TrainView has no timestamps, so a matched GTFS-RT position
///    (which does) is preferred for trains.
/// 3. Optionally (off by default) add buses/trolleys that only GTFS-RT reports. Checked
///    against SEPTA's schedule on 4 snapshots (Sat 2026-11-07 6:17 pm, Sun 2026-11-08
///    7:47-7:49 am): of 396 such vehicles, only 2 were running their trip. 271 were waiting
///    at their first stop for a trip that hadn't started, 43 were driving to their next
///    trip, and 80 had finished. TransitView leaves these out on purpose; showing them as
///    "Route 21" would be misleading.
///
/// Positions are never averaged: the two feeds report the same GPS units at different
/// moments, so an average would land behind the vehicle.
enum VehicleMerger {

    // MARK: Buses and trolleys

    /// - Parameters:
    ///   - transitView: every TransitView entry, duplicates included.
    ///   - realtime: the bus/trolley GTFS-RT feed, or empty if it failed.
    static func mergeSurface(transitView: [Vehicle], realtime: [RealtimeVehiclePosition],
                             includeRealtimeOnly: Bool = false) -> [Vehicle] {
        let realtimeByID = Dictionary(realtime.map { ($0.vehicleID, $0) }, uniquingKeysWith: { a, _ in a })
        var merged = resolveDuplicates(transitView) { realtimeByID[$0.label]?.tripID }

        for index in merged.indices {
            guard let rt = realtimeByID[merged[index].label],
                  rt.routeID == nil || rt.routeID == merged[index].route,
                  let rtTime = rt.timestamp
            else { continue }
            if merged[index].reportedAt.map({ rtTime > $0 }) ?? true {
                apply(rt, to: &merged[index])
            }
        }

        guard includeRealtimeOnly else { return uniqued(merged) }
        let known = Set(merged.map(\.label))
        let extras = realtime.compactMap { rt -> Vehicle? in
            // No trip means the vehicle isn't in service (deadheading, in the garage).
            guard !known.contains(rt.vehicleID), let tripID = rt.tripID, let route = rt.routeID else { return nil }
            let mode = TransitMode.forSurfaceRoute(route)
            return Vehicle(
                id: "\(mode.rawValue)-\(route)-\(rt.vehicleID)",
                mode: mode,
                route: route,
                label: rt.vehicleID,
                latitude: rt.latitude,
                longitude: rt.longitude,
                heading: rt.bearing,
                destination: nil,
                direction: nil,
                nextStop: nil,
                minutesLate: nil,
                reportedAt: rt.timestamp,
                tripID: tripID,
                positionSource: .gtfsRealtime
            )
        }
        return uniqued(merged + extras.filter(isPlausible))
    }

    /// Collapses entries that share an ID to one. Preference order:
    /// 1. the entry whose trip matches `activeTrip` (from GTFS-RT);
    /// 2. an entry with non-zero lateness. In captured data the duplicate with
    ///    `late: 0` was the not-yet-started next trip, every time GTFS-RT could tell;
    /// 3. the first entry.
    static func resolveDuplicates(_ vehicles: [Vehicle], activeTrip: (Vehicle) -> String? = { _ in nil }) -> [Vehicle] {
        var order: [Vehicle.ID] = []
        var groups: [Vehicle.ID: [Vehicle]] = [:]
        for vehicle in vehicles {
            if groups[vehicle.id] == nil { order.append(vehicle.id) }
            groups[vehicle.id, default: []].append(vehicle)
        }
        return order.compactMap { id in
            guard let group = groups[id], let first = group.first else { return nil }
            if group.count == 1 { return first }
            if let trip = activeTrip(first), let match = group.first(where: { $0.tripID == trip }) {
                return match
            }
            return group.first { ($0.minutesLate ?? 0) != 0 } ?? first
        }
    }

    // MARK: Regional Rail

    /// Matches trains by train number (TrainView `trainno`, the digits in GTFS-RT `trip_id`).
    /// GTFS-RT can list one train under two trip IDs at the same position; any match works.
    static func mergeRail(trainView: [Vehicle], realtime: [RealtimeVehiclePosition]) -> [Vehicle] {
        var byTrain: [String: RealtimeVehiclePosition] = [:]
        for rt in realtime {
            guard let number = rt.trainNumber else { continue }
            if let existing = byTrain[number], let a = existing.timestamp, let b = rt.timestamp, a >= b { continue }
            byTrain[number] = rt
        }
        return trainView.map { train in
            guard let rt = byTrain[train.label], rt.timestamp != nil else { return train }
            var copy = train
            apply(rt, to: &copy)
            return copy
        }
    }

    // MARK: Helpers

    private static func apply(_ rt: RealtimeVehiclePosition, to vehicle: inout Vehicle) {
        guard isPlausible(lat: rt.latitude, lon: rt.longitude) else { return }
        vehicle.latitude = rt.latitude
        vehicle.longitude = rt.longitude
        if let bearing = rt.bearing { vehicle.heading = bearing }
        vehicle.reportedAt = rt.timestamp
        vehicle.positionSource = .gtfsRealtime
    }

    static func uniqued(_ vehicles: [Vehicle]) -> [Vehicle] {
        var seen = Set<Vehicle.ID>()
        return vehicles.filter { seen.insert($0.id).inserted }
    }

    private static func isPlausible(_ vehicle: Vehicle) -> Bool {
        isPlausible(lat: vehicle.latitude, lon: vehicle.longitude)
    }

    /// Drops (0, 0) and anything far outside the SEPTA region.
    static func isPlausible(lat: Double, lon: Double) -> Bool {
        (38.5...41.5).contains(lat) && (-77.0 ... -73.5).contains(lon)
    }
}
