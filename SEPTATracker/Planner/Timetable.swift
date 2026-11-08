import Foundation

/// SEPTA's bus/trolley/subway and Regional Rail schedules compiled into flat arrays for
/// on-device routing (RAPTOR). Built from SEPTA's published GTFS
/// (https://github.com/septadev/GTFS), cached on disk in a compact binary form.
///
/// IDs from the two feeds are prefixed ("b:" bus feed, "r:" rail feed) so they can't collide.
/// Times are seconds after the service day's start (GTFS "noon minus 12h"); they can
/// exceed 24h for trips running past midnight.
struct Timetable {
    static let formatVersion: Int32 = 1

    // Stops (boardable stops only; stations without location_type 0 are dropped)
    var stopIDs: [String] = []
    var stopNames: [String] = []
    var stopLat: [Double] = []
    var stopLon: [Double] = []

    // Routes
    var routeIDs: [String] = []
    var routeShortNames: [String] = []
    var routeLongNames: [String] = []
    var routeColors: [String] = []
    var routeTextColors: [String] = []
    /// GTFS route_type: 0 tram, 1 subway, 2 rail, 3 bus, 11 trolleybus.
    var routeTypes: [Int32] = []

    // Service calendars
    var serviceIDs: [String] = []
    /// Bit 0 = Monday … bit 6 = Sunday.
    var serviceWeekdays: [Int32] = []
    var serviceStart: [Int32] = []   // yyyymmdd
    var serviceEnd: [Int32] = []
    var exceptionService: [Int32] = []
    var exceptionDate: [Int32] = []
    /// 1 = added, 2 = removed.
    var exceptionType: [Int32] = []

    // Patterns: a route plus an exact stop sequence. Trips in a pattern share stops.
    var patternRoute: [Int32] = []
    /// patternStops[patternStopStart[p] ..< patternStopStart[p+1]]
    var patternStopStart: [Int32] = [0]
    var patternStops: [Int32] = []
    /// Trips of pattern p are tripIndex patternTripStart[p] ..< patternTripStart[p+1].
    var patternTripStart: [Int32] = [0]

    // Trips, grouped by pattern and sorted by first departure.
    var tripIDs: [String] = []
    var tripShortNames: [String] = []
    var tripHeadsign: [Int32] = []      // index into headsigns
    var headsigns: [String] = []
    var tripService: [Int32] = []
    /// Offset of this trip's first stop event in `arrivals`/`departures`/`eventFlags`.
    var tripEventStart: [Int32] = []
    var arrivals: [Int32] = []
    var departures: [Int32] = []
    /// Bit 0 = no pickup, bit 1 = no drop-off.
    var eventFlags: [UInt8] = []

    // Stop → patterns serving it
    var stopPatternStart: [Int32] = [0]
    var stopPatterns: [Int32] = []

    // Walking transfers between nearby stops
    var transferStart: [Int32] = [0]
    var transferTo: [Int32] = []
    var transferSeconds: [Int32] = []

    // Metadata
    var feedVersion = ""
    var validFrom: Int32 = 0
    var validTo: Int32 = 0
    var builtAt: Double = 0

    var stopCount: Int { stopIDs.count }
    var patternCount: Int { patternRoute.count }

    func stops(ofPattern p: Int) -> ArraySlice<Int32> {
        patternStops[Int(patternStopStart[p])..<Int(patternStopStart[p + 1])]
    }

    func trips(ofPattern p: Int) -> Range<Int> {
        Int(patternTripStart[p])..<Int(patternTripStart[p + 1])
    }

    func point(ofStop s: Int) -> GeoPoint { GeoPoint(latitude: stopLat[s], longitude: stopLon[s]) }

    /// Indexes of boardable stops within `meters` of `point`.
    func stops(near point: GeoPoint, within meters: Double) -> [(stop: Int, meters: Double)] {
        let dLat = meters / 111_000
        let dLon = meters / (111_000 * cos(point.latitude * .pi / 180))
        var result: [(Int, Double)] = []
        for s in 0..<stopCount {
            guard abs(stopLat[s] - point.latitude) <= dLat, abs(stopLon[s] - point.longitude) <= dLon else { continue }
            let d = point.distance(to: self.point(ofStop: s))
            if d <= meters { result.append((s, d)) }
        }
        return result
    }
}

// MARK: - Calendar

