import Foundation

/// On-device transit routing over SEPTA's timetable using RAPTOR
/// (Delling, Pajor, Werneck: "Round-Based Public Transit Routing", 2012).
///
/// Each round adds one more ride, so the results are a Pareto set: the fastest trip
/// with one ride, a faster one with two rides (if any), and so on.
struct TripRouter {
    struct Options {
        var maxRides = 5
        /// How far you'll walk to the first stop / from the last stop.
        var accessMeters = 900.0
        /// Offer a walk-only option below this straight-line distance.
        var walkOnlyMeters = 1_600.0
    }

    let timetable: Timetable
    let tripIndex: [String: Int32]
    let stopIndex: [String: Int32]
    /// Pattern of each trip.
    let tripPattern: [Int32]

    init(timetable: Timetable) {
        self.timetable = timetable
        var trips: [String: Int32] = [:]
        trips.reserveCapacity(timetable.tripIDs.count)
        for (i, id) in timetable.tripIDs.enumerated() { trips[id] = Int32(i) }
        tripIndex = trips
        var stops: [String: Int32] = [:]
        for (i, id) in timetable.stopIDs.enumerated() { stops[id] = Int32(i) }
        stopIndex = stops
        var pattern = [Int32](repeating: 0, count: timetable.tripIDs.count)
        for p in 0..<timetable.patternCount {
            for t in timetable.trips(ofPattern: p) { pattern[t] = Int32(p) }
        }
        tripPattern = pattern
    }

    /// Maps both SEPTA TripUpdates feeds onto this timetable.
    func liveDelays(bus: [RealtimeTripUpdate], rail: [RealtimeTripUpdate], now: Date = Date()) -> LiveDelays {
        var live = LiveDelays(fetchedAt: now)
        let today = ServiceDay(containing: now)
        live.apply(bus, prefix: "b:", timetable: timetable, tripIndex: tripIndex, stopIndex: stopIndex, pattern: tripPattern, today: today)
        live.apply(rail, prefix: "r:", timetable: timetable, tripIndex: tripIndex, stopIndex: stopIndex, pattern: tripPattern, today: today)
        return live
    }

    /// Up to `count` distinct itineraries, earliest departures first within each Pareto set.
    func plan(from origin: GeoPoint, to destination: GeoPoint, departAt: Date,
              live: LiveDelays? = nil, options: Options = Options(), count: Int = 4) -> [TransitRoute] {
        var results: [Journey] = []
        var seen = Set<[Int32]>()
        var start = departAt
        for _ in 0..<3 {
            let found = search(from: origin, to: destination, departAt: start, live: live, options: options)
            for j in found where seen.insert(j.signature).inserted { results.append(j) }
            // Next run: just after the earliest ride departure found, to surface later alternatives.
            guard results.count < count, let firstRide = found.compactMap(\.firstRideDeparture).min() else { break }
            start = firstRide.addingTimeInterval(60 - (found.first?.accessSeconds ?? 0))
        }
        results.sort { ($0.arrival, $0.rideCount) < ($1.arrival, $1.rideCount) }
        var routes = results.prefix(count).enumerated().map { i, j in j.route(id: i) }
        let straight = origin.distance(to: destination)
        if straight <= options.walkOnlyMeters {
            let seconds = Walking.seconds(meters: straight)
            routes.append(TransitRoute(id: routes.count, duration: seconds, durationText: minutesText(seconds),
                                       distanceText: nil, fareText: nil,
                                       segments: [.walk(.init(duration: seconds, distanceMeters: Int(Walking.meters(straightLine: straight)),
                                                               path: [origin, destination]))],
                                       warnings: []))
        }
        return routes
    }

