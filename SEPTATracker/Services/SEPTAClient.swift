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

    /// All buses and trolleys currently reporting.
    func fetchSurfaceVehicles() async throws -> [Vehicle] {
        let data = try await get("TransitViewAll/index.php")
        return try Self.parseTransitViewAll(data)
    }

    /// All Regional Rail trains currently reporting.
    func fetchTrains() async throws -> [Vehicle] {
        let data = try await get("TrainView/index.php")
        return try Self.parseTrainView(data)
    }

    private func get(_ path: String) async throws -> Data {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(path))
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
    /// The feed can list the same vehicle twice, at the same position, under two trip IDs
    /// (apparently the trip it is finishing and the next one). Only the first entry per
    /// vehicle is kept so IDs stay unique.
    static func parseTransitViewAll(_ data: Data) throws -> [Vehicle] {
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
        return uniqued(vehicles)
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
            reportedAt: reportedAt
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
        return uniqued(trains)
    }

    /// Keeps the first vehicle for each ID. SwiftUI's `ForEach` and map selection
    /// both misbehave with duplicate IDs.
    private static func uniqued(_ vehicles: [Vehicle]) -> [Vehicle] {
        var seen = Set<Vehicle.ID>()
        return vehicles.filter { seen.insert($0.id).inserted }
    }

    /// Drops (0, 0) and anything far outside the SEPTA region.
    private static func isPlausible(lat: Double, lon: Double) -> Bool {
        (38.5...41.5).contains(lat) && (-77.0 ... -73.5).contains(lon)
    }

    /// TransitView sends `late: 998` (with `Offset_sec: "0"`) when it has no estimate.
    /// 999 is the value older clients report for the same thing; it wasn't seen in the
    /// captured responses. Anything 900+ is treated as a sentinel.
    private static func normalizedLateness(_ minutes: Int?) -> Int? {
        guard let minutes, abs(minutes) < 900 else { return nil }
        return minutes
    }
}