extension Timetable {
    /// Which services run on `date` (yyyymmdd) with `weekday` (0 = Monday).
    func activeServices(on date: Int32, weekday: Int) -> [Bool] {
        var active = (0..<serviceIDs.count).map { s in
            serviceStart[s] <= date && date <= serviceEnd[s] && (serviceWeekdays[s] >> weekday) & 1 == 1
        }
        for i in exceptionDate.indices where exceptionDate[i] == date {
            active[Int(exceptionService[i])] = exceptionType[i] == 1
        }
        return active
    }
}

// MARK: - Building from GTFS

extension Timetable {
    enum BuildError: LocalizedError {
        case missingColumn(String, String)
        case empty
        var errorDescription: String? {
            switch self {
            case .missingColumn(let file, let col): return "SEPTA schedule file \(file) has no \(col) column."
            case .empty: return "SEPTA's schedule contained no trips."
            }
        }
    }

    /// Builds from SEPTA's `gtfs_public.zip` (which contains google_bus.zip and google_rail.zip).
    static func build(fromSEPTAZip data: Data, now: Date = Date()) throws -> Timetable {
        let outer = try ZipArchive(data)
        var feeds: [(prefix: String, zip: ZipArchive)] = []
        if outer.entry(named: "stop_times.txt") != nil {
            feeds.append(("b:", outer))   // a single plain GTFS zip
        } else {
            feeds.append(("b:", try ZipArchive(bytes: try outer.contents(of: "google_bus.zip"))))
            feeds.append(("r:", try ZipArchive(bytes: try outer.contents(of: "google_rail.zip"))))
        }
        var builder = Builder()
        for feed in feeds {
            try builder.add(feed: feed.zip, prefix: feed.prefix)
        }
        return try builder.finish(builtAt: now)
    }

    struct Builder {
        var t = Timetable()
        var stopIndex: [String: Int32] = [:]
        var routeIndex: [String: Int32] = [:]
        var serviceIndex: [String: Int32] = [:]
        var headsignIndex: [String: Int32] = [:]

        // Raw trips before pattern grouping
        var rawTripID: [String] = []
        var rawShortName: [String] = []
        var rawRoute: [Int32] = []
        var rawService: [Int32] = []
        var rawHeadsign: [Int32] = []
        var rawEvents: [[(seq: Int32, stop: Int32, arr: Int32, dep: Int32, flags: UInt8)]] = []
        var droppedTrips = 0