    /// "Arrive by": the latest-leaving itineraries that still arrive by `deadline`.
    ///
    /// Earliest arrival never gets earlier when you leave later, so this binary-searches
    /// the departure time (forward RAPTOR at each probe) for the latest start that still
    /// arrives in time. Every in-time itinerary seen along the way is a candidate.
    func plan(from origin: GeoPoint, to destination: GeoPoint, arriveBy deadline: Date,
              live: LiveDelays? = nil, options: Options = Options(), count: Int = 4,
              window: TimeInterval = 2 * 3600, precision: TimeInterval = 60) -> [TransitRoute] {
        var results: [Journey] = []
        var seen = Set<[Int32]>()
        func probe(_ start: Date) -> Bool {
            let inTime = search(from: origin, to: destination, departAt: start, live: live, options: options)
                .filter { $0.arrival <= deadline }
            for j in inTime where seen.insert(j.signature).inserted { results.append(j) }
            return !inTime.isEmpty
        }

        // Find a start that works: 2 h before, then 4 h before for long trips.
        var lo = deadline.addingTimeInterval(-window)
        if !probe(lo) {
            lo = deadline.addingTimeInterval(-2 * window)
            if !probe(lo) { lo = deadline }
        }
        var hi = deadline
        while lo < deadline && hi.timeIntervalSince(lo) > precision {
            let mid = lo.addingTimeInterval(hi.timeIntervalSince(lo) / 2)
            if probe(mid) { lo = mid } else { hi = mid }
        }
        // A couple of earlier alternatives.
        for minutes in [15.0, 35.0] where results.count < count && lo < deadline {
            _ = probe(lo.addingTimeInterval(-minutes * 60))
        }

        // Latest departure first; among equal departures, fewer rides.
        results.sort { ($0.leaveTime, -$0.rideCount) > ($1.leaveTime, -$1.rideCount) }
        var routes = results.prefix(count).enumerated().map { i, j in j.route(id: i) }
        let straight = origin.distance(to: destination)
        if straight <= options.walkOnlyMeters {
            let seconds = Walking.seconds(meters: straight)
            routes.append(TransitRoute(id: routes.count, duration: seconds, durationText: minutesText(seconds),
                                       distanceText: nil, fareText: nil,
                                       segments: [.walk(.init(duration: seconds, distanceMeters: Int(Walking.meters(straightLine: straight)),
                                                               path: [origin, destination]))],
                                       warnings: []))
        }
        return routes
    }

    // MARK: - RAPTOR

    private struct Instance: Equatable {
        let trip: Int32
        let day: Int        // index into `days`
    }

    private struct Day {
        let serviceDay: ServiceDay
        let offset: Int32
        let active: [Bool]
    }

