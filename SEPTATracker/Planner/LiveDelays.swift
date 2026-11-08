import Foundation

/// A SEPTA service day. GTFS times count from "noon minus 12 hours" local time,
/// which equals midnight except on daylight-saving change days.
struct ServiceDay: Hashable {
    static let timeZone = TimeZone(identifier: "America/New_York")!

    /// yyyymmdd
    let date: Int32
    /// 0 = Monday … 6 = Sunday
    let weekday: Int
    let start: Date

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    /// The service day whose calendar date (in Philadelphia) contains `instant`.
    init(containing instant: Date) {
        let c = Self.calendar
        let parts = c.dateComponents([.year, .month, .day], from: instant)
        self.init(year: parts.year!, month: parts.month!, day: parts.day!)
    }

    init(year: Int, month: Int, day: Int) {
        let c = Self.calendar
        let noon = c.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
        date = Int32(year * 10_000 + month * 100 + day)
        weekday = (c.component(.weekday, from: noon) + 5) % 7
        start = noon.addingTimeInterval(-12 * 3600)
    }

    init?(yyyymmdd: String) {
        guard yyyymmdd.count == 8, let n = Int(yyyymmdd) else { return nil }
        self.init(year: n / 10_000, month: (n / 100) % 100, day: n % 100)
    }

    func adding(days: Int) -> ServiceDay {
        let c = Self.calendar
        let noon = c.date(byAdding: .day, value: days, to: start.addingTimeInterval(12 * 3600))!
        return ServiceDay(containing: noon)
    }
}

/// SEPTA's live predictions (GTFS-realtime TripUpdates) mapped onto the timetable.
///
/// - Buses: SEPTA sends predicted absolute times for upcoming stops (matched by stop ID).
///   The delay at each matched stop carries forward to later stops until the next update.
/// - Rail: SEPTA sends one delay per train (with a stop_sequence that didn't line up with
///   the schedule's numbering in the captured feed), so it's applied to the whole trip.
/// - Canceled trips are excluded from routing; skipped stops can't be used to board or alight.
struct LiveDelays {
    struct Key: Hashable {
        let trip: Int32
        /// yyyymmdd of the service day, or 0 when the feed didn't say (applies to any day).
        let date: Int32
    }

    private(set) var delays: [Key: [Int32]] = [:]
    private(set) var canceled: Set<Key> = []
    private(set) var skipped: [Key: Set<Int>] = [:]
    var fetchedAt: Date
    var matchedTrips: Int { Set(delays.keys.map(\.trip)).union(canceled.map(\.trip)).count }

    init(fetchedAt: Date = Date()) { self.fetchedAt = fetchedAt }

    func delay(trip: Int32, date: Int32, position: Int) -> Int32? {
        (delays[Key(trip: trip, date: date)] ?? delays[Key(trip: trip, date: 0)])?[position]
    }

    func isCanceled(trip: Int32, date: Int32) -> Bool {
        canceled.contains(Key(trip: trip, date: date)) || canceled.contains(Key(trip: trip, date: 0))
    }

    func isSkipped(trip: Int32, date: Int32, position: Int) -> Bool {
        (skipped[Key(trip: trip, date: date)] ?? skipped[Key(trip: trip, date: 0)])?.contains(position) ?? false
    }

    /// - Parameters:
    ///   - prefix: "b:" for the bus feed, "r:" for rail (matches Timetable IDs).
    ///   - today: used for absolute-time updates that don't say which service day they're for.
    mutating func apply(_ updates: [RealtimeTripUpdate], prefix: String, timetable: Timetable,
                        tripIndex: [String: Int32], stopIndex: [String: Int32], pattern: [Int32], today: ServiceDay) {
        for update in updates {
            guard let trip = tripIndex[prefix + update.tripID] else { continue }
            let day = update.startDate.flatMap(ServiceDay.init(yyyymmdd:))
            let key = Key(trip: trip, date: day?.date ?? 0)
            if update.canceled { canceled.insert(key); continue }

            let p = Int(pattern[Int(trip)])
            let stops = timetable.stops(ofPattern: p)
            let n = stops.count
            let base = Int(timetable.tripEventStart[Int(trip)])

            // (position, delay) pairs in trip order.
            var points: [(Int, Int32)] = []
            var skips = Set<Int>()
            var searchFrom = 0
            for u in update.stopUpdates {
                var position: Int?
                if let id = u.stopID, let stop = stopIndex[prefix + id] {
                    position = stops[(stops.startIndex + searchFrom)...].firstIndex(of: stop).map { $0 - stops.startIndex }
                }
                if position == nil, prefix == "r:" {
                    position = 0    // rail: trip-wide delay (see type docs)
                }
                guard let pos = position else { continue }
                searchFrom = pos
                if u.skipped { skips.insert(pos); continue }

                var delay: Int32?
                if let d = u.departureDelay ?? u.arrivalDelay {
                    delay = Int32(d)
                } else if let time = u.departureTime ?? u.arrivalTime {
                    let serviceDay = day ?? today
                    let scheduled = u.departureTime != nil ? timetable.departures[base + pos] : timetable.arrivals[base + pos]
                    delay = Int32(time - Int64(serviceDay.start.timeIntervalSince1970)) - scheduled
                }
                if let delay, abs(delay) < 6 * 3600 { points.append((pos, delay)) }
            }
            if !skips.isEmpty { skipped[key] = skips }
            guard let first = points.first else { continue }

            var perStop = [Int32](repeating: first.1, count: n)
            for (i, point) in points.enumerated() {
                let end = i + 1 < points.count ? points[i + 1].0 : n
                for pos in point.0..<max(point.0, end) { perStop[pos] = point.1 }
            }
            delays[key] = perStop
        }
    }
}