        mutating func add(feed zip: ZipArchive, prefix: String) throws {
            if let info = try? zip.contents(of: "feed_info.txt") {
                let r = CSVReader(info)
                r.forEachRow { row in
                    let v = row.string(r.column("feed_version"))
                    if !v.isEmpty { t.feedVersion += (t.feedVersion.isEmpty ? "" : "+") + v }
                }
            }

            // stops.txt
            let stops = CSVReader(try zip.contents(of: "stops.txt"))
            guard let cID = stops.column("stop_id") else { throw BuildError.missingColumn("stops.txt", "stop_id") }
            let cName = stops.column("stop_name"), cLat = stops.column("stop_lat"), cLon = stops.column("stop_lon")
            let cType = stops.column("location_type")
            stops.forEachRow { row in
                let type = row.int(cType) ?? 0
                guard type == 0, let lat = row.double(cLat), let lon = row.double(cLon) else { return }
                let id = prefix + row.string(cID)
                stopIndex[id] = Int32(t.stopIDs.count)
                t.stopIDs.append(id)
                t.stopNames.append(row.string(cName))
                t.stopLat.append(lat)
                t.stopLon.append(lon)
            }

            // routes.txt
            let routes = CSVReader(try zip.contents(of: "routes.txt"))
            guard let rID = routes.column("route_id") else { throw BuildError.missingColumn("routes.txt", "route_id") }
            routes.forEachRow { row in
                let id = prefix + row.string(rID)
                routeIndex[id] = Int32(t.routeIDs.count)
                t.routeIDs.append(id)
                t.routeShortNames.append(row.string(routes.column("route_short_name")))
                t.routeLongNames.append(row.string(routes.column("route_long_name")))
                t.routeColors.append(row.string(routes.column("route_color")))
                t.routeTextColors.append(row.string(routes.column("route_text_color")))
                t.routeTypes.append(Int32(row.int(routes.column("route_type")) ?? 3))
            }

            // calendar.txt / calendar_dates.txt
            func service(_ raw: String) -> Int32 {
                let id = prefix + raw
                if let i = serviceIndex[id] { return i }
                let i = Int32(t.serviceIDs.count)
                serviceIndex[id] = i
                t.serviceIDs.append(id)
                t.serviceWeekdays.append(0)
                t.serviceStart.append(0)
                t.serviceEnd.append(0)
                return i
            }
            if let bytes = try? zip.contents(of: "calendar.txt") {
                let cal = CSVReader(bytes)
                let days = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"].map { cal.column($0) }
                cal.forEachRow { row in
                    let s = Int(service(row.string(cal.column("service_id"))))
                    var mask: Int32 = 0
                    for (bit, c) in days.enumerated() where row.int(c) == 1 { mask |= 1 << bit }
                    t.serviceWeekdays[s] = mask
                    t.serviceStart[s] = Int32(row.int(cal.column("start_date")) ?? 0)
                    t.serviceEnd[s] = Int32(row.int(cal.column("end_date")) ?? 0)
                }
            }
            if let bytes = try? zip.contents(of: "calendar_dates.txt") {
                let cd = CSVReader(bytes)
                cd.forEachRow { row in
                    guard let date = row.int(cd.column("date")), let type = row.int(cd.column("exception_type")) else { return }
                    t.exceptionService.append(service(row.string(cd.column("service_id"))))
                    t.exceptionDate.append(Int32(date))
                    t.exceptionType.append(Int32(type))
                }
            }

            // trips.txt
            let trips = CSVReader(try zip.contents(of: "trips.txt"))
            guard let tID = trips.column("trip_id") else { throw BuildError.missingColumn("trips.txt", "trip_id") }
            var localTrip: [String: Int] = [:]
            trips.forEachRow { row in
                guard let route = routeIndex[prefix + row.string(trips.column("route_id"))] else { return }
                let headsign = row.string(trips.column("trip_headsign"))
                let h: Int32
                if let existing = headsignIndex[headsign] { h = existing } else {
                    h = Int32(t.headsigns.count)
                    headsignIndex[headsign] = h
                    t.headsigns.append(headsign)
                }
                let raw = row.string(tID)
                localTrip[raw] = rawTripID.count
                rawTripID.append(prefix + raw)
                rawShortName.append(row.string(trips.column("trip_short_name")))
                rawRoute.append(route)
                rawService.append(service(row.string(trips.column("service_id"))))
                rawHeadsign.append(h)
                rawEvents.append([])
            }

            // stop_times.txt
            let st = CSVReader(try zip.contents(of: "stop_times.txt"))
            guard let sTrip = st.column("trip_id"), let sStop = st.column("stop_id") else {
                throw BuildError.missingColumn("stop_times.txt", "trip_id/stop_id")
            }
            let sArr = st.column("arrival_time"), sDep = st.column("departure_time"), sSeq = st.column("stop_sequence")
            let sPick = st.column("pickup_type"), sDrop = st.column("drop_off_type")
            var missing = Set<Int>()
            st.forEachRow { row in
                guard let trip = localTrip[row.string(sTrip)] else { return }
                guard let stop = stopIndex[prefix + row.string(sStop)] else { missing.insert(trip); return }
                let arr = row.time(sArr), dep = row.time(sDep)
                guard let a = arr ?? dep, let d = dep ?? arr else { missing.insert(trip); return }
                var flags: UInt8 = 0
                if row.int(sPick) == 1 { flags |= 1 }
                if row.int(sDrop) == 1 { flags |= 2 }
                rawEvents[trip].append((Int32(row.int(sSeq) ?? 0), stop, a, d, flags))
            }
            // Trips with untimed or unknown stops are dropped rather than interpolated.
            for trip in missing { rawEvents[trip] = [] }
            droppedTrips += missing.count
        }

