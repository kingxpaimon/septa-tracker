import Foundation

/// The next departures of one line, in one direction, from the nearest stop that serves it.
struct LineDepartures: Identifiable, Hashable {
    struct Departure: Identifiable, Hashable {
        /// SEPTA GTFS trip_id (no feed prefix) + service date; stable across refreshes.
        var id: String { "\(tripID)@\(serviceDate)" }
        let tripID: String
        let serviceDate: Int32
        /// Live-adjusted when SEPTA has a prediction for this trip.
        let time: Date
        let scheduled: Date
        /// Seconds late (negative = early); nil = schedule only.
        let delaySeconds: Int?
        var isLive: Bool { delaySeconds != nil }
    }

    var id: String { "\(routeID)|\(headsign)|\(stopID)" }
    let routeID: String
    let routeShortName: String
    let routeLongName: String
    /// "#RRGGBB"
    let color: String?
    let textColor: String?
    /// GTFS route_type: 0 tram, 1 subway, 2 rail, 3 bus, 11 trackless trolley.
    let routeType: Int32
    let headsign: String
    let stopID: String
    let stopName: String
    let stop: GeoPoint
    /// Walking distance estimate (straight line × 1.25).
    let walkMeters: Double
    let departures: [Departure]

    var isRail: Bool { routeType == 2 }
    /// "21", "T1", or the rail line name without " Line".
    var displayName: String {
        if isRail {
            return routeLongName.hasSuffix(" Line") ? String(routeLongName.dropLast(5)) : routeLongName
        }
        return routeShortName.isEmpty ? routeLongName : routeShortName
    }
    var systemImage: String {
        switch routeType {
        case 0: return "tram.fill"
        case 1: return "tram.tunnel.fill"
        case 2: return "train.side.front.car"
        default: return "bus.fill"
        }
    }
}

extension TripRouter {
    /// Next departures near `point`, one entry per line + direction (headsign), taken from the
    /// nearest stop serving it, like Transit's main screen. Sorted by the soonest departure.
    ///
    /// - Live delays and cancellations from SEPTA's TripUpdates are applied when given.
    /// - Stops where a trip only drops off (its last stop, or pickup_type 1) are excluded.
    func departures(near point: GeoPoint, at now: Date, live: LiveDelays? = nil,
                    radius: Double = 500, window: TimeInterval = 90 * 60,
                    perLine: Int = 3, maxLines: Int = 25) -> [LineDepartures] {
        let tt = timetable
        let today = ServiceDay(containing: now)
        let days: [(day: ServiceDay, offset: Int32, active: [Bool])] = [(-1, Int32(-86_400)), (0, 0), (1, 86_400)].map { delta, offset in
            let d = today.adding(days: delta)
            return (d, offset, tt.activeServices(on: d.date, weekday: d.weekday))
        }
        let t0 = Int32(now.timeIntervalSince(today.start))
        let from = t0 - 60, to = t0 + Int32(window)

        struct Group {
            let stop: Int
            let meters: Double
            let route: Int
            let headsign: String
            var departures: [LineDepartures.Departure]
        }
        var groups: [String: Group] = [:]

        let nearby = tt.stops(near: point, within: radius).sorted { $0.meters < $1.meters }
        for (stop, meters) in nearby {
            let lo = Int(tt.stopPatternStart[stop]), hi = Int(tt.stopPatternStart[stop + 1])
            for pi in lo..<hi {
                let p = Int(tt.stopPatterns[pi])
                let stops = tt.stops(ofPattern: p)
                // Positions of this stop in the pattern where boarding makes sense (not the last stop).
                let positions = stops.indices.filter { Int(stops[$0]) == stop && $0 < stops.endIndex - 1 }
                    .map { $0 - stops.startIndex }
                guard !positions.isEmpty else { continue }
                let route = Int(tt.patternRoute[p])

                for trip in tt.trips(ofPattern: p) {
                    let service = Int(tt.tripService[trip])
                    let headsign = tt.headsigns[Int(tt.tripHeadsign[trip])]
                    let key = "\(route)|\(headsign)"
                    // The nearest stop that serves this line + direction owns it.
                    if let g = groups[key], g.stop != stop { continue }
                    let base = Int(tt.tripEventStart[trip])
                    for d in days where d.active[service] {
                        let date = d.day.date
                        if live?.isCanceled(trip: Int32(trip), date: date) == true { continue }
                        for pos in positions {
                            guard tt.eventFlags[base + pos] & 1 == 0,
                                  !(live?.isSkipped(trip: Int32(trip), date: date, position: pos) ?? false) else { continue }
                            let scheduled = tt.departures[base + pos] + d.offset
                            let delay = live?.delay(trip: Int32(trip), date: date, position: pos)
                            let time = scheduled + (delay ?? 0)
                            guard time >= from && time <= to else { continue }
                            let departure = LineDepartures.Departure(
                                tripID: String(tt.tripIDs[trip].dropFirst(2)),
                                serviceDate: date,
                                time: today.start.addingTimeInterval(TimeInterval(time)),
                                scheduled: today.start.addingTimeInterval(TimeInterval(scheduled)),
                                delaySeconds: delay.map(Int.init))
                            if groups[key] == nil {
                                groups[key] = Group(stop: stop, meters: meters, route: route, headsign: headsign, departures: [])
                            }
                            groups[key]?.departures.append(departure)
                        }
                    }
                }
            }
        }

        let lines: [LineDepartures] = groups.values.compactMap { g in
            let next = g.departures.sorted { $0.time < $1.time }
            // The same trip can appear twice if a loop passes the stop twice; keep the first.
            var seen = Set<String>()
            let unique = next.filter { seen.insert($0.id).inserted }.prefix(perLine)
            guard !unique.isEmpty else { return nil }
            let color = tt.routeColors[g.route], text = tt.routeTextColors[g.route]
            return LineDepartures(
                routeID: String(tt.routeIDs[g.route].dropFirst(2)),
                routeShortName: tt.routeShortNames[g.route],
                routeLongName: tt.routeLongNames[g.route],
                color: color.isEmpty ? nil : "#" + color,
                textColor: text.isEmpty ? nil : "#" + text,
                routeType: tt.routeTypes[g.route],
                headsign: g.headsign,
                stopID: String(tt.stopIDs[g.stop].dropFirst(2)),
                stopName: tt.stopNames[g.stop],
                stop: tt.point(ofStop: g.stop),
                walkMeters: Walking.meters(straightLine: g.meters),
                departures: Array(unique))
        }
        return Array(lines.sorted { ($0.departures[0].time, $0.walkMeters) < ($1.departures[0].time, $1.walkMeters) }.prefix(maxLines))
    }
}
