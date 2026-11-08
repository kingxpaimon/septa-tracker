import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // Linux only; lets the parser tests run off-Mac.
#endif

enum SEPTAError: LocalizedError {
    case badStatus(Int)
    case unexpectedFormat(String)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "SEPTA returned HTTP \(code)."
        case .unexpectedFormat(let detail): return "Unexpected response from SEPTA: \(detail)"
        }
    }
}

/// Reads SEPTA's public real-time JSON endpoints. No API key is needed.
///
/// SEPTA publishes no formal spec for these feeds. The field names and types below
/// were checked against live responses captured in November 2026 (see the fixtures
/// in SEPTATrackerTests/Fixtures). Parsing is still lenient: a vehicle with no usable
/// coordinates is skipped rather than failing the whole response.
struct SEPTAClient {
    static let baseURL = URL(string: "https://www3.septa.org/api/")!

    var session: URLSession = .shared

    static let busRealtimeURL = URL(string: "https://www3.septa.org/gtfsrt/septa-pa-us/Vehicle/rtVehiclePosition.pb")!
    static let railRealtimeURL = URL(string: "https://www3.septa.org/gtfsrt/septarail-pa-us/Vehicle/rtVehiclePosition.pb")!

    /// All buses and trolleys currently reporting: TransitView merged with GTFS-realtime.
    /// If only one of the two feeds fails, the other is used alone.
    func fetchSurfaceVehicles() async throws -> [Vehicle] {
        async let json = Self.capture { try Self.parseTransitViewAllEntries(try await get(Self.baseURL.appendingPathComponent("TransitViewAll/index.php"))) }
        async let realtime = Self.capture { try GTFSRealtime.parseVehiclePositions(try await get(Self.busRealtimeURL)) }
        let (entries, positions) = await (json, realtime)
        switch (entries, positions) {
        case (.success(let e), .success(let p)): return VehicleMerger.mergeSurface(transitView: e, realtime: p)
        case (.success(let e), .failure): return VehicleMerger.mergeSurface(transitView: e, realtime: [])
        case (.failure, .success(let p)): return VehicleMerger.mergeSurface(transitView: [], realtime: p)
        case (.failure(let error), .failure): throw error
        }
    }

    /// All Regional Rail trains currently reporting: TrainView, with GTFS-realtime
    /// positions where a train matches. Trains only in GTFS-RT aren't added, because
    /// its line codes ("PAO") don't map cleanly to TrainView line names.
    func fetchTrains() async throws -> [Vehicle] {
        async let json = Self.capture { try Self.parseTrainView(try await get(Self.baseURL.appendingPathComponent("TrainView/index.php"))) }
        async let realtime = Self.capture { try GTFSRealtime.parseVehiclePositions(try await get(Self.railRealtimeURL)) }
        let (trains, positions) = await (json, realtime)
        let base = try trains.get()
        return VehicleMerger.mergeRail(trainView: base, realtime: (try? positions.get()) ?? [])
    }