        mutating func finish(builtAt: Date) throws -> Timetable {
            // Group trips into patterns.
            var patternOf: [[Int32]: Int] = [:]
            var patternTrips: [[Int]] = []
            var patternStops: [[Int32]] = []
            var patternRoutes: [Int32] = []
            for trip in rawEvents.indices where rawEvents[trip].count >= 2 {
                rawEvents[trip].sort { $0.seq < $1.seq }
                let stops = rawEvents[trip].map(\.stop)
                let key = [rawRoute[trip]] + stops
                if let p = patternOf[key] {
                    patternTrips[p].append(trip)
                } else {
                    patternOf[key] = patternTrips.count
                    patternTrips.append([trip])
                    patternStops.append(stops)
                    patternRoutes.append(rawRoute[trip])
                }
            }
            guard !patternTrips.isEmpty else { throw BuildError.empty }

            for p in patternTrips.indices {
                t.patternRoute.append(patternRoutes[p])
                t.patternStops.append(contentsOf: patternStops[p])
                t.patternStopStart.append(Int32(t.patternStops.count))
                for trip in patternTrips[p].sorted(by: { rawEvents[$0][0].dep < rawEvents[$1][0].dep }) {
                    t.tripIDs.append(rawTripID[trip])
                    t.tripShortNames.append(rawShortName[trip])
                    t.tripHeadsign.append(rawHeadsign[trip])
                    t.tripService.append(rawService[trip])
                    t.tripEventStart.append(Int32(t.arrivals.count))
                    for e in rawEvents[trip] {
                        t.arrivals.append(e.arr)
                        t.departures.append(e.dep)
                        t.eventFlags.append(e.flags)
                    }
                }
                t.patternTripStart.append(Int32(t.tripIDs.count))
            }
            rawEvents = []

            // Stop → patterns.
            var byStop = [[Int32]](repeating: [], count: t.stopCount)
            for p in 0..<t.patternCount {
                for s in Set(t.stops(ofPattern: p)) { byStop[Int(s)].append(Int32(p)) }
            }
            for list in byStop {
                t.stopPatterns.append(contentsOf: list)
                t.stopPatternStart.append(Int32(t.stopPatterns.count))
            }

            buildTransfers()

            // Validity: the span covered by calendars that actually have trips.
            let used = Set(t.tripService)
            let starts = used.map { Int(t.serviceStart[Int($0)]) }.filter { $0 > 0 }
            let ends = used.map { Int(t.serviceEnd[Int($0)]) }.filter { $0 > 0 }
            t.validFrom = Int32(starts.min() ?? 0)
            t.validTo = Int32(ends.max() ?? 0)
            t.builtAt = builtAt.timeIntervalSince1970
            return t
        }

        /// Walking links between stops within `maxMeters`, using a coarse grid.
        mutating func buildTransfers(maxMeters: Double = 400) {
            let cell = 0.003
            var grid: [Int64: [Int32]] = [:]
            func key(_ lat: Double, _ lon: Double) -> (Int64, Int64) { (Int64((lat / cell).rounded(.down)), Int64((lon / cell).rounded(.down))) }
            for s in 0..<t.stopCount {
                let (a, b) = key(t.stopLat[s], t.stopLon[s])
                grid[a << 32 ^ b, default: []].append(Int32(s))
            }
            for s in 0..<t.stopCount {
                let (a, b) = key(t.stopLat[s], t.stopLon[s])
                let here = t.point(ofStop: s)
                for da in -1...1 { for db in -1...1 {
                    for other in grid[(a + Int64(da)) << 32 ^ (b + Int64(db))] ?? [] where Int(other) != s {
                        let d = here.distance(to: t.point(ofStop: Int(other)))
                        guard d <= maxMeters else { continue }
                        t.transferTo.append(other)
                        t.transferSeconds.append(Int32(Walking.seconds(meters: d)))
                    }
                }}
                t.transferStart.append(Int32(t.transferTo.count))
            }
        }
    }
}

/// Walking assumptions shared by the builder and the router.
enum Walking {
    /// 1.3 m/s (~2.9 mph), with straight-line distance stretched 25% for streets.
    static func seconds(meters: Double) -> Double { meters * 1.25 / 1.3 }
    static func meters(straightLine: Double) -> Double { straightLine * 1.25 }
}

// MARK: - Binary serialization

extension Timetable {
    enum CacheError: Error { case badFormat }

    func serialized() -> Data {
        var w = BinaryWriter()
        w.int32(0x5350_5454) // "SPTT"
        w.int32(Self.formatVersion)
        w.strings(stopIDs); w.strings(stopNames); w.doubles(stopLat); w.doubles(stopLon)
        w.strings(routeIDs); w.strings(routeShortNames); w.strings(routeLongNames)
        w.strings(routeColors); w.strings(routeTextColors); w.int32s(routeTypes)
        w.strings(serviceIDs); w.int32s(serviceWeekdays); w.int32s(serviceStart); w.int32s(serviceEnd)
        w.int32s(exceptionService); w.int32s(exceptionDate); w.int32s(exceptionType)
        w.int32s(patternRoute); w.int32s(patternStopStart); w.int32s(patternStops); w.int32s(patternTripStart)
        w.strings(tripIDs); w.strings(tripShortNames); w.int32s(tripHeadsign); w.strings(headsigns)
        w.int32s(tripService); w.int32s(tripEventStart); w.int32s(arrivals); w.int32s(departures); w.bytes(eventFlags)
        w.int32s(stopPatternStart); w.int32s(stopPatterns)
        w.int32s(transferStart); w.int32s(transferTo); w.int32s(transferSeconds)
        w.strings([feedVersion]); w.int32(validFrom); w.int32(validTo); w.doubles([builtAt])
        return w.data
    }