    private func search(from origin: GeoPoint, to destination: GeoPoint, departAt: Date,
                        live: LiveDelays?, options: Options) -> [Journey] {
        let tt = timetable
        let today = ServiceDay(containing: departAt)
        let days: [Day] = [(-1, Int32(-86_400)), (0, 0), (1, 86_400)].map { delta, offset in
            let d = today.adding(days: delta)
            return Day(serviceDay: d, offset: offset, active: tt.activeServices(on: d.date, weekday: d.weekday))
        }
        let t0 = Int32(departAt.timeIntervalSince(today.start))
        let S = tt.stopCount
        let never = Int32.max
        let rounds = options.maxRides

        func liveDelay(_ i: Instance, _ pos: Int) -> Int32 {
            live?.delay(trip: i.trip, date: days[i.day].serviceDay.date, position: pos) ?? 0
        }
        func dep(_ i: Instance, _ pos: Int) -> Int32 {
            tt.departures[Int(tt.tripEventStart[Int(i.trip)]) + pos] + days[i.day].offset + liveDelay(i, pos)
        }
        func arr(_ i: Instance, _ pos: Int) -> Int32 {
            tt.arrivals[Int(tt.tripEventStart[Int(i.trip)]) + pos] + days[i.day].offset + liveDelay(i, pos)
        }
        func usable(_ i: Instance, _ pos: Int, flag: UInt8) -> Bool {
            tt.eventFlags[Int(tt.tripEventStart[Int(i.trip)]) + pos] & flag == 0
                && !(live?.isSkipped(trip: i.trip, date: days[i.day].serviceDay.date, position: pos) ?? false)
        }
        func earliest(pattern p: Int, pos: Int, after t: Int32) -> Instance? {
            var best: Instance?
            var bestDep = never
            for trip in tt.trips(ofPattern: p) {
                let service = Int(tt.tripService[trip])
                for d in days.indices where days[d].active[service] {
                    let i = Instance(trip: Int32(trip), day: d)
                    if live?.isCanceled(trip: i.trip, date: days[d].serviceDay.date) == true { continue }
                    let time = dep(i, pos)
                    if time >= t && time < bestDep && usable(i, pos, flag: 1) { best = i; bestDep = time }
                }
            }
            return best
        }

        // Labels per round.
        var label = [[Int32]](repeating: [Int32](repeating: never, count: S), count: rounds + 1)
        var rideArr = label, walkArr = label
        var rideTrip = [[Int32]](repeating: [Int32](repeating: -1, count: S), count: rounds + 1)
        var rideDay = rideTrip, rideBoardPos = rideTrip, rideAlightPos = rideTrip, rideBoardStop = rideTrip
        var walkFrom = rideTrip
        var best = [Int32](repeating: never, count: S)

        var accessSeconds: [Int32: Int32] = [:]
        var marked = Set<Int32>()
        for (s, meters) in tt.stops(near: origin, within: options.accessMeters) {
            let w = Int32(Walking.seconds(meters: meters))
            label[0][s] = t0 + w
            best[s] = t0 + w
            accessSeconds[Int32(s)] = w
            marked.insert(Int32(s))
        }
        var egress: [(stop: Int, seconds: Int32)] = tt.stops(near: destination, within: options.accessMeters)
            .map { ($0.stop, Int32(Walking.seconds(meters: $0.meters))) }
        egress.sort { $0.seconds < $1.seconds }

        var destByRound = [Int32](repeating: never, count: rounds + 1)
        var destStop = [Int](repeating: -1, count: rounds + 1)
        var destBest = never

        for k in 1...rounds where !marked.isEmpty {
            label[k] = label[k - 1]

            // Patterns through marked stops, starting at their first marked position.
            var patterns = Set<Int32>()
            for s in marked {
                let lo = Int(tt.stopPatternStart[Int(s)]), hi = Int(tt.stopPatternStart[Int(s) + 1])
                for i in lo..<hi { patterns.insert(tt.stopPatterns[i]) }
            }
            var rideImproved: [Int32] = []
            for p32 in patterns {
                let p = Int(p32)
                let stops = tt.stops(ofPattern: p)
                guard let startPos = stops.firstIndex(where: { marked.contains($0) }).map({ $0 - stops.startIndex }) else { continue }
                var current: Instance?
                var boardPos = 0
                for pos in startPos..<stops.count {
                    let s = Int(stops[stops.startIndex + pos])
                    if let c = current, usable(c, pos, flag: 2) {
                        let a = arr(c, pos)
                        if a < best[s] && a < destBest {
                            label[k][s] = a; rideArr[k][s] = a; best[s] = a
                            rideTrip[k][s] = c.trip; rideDay[k][s] = Int32(c.day)
                            rideBoardPos[k][s] = Int32(boardPos); rideAlightPos[k][s] = Int32(pos)
                            rideBoardStop[k][s] = stops[stops.startIndex + boardPos]
                            rideImproved.append(Int32(s))
                        }
                    }
                    let prev = label[k - 1][s]
                    if prev != never, current.map({ prev <= dep($0, pos) }) ?? true,
                       let e = earliest(pattern: p, pos: pos, after: prev),
                       current.map({ dep(e, pos) < dep($0, pos) }) ?? true {
                        current = e
                        boardPos = pos
                    }
                }
            }

            // One walking transfer after each ride.
            var nextMarked = Set(rideImproved)
            for s in rideImproved {
                let base = rideArr[k][Int(s)]
                let lo = Int(tt.transferStart[Int(s)]), hi = Int(tt.transferStart[Int(s) + 1])
                for i in lo..<hi {
                    let to = Int(tt.transferTo[i])
                    let t = base + tt.transferSeconds[i]
                    if t < best[to] && t < destBest {
                        label[k][to] = t; walkArr[k][to] = t; walkFrom[k][to] = s; best[to] = t
                        nextMarked.insert(Int32(to))
                    }
                }
            }
            marked = nextMarked

            for (s, e) in egress where label[k][s] != never {
                let total = label[k][s] + e
                if total < destByRound[k] { destByRound[k] = total; destStop[k] = s }
            }
            destBest = min(destBest, destByRound[k])
        }

        // Reconstruct one journey per round that improves on fewer rides.
        var journeys: [Journey] = []
        var bestSoFar = never
        for k in 1...rounds where destByRound[k] < bestSoFar && destStop[k] >= 0 {
            bestSoFar = destByRound[k]
            var legs: [Journey.Leg] = []
            var s = destStop[k]
            var round = k
            let egressSeconds = egress.first { $0.stop == s }!.seconds
            legs.append(.walk(from: Int32(s), to: -1, seconds: egressSeconds))
            var ok = true
            while round > 0 {
                if rideTrip[round][s] >= 0 && rideArr[round][s] == label[round][s] {
                    let i = Instance(trip: rideTrip[round][s], day: Int(rideDay[round][s]))
                    let b = Int(rideBoardPos[round][s]), a = Int(rideAlightPos[round][s])
                    legs.append(.ride(trip: i.trip, serviceDay: days[i.day].serviceDay, boardPos: b, alightPos: a,
                                      departure: dep(i, b), arrival: arr(i, a),
                                      delay: live?.delay(trip: i.trip, date: days[i.day].serviceDay.date, position: b)))
                    s = Int(rideBoardStop[round][s])
                    round -= 1
                } else if walkFrom[round][s] >= 0 && walkArr[round][s] == label[round][s] {
                    let from = Int(walkFrom[round][s])
                    legs.append(.walk(from: Int32(from), to: Int32(s), seconds: walkArr[round][s] - rideArr[round][from]))
                    s = from
                    // The stop we walked from was reached by a ride in this same round.
                    guard rideTrip[round][s] >= 0 else { ok = false; break }
                } else if label[round - 1][s] == label[round][s] {
                    round -= 1   // label copied from the previous round
                } else {
                    ok = false; break
                }
            }
            guard ok, let access = accessSeconds[Int32(s)] else { continue }
            legs.append(.walk(from: -1, to: Int32(s), seconds: access))
            journeys.append(Journey(timetable: tt, today: today, departAt: departAt, origin: origin, destination: destination,
                                    legs: legs.reversed(), arrivalSeconds: destByRound[k]))
        }
        return journeys
    }
}