    private static func capture<T>(_ work: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SEPTAError.badStatus(http.statusCode)
        }
        return data
    }

    // MARK: - Parsing

    /// Observed shape: `{"routes": [{"17": [{vehicle}, ...], "33": [...]}]}`, i.e. an
    /// array holding a single object keyed by route. `routes` as a bare object is also
    /// accepted.
    ///
    /// Observed vehicle fields (types as sent):
    /// `lat`/`lng` (string), `label`/`VehicleID` (string, always equal), `route_id`,
    /// `Direction` ("NorthBound", "Loop", ...), `destination`, `heading` (int),
    /// `late` (int minutes, 998 = no estimate), `Offset` (string minutes, same as `late`),
    /// `Offset_sec` (string, the same schedule deviation in seconds — NOT report age),
    /// `next_stop_name` (string or null), `timestamp` (int Unix seconds of the GPS fix).
    ///
    /// The feed can list the same vehicle twice, at the same position, under two trip IDs:
    /// the trip it's running (usually late) and its next trip (`late: 0`). This collapses
    /// them with `VehicleMerger.resolveDuplicates`; with GTFS-RT available,
    /// `fetchSurfaceVehicles` resolves them by trip ID instead.
    static func parseTransitViewAll(_ data: Data) throws -> [Vehicle] {
        VehicleMerger.resolveDuplicates(try parseTransitViewAllEntries(data))
    }

    /// Every TransitView entry, duplicates included.
    static func parseTransitViewAllEntries(_ data: Data) throws -> [Vehicle] {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let top = root as? [String: Any] else {
            throw SEPTAError.unexpectedFormat("TransitViewAll is not a JSON object")
        }

        let routeMaps: [[String: Any]]
        if let list = top["routes"] as? [[String: Any]] {
            routeMaps = list
        } else if let single = top["routes"] as? [String: Any] {
            routeMaps = [single]
        } else {
            throw SEPTAError.unexpectedFormat("TransitViewAll has no \"routes\"")
        }

        var vehicles: [Vehicle] = []
        for routeMap in routeMaps {
            for (route, entries) in routeMap {
                guard let entries = entries as? [[String: Any]] else { continue }
                let mode = TransitMode.forSurfaceRoute(route)
                for entry in entries {
                    if let vehicle = surfaceVehicle(from: entry, route: route, mode: mode) {
                        vehicles.append(vehicle)
                    }
                }
            }
        }
        return vehicles
    }

    private static func surfaceVehicle(from entry: [String: Any], route: String, mode: TransitMode) -> Vehicle? {
        guard
            let lat = JSONValues.double(entry, "lat"),
            let lon = JSONValues.double(entry, "lng", "lon"),
            isPlausible(lat: lat, lon: lon)
        else { return nil }

        let label = JSONValues.string(entry, "label", "VehicleID") ?? "?"
        let reportedAt = JSONValues.double(entry, "timestamp")
            .flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }

        return Vehicle(
            id: "\(mode.rawValue)-\(route)-\(label)",
            mode: mode,
            route: route,
            label: label,
            latitude: lat,
            longitude: lon,
            heading: JSONValues.double(entry, "heading"),
            destination: JSONValues.string(entry, "destination"),
            direction: JSONValues.string(entry, "Direction"),
            nextStop: JSONValues.string(entry, "next_stop_name"),
            minutesLate: normalizedLateness(JSONValues.int(entry, "late")),
            reportedAt: reportedAt,
            tripID: JSONValues.string(entry, "trip")
        )
    }

    /// Observed shape: a bare array of trains. Fields as sent: `lat`/`lon` (string),
    /// `trainno`, `line`, `dest`, `currentstop`, `nextstop`, `service`, `consist`, `SOURCE`,
    /// `TRACK`, `TRACK_CHANGE` (strings), `heading` (string, fractional degrees),
    /// `late` (int minutes). There is no report timestamp.
    static func parseTrainView(_ data: Data) throws -> [Vehicle] {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let entries = root as? [[String: Any]] else {
            throw SEPTAError.unexpectedFormat("TrainView is not a JSON array")
        }

        let trains: [Vehicle] = entries.compactMap { entry in
            guard
                let lat = JSONValues.double(entry, "lat"),
                let lon = JSONValues.double(entry, "lon"),
                isPlausible(lat: lat, lon: lon)
            else { return nil }

            let trainNumber = JSONValues.string(entry, "trainno") ?? "?"
            let line = JSONValues.string(entry, "line") ?? "Regional Rail"

            return Vehicle(
                id: "\(TransitMode.regionalRail.rawValue)-\(trainNumber)",
                mode: .regionalRail,
                route: line,
                label: trainNumber,
                latitude: lat,
                longitude: lon,
                heading: JSONValues.double(entry, "heading"),
                destination: JSONValues.string(entry, "dest"),
                direction: nil,
                nextStop: JSONValues.string(entry, "nextstop"),
                minutesLate: normalizedLateness(JSONValues.int(entry, "late")),
                reportedAt: nil
            )
        }
        return VehicleMerger.uniqued(trains)
    }

    private static func isPlausible(lat: Double, lon: Double) -> Bool {
        VehicleMerger.isPlausible(lat: lat, lon: lon)
    }

    /// TransitView sends `late: 998` (with `Offset_sec: "0"`) when it has no estimate.
    /// 999 is the value older clients report for the same thing; it wasn't seen in the
    /// captured responses. Anything 900+ is treated as a sentinel.
    private static func normalizedLateness(_ minutes: Int?) -> Int? {
        guard let minutes, abs(minutes) < 900 else { return nil }
        return minutes
    }
}