    init(serialized data: Data) throws {
        var r = BinaryReader([UInt8](data))
        guard try r.int32() == 0x5350_5454, try r.int32() == Self.formatVersion else { throw CacheError.badFormat }
        stopIDs = try r.strings(); stopNames = try r.strings(); stopLat = try r.doubles(); stopLon = try r.doubles()
        routeIDs = try r.strings(); routeShortNames = try r.strings(); routeLongNames = try r.strings()
        routeColors = try r.strings(); routeTextColors = try r.strings(); routeTypes = try r.int32s()
        serviceIDs = try r.strings(); serviceWeekdays = try r.int32s(); serviceStart = try r.int32s(); serviceEnd = try r.int32s()
        exceptionService = try r.int32s(); exceptionDate = try r.int32s(); exceptionType = try r.int32s()
        patternRoute = try r.int32s(); patternStopStart = try r.int32s(); patternStops = try r.int32s(); patternTripStart = try r.int32s()
        tripIDs = try r.strings(); tripShortNames = try r.strings(); tripHeadsign = try r.int32s(); headsigns = try r.strings()
        tripService = try r.int32s(); tripEventStart = try r.int32s(); arrivals = try r.int32s(); departures = try r.int32s(); eventFlags = try r.bytes()
        stopPatternStart = try r.int32s(); stopPatterns = try r.int32s()
        transferStart = try r.int32s(); transferTo = try r.int32s(); transferSeconds = try r.int32s()
        feedVersion = try r.strings().first ?? ""; validFrom = try r.int32(); validTo = try r.int32(); builtAt = try r.doubles().first ?? 0
        guard stopLat.count == stopIDs.count, arrivals.count == departures.count,
              patternStopStart.count == patternRoute.count + 1, tripEventStart.count == tripIDs.count
        else { throw CacheError.badFormat }
    }
}

private struct BinaryWriter {
    var data = Data()

    mutating func int32(_ v: Int32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func int32s(_ a: [Int32]) {
        int32(Int32(a.count))
        a.map(\.littleEndian).withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
    }
    mutating func doubles(_ a: [Double]) {
        int32(Int32(a.count))
        a.map { $0.bitPattern.littleEndian }.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
    }
    mutating func bytes(_ a: [UInt8]) { int32(Int32(a.count)); data.append(contentsOf: a) }
    mutating func strings(_ a: [String]) {
        var blob: [UInt8] = []
        var lengths: [Int32] = []
        lengths.reserveCapacity(a.count)
        for s in a { let u = Array(s.utf8); lengths.append(Int32(u.count)); blob.append(contentsOf: u) }
        int32s(lengths)
        bytes(blob)
    }
}

private struct BinaryReader {
    let b: [UInt8]
    var i = 0
    init(_ b: [UInt8]) { self.b = b }

    mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard n >= 0, i + n <= b.count else { throw Timetable.CacheError.badFormat }
        defer { i += n }
        return b[i..<(i + n)]
    }
    mutating func int32() throws -> Int32 {
        let s = try take(4)
        return s.withUnsafeBytes { Int32(littleEndian: $0.loadUnaligned(as: Int32.self)) }
    }
    mutating func count() throws -> Int {
        let n = Int(try int32())
        guard n >= 0 else { throw Timetable.CacheError.badFormat }
        return n
    }
    mutating func int32s() throws -> [Int32] {
        let n = try count()
        let s = try take(n * 4)
        return s.withUnsafeBytes { raw in (0..<n).map { Int32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: Int32.self)) } }
    }
    mutating func doubles() throws -> [Double] {
        let n = try count()
        let s = try take(n * 8)
        return s.withUnsafeBytes { raw in (0..<n).map { Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 8, as: UInt64.self))) } }
    }
    mutating func bytes() throws -> [UInt8] { Array(try take(try count())) }
    mutating func strings() throws -> [String] {
        let lengths = try int32s()
        let blob = try bytes()
        var out: [String] = []
        out.reserveCapacity(lengths.count)
        var p = 0
        for l in lengths {
            let n = Int(l)
            guard n >= 0, p + n <= blob.count else { throw Timetable.CacheError.badFormat }
            out.append(String(decoding: blob[p..<(p + n)], as: UTF8.self))
            p += n
        }
        return out
    }
}