// MARK: - Journeys

private struct Journey {
    enum Leg {
        /// -1 = origin/destination
        case walk(from: Int32, to: Int32, seconds: Int32)
        case ride(trip: Int32, serviceDay: ServiceDay, boardPos: Int, alightPos: Int,
                  departure: Int32, arrival: Int32, delay: Int32?)
    }

    let timetable: Timetable
    let today: ServiceDay
    let departAt: Date
    let origin: GeoPoint
    let destination: GeoPoint
    let legs: [Leg]
    let arrivalSeconds: Int32

    var arrival: Date { today.start.addingTimeInterval(TimeInterval(arrivalSeconds)) }
    var rideCount: Int { legs.filter { if case .ride = $0 { return true } else { return false } }.count }
    var signature: [Int32] { legs.compactMap { if case .ride(let t, _, _, _, _, _, _) = $0 { return t } else { return nil } } }

    /// When you leave the origin.
    var leaveTime: Date {
        firstRideDeparture.map { $0.addingTimeInterval(-accessSeconds) } ?? departAt
    }

    var accessSeconds: TimeInterval {
        if case .walk(_, _, let s)? = legs.first { return TimeInterval(s) }
        return 0
    }

    var firstRideDeparture: Date? {
        for leg in legs {
            if case .ride(_, _, _, _, let dep, _, _) = leg { return today.start.addingTimeInterval(TimeInterval(dep)) }
        }
        return nil
    }

