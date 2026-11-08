import Foundation

/// One GPS fix from the phone.
struct UserFix: Equatable {
    let time: Date
    let point: GeoPoint
    /// m/s from Core Location; nil when invalid (negative).
    let speed: Double?
    /// Horizontal accuracy in meters.
    let accuracy: Double
}

/// Notices when the user is riding a specific live SEPTA vehicle, entirely on the phone.
///
/// Speeding up alone isn't enough (cars and bikes do that too). A ride is confirmed when:
/// 1. the phone is moving faster than walking (`minRidingSpeed`, sustained over `movingWindow`), and
/// 2. the phone's position *at the time of each vehicle report* is within `matchRadius` of that
///    vehicle, for `reportsToConfirm` distinct reports spanning at least `minConfirmSpan`.
/// Comparing against where the user *was* when SEPTA's report was taken keeps a lagging feed
/// from causing misses or false matches.
///
/// Nothing is stored or sent anywhere. (A future crowd-sourcing backend could use the same
/// confirmed rides, with explicit consent.)
struct RideDetector {
    struct Config {
        /// ~9 mph; brisk walking is ~1.5 m/s, cycling 4–7 m/s (so bikes next to a bus can still
        /// match, which is why several reports over a minute are required).
        var minRidingSpeed = 4.0
        var movingWindow: TimeInterval = 60
        var busMatchRadius = 120.0
        /// Trains are long and their GPS unit may be at either end.
        var railMatchRadius = 250.0
        /// Extra slack when a vehicle has no report time (TrainView without GTFS-RT).
        var untimedSlack = 150.0
        var reportsToConfirm = 3
        var minConfirmSpan: TimeInterval = 60
        /// Fixes worse than this are ignored.
        var maxFixAccuracy = 50.0
        /// A ride ends after this long without a matching report.
        var endAfter: TimeInterval = 150
        var keepFixes: TimeInterval = 600
    }

    struct Ride: Equatable {
        let vehicleID: Vehicle.ID
        let route: String
        let label: String
        let mode: TransitMode
        let since: Date
        var lastMatched: Date
        /// How old SEPTA's latest report was, and how far it was from the phone right now.
        var feedLagSeconds: Double?
        var feedOffsetMeters: Double?
        var minutesLate: Int?
    }

    var config = Config()
    private(set) var fixes: [UserFix] = []
    private(set) var ride: Ride?
    private var candidates: [Vehicle.ID: Candidate] = [:]
    private var rejected: Set<Vehicle.ID> = []

    private struct Candidate {
        var matches: Int
        var first: Date
        var last: Date
        var lastReport: Date?
    }

    init(config: Config = Config()) { self.config = config }

    // MARK: Input

    mutating func add(_ fix: UserFix) {
        guard fix.accuracy >= 0, fix.accuracy <= config.maxFixAccuracy else { return }
        if let last = fixes.last, fix.time <= last.time { return }
        fixes.append(fix)
        let cutoff = fix.time.addingTimeInterval(-config.keepFixes)
        fixes.removeAll { $0.time < cutoff }
    }