    func route(id: Int) -> TransitRoute {
        let tt = timetable
        var segments: [TransitRoute.Segment] = []
        for leg in legs {
            switch leg {
            case .walk(let from, let to, let seconds):
                let a = from >= 0 ? tt.point(ofStop: Int(from)) : origin
                let b = to >= 0 ? tt.point(ofStop: Int(to)) : destination
                let meters = Walking.meters(straightLine: a.distance(to: b))
                if seconds > 0 {
                    if case .walk(var w)? = segments.last {
                        w.duration += TimeInterval(seconds); w.distanceMeters += Int(meters)
                        w.path.append(b)
                        segments[segments.count - 1] = .walk(w)
                    } else {
                        // Straight line: this planner has no street network.
                        segments.append(.walk(.init(duration: TimeInterval(seconds), distanceMeters: Int(meters), path: [a, b])))
                    }
                }
            case .ride(let trip, _, let b, let a, let depS, let arrS, let delay):
                let t = Int(trip)
                let p = tt.patternOfTrip(t)
                let stops = tt.stops(ofPattern: p)
                let boardStop = Int(stops[stops.startIndex + b]), alightStop = Int(stops[stops.startIndex + a])
                let route = Int(tt.patternRoute[p])
                let type = tt.routeTypes[route]
                let isRail = type == 2
                let short = tt.routeShortNames[route]
                let long = tt.routeLongNames[route]
                let rawTrip = String(tt.tripIDs[t].dropFirst(2))
                segments.append(.ride(TransitRoute.Ride(
                    lineName: long.isEmpty ? nil : long,
                    lineShortName: isRail ? nil : (short.isEmpty ? nil : short),
                    lineColor: tt.routeColors[route].isEmpty ? nil : "#" + tt.routeColors[route],
                    lineTextColor: tt.routeTextColors[route].isEmpty ? nil : "#" + tt.routeTextColors[route],
                    vehicleType: Self.vehicleType(type),
                    vehicleName: Self.vehicleName(type),
                    agencyNames: ["SEPTA"],
                    headsign: tt.headsigns[Int(tt.tripHeadsign[t])],
                    departureStopName: tt.stopNames[boardStop],
                    departureStop: tt.point(ofStop: boardStop),
                    arrivalStopName: tt.stopNames[alightStop],
                    departureTime: today.start.addingTimeInterval(TimeInterval(depS)),
                    arrivalTime: today.start.addingTimeInterval(TimeInterval(arrS)),
                    departureTimeText: nil,
                    arrivalTimeText: nil,
                    stopCount: a - b,
                    duration: TimeInterval(arrS - depS),
                    tripID: rawTrip,
                    trainNumber: isRail ? Self.trainNumber(tt.tripShortNames[t], tripID: rawTrip) : nil,
                    liveDelaySeconds: delay.map(Int.init),
                    routeShortName: short.isEmpty ? nil : short,
                    // Stop by stop (SEPTA's route shapes aren't downloaded, to save space).
                    path: stops[(stops.startIndex + b)...(stops.startIndex + a)].map { tt.point(ofStop: Int($0)) }
                )))
            }
        }
        let start = firstRideDeparture.map { $0.addingTimeInterval(-accessSeconds) } ?? departAt
        let total = arrival.timeIntervalSince(start)
        return TransitRoute(id: id, duration: total, durationText: minutesText(total), distanceText: nil,
                            fareText: nil, segments: segments, warnings: [])
    }

    static func vehicleType(_ routeType: Int32) -> String {
        switch routeType {
        case 0: return "TRAM"
        case 1: return "SUBWAY"
        case 2: return "COMMUTER_TRAIN"
        case 11: return "TROLLEYBUS"
        default: return "BUS"
        }
    }

    static func vehicleName(_ routeType: Int32) -> String {
        switch routeType {
        case 0: return "Trolley"
        case 1: return "Subway"
        case 2: return "Regional Rail"
        case 11: return "Trackless trolley"
        default: return "Bus"
        }
    }

    /// "CYN1052" → "1052"; falls back to the digits in the trip ID ("PAO9566_…").
    static func trainNumber(_ shortName: String, tripID: String) -> String? {
        let digits = shortName.drop { $0.isLetter }
        if !digits.isEmpty, digits.allSatisfy(\.isNumber) { return String(digits) }
        let head = tripID.prefix { $0 != "_" }.drop { $0.isLetter }
        return !head.isEmpty && head.allSatisfy(\.isNumber) ? String(head) : nil
    }
}

extension Timetable {
    /// Binary search over pattern trip ranges.
    func patternOfTrip(_ trip: Int) -> Int {
        var lo = 0, hi = patternCount - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if Int(patternTripStart[mid]) <= trip { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}

/// Shared with the UI.
func minutesText(_ seconds: TimeInterval) -> String {
    let minutes = max(1, Int((seconds / 60).rounded()))
    return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) hr \(minutes % 60) min"
}