    /// Call after each vehicle refresh. Returns the current ride, if any.
    @discardableResult
    mutating func update(vehicles: [Vehicle], now: Date) -> Ride? {
        if var current = ride {
            if let vehicle = vehicles.first(where: { $0.id == current.vehicleID }),
               let d = distance(to: vehicle, now: now), d <= radius(for: vehicle) {
                current.lastMatched = now
                current.minutesLate = vehicle.minutesLate
                current.feedLagSeconds = vehicle.reportedAt.map { now.timeIntervalSince($0) }
                current.feedOffsetMeters = latest.map { $0.point.distance(to: GeoPoint(latitude: vehicle.latitude, longitude: vehicle.longitude)) }
            }
            if now.timeIntervalSince(current.lastMatched) > config.endAfter {
                ride = nil
                candidates = [:]
            } else {
                ride = current
                return ride
            }
        }

        guard isMoving(at: now) else {
            candidates = [:]
            return nil
        }

        var stillClose = Set<Vehicle.ID>()
        for vehicle in vehicles where !rejected.contains(vehicle.id) {
            guard let d = distance(to: vehicle, now: now), d <= radius(for: vehicle) else { continue }
            stillClose.insert(vehicle.id)
            var c = candidates[vehicle.id] ?? Candidate(matches: 0, first: now, last: now, lastReport: nil)
            // Count each distinct SEPTA report once; untimed vehicles count once per refresh.
            if vehicle.reportedAt == nil || vehicle.reportedAt != c.lastReport {
                c.matches += 1
                c.last = now
                c.lastReport = vehicle.reportedAt
            }
            candidates[vehicle.id] = c
        }
        candidates = candidates.filter { stillClose.contains($0.key) }

        let confirmed = candidates.filter {
            $0.value.matches >= config.reportsToConfirm && $0.value.last.timeIntervalSince($0.value.first) >= config.minConfirmSpan
        }
        // Two vehicles side by side (e.g. bunched buses) stay ambiguous until one drops away.
        guard confirmed.count == 1, let (id, c) = confirmed.first,
              let vehicle = vehicles.first(where: { $0.id == id }) else { return nil }
        ride = Ride(vehicleID: id, route: vehicle.route, label: vehicle.label, mode: vehicle.mode,
                    since: c.first, lastMatched: now,
                    feedLagSeconds: vehicle.reportedAt.map { now.timeIntervalSince($0) },
                    feedOffsetMeters: latest.map { $0.point.distance(to: GeoPoint(latitude: vehicle.latitude, longitude: vehicle.longitude)) },
                    minutesLate: vehicle.minutesLate)
        return ride
    }

    /// "Not on this vehicle": end the ride and don't suggest that vehicle again this session.
    mutating func reject() {
        if let id = ride?.vehicleID { rejected.insert(id) }
        ride = nil
        candidates = [:]
    }

    mutating func reset() {
        fixes = []
        ride = nil
        candidates = [:]
    }

    // MARK: Helpers

    var latest: UserFix? { fixes.last }

    /// Moving faster than walking over the last `movingWindow`: median reported speed when
    /// available, otherwise straight-line displacement over time.
    func isMoving(at now: Date) -> Bool {
        let window = fixes.filter { now.timeIntervalSince($0.time) <= config.movingWindow && $0.time <= now }
        guard window.count >= 2, let first = window.first, let last = window.last else { return false }
        let speeds = window.compactMap(\.speed).sorted()
        if speeds.count >= 3 {
            return speeds[speeds.count / 2] >= config.minRidingSpeed
        }
        let dt = last.time.timeIntervalSince(first.time)
        guard dt >= 15 else { return false }
        return first.point.distance(to: last.point) / dt >= config.minRidingSpeed
    }

    /// Where the phone was at `time`, interpolated between fixes. Nil if outside the track
    /// (more than 30 s past the last fix, or before the first).
    func position(at time: Date) -> GeoPoint? {
        guard let first = fixes.first, let last = fixes.last else { return nil }
        if time >= last.time { return time.timeIntervalSince(last.time) <= 30 ? last.point : nil }
        if time < first.time { return nil }
        guard let i = fixes.firstIndex(where: { $0.time >= time }), i > 0 else { return first.point }
        let a = fixes[i - 1], b = fixes[i]
        let f = time.timeIntervalSince(a.time) / b.time.timeIntervalSince(a.time)
        return GeoPoint(latitude: a.point.latitude + (b.point.latitude - a.point.latitude) * f,
                        longitude: a.point.longitude + (b.point.longitude - a.point.longitude) * f)
    }

    private func distance(to vehicle: Vehicle, now: Date) -> Double? {
        guard let user = position(at: vehicle.reportedAt ?? now) else { return nil }
        return user.distance(to: GeoPoint(latitude: vehicle.latitude, longitude: vehicle.longitude))
    }

    private func radius(for vehicle: Vehicle) -> Double {
        let base = vehicle.mode == .regionalRail ? config.railMatchRadius : config.busMatchRadius
        return base + (vehicle.reportedAt == nil ? config.untimedSlack : 0)
    }
}
