import Foundation

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
/// Field names below come from SEPTA's published examples and community clients,
/// not a formal spec; SEPTA changed these feeds in 2024. Parsing is deliberately
/// lenient: a vehicle with no usable coordinates is skipped rather than failing
/// the whole response.
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

    /// Expected shape: `{"routes": [{"17": [{vehicle}, ...], "33": [...]}]}`.
    /// `routes` as a single object (not wrapped in an array) is also accepted.
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
        return vehicles
    }

    private static func surfaceVehicle(from entry: [String: Any], route: String, mode: TransitMode) -> Vehicle? {
        guard
            let lat = JSONValues.double(entry, "lat"),
            let lon = JSONValues.double(entry, "lng", "lon"),
            isPlausible(lat: lat, lon: lon)
        else { return nil }

        let label = JSONValues.string(entry, "label", "VehicleID", "vehicle_id") ?? "?"
        let secondsSinceReport = JSONValues.int(entry, "Offset_sec")
            ?? JSONValues.int(entry, "Offset").map { $0 * 60 }

        return Vehicle(
            id: "\(mode.rawValue)-\(route)-\(label)",
            mode: mode,
            route: route,
            label: label,
            latitude: lat,
            longitude: lon,
            heading: JSONValues.double(entry, "heading"),
            destination: JSONValues.string(entry, "destination"),
            direction: JSONValues.string(entry, "Direction", "direction"),
            nextStop: JSONValues.string(entry, "next_stop_name"),
            minutesLate: normalizedLateness(JSONValues.int(entry, "late")),
            secondsSinceReport: secondsSinceReport
        )
    }

    /// Expected shape: `[{"trainno": "9230", "line": "...", "lat": "...", "lon": "...", ...}]`.
    static func parseTrainView(_ data: Data) throws -> [Vehicle] {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let entries = root as? [[String: Any]] else {
            throw SEPTAError.unexpectedFormat("TrainView is not a JSON array")
        }

        return entries.compactMap { entry in
            guard
                let lat = JSONValues.double(entry, "lat"),
                let lon = JSONValues.double(entry, "lon", "lng"),
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
                secondsSinceReport: nil
            )
        }
    }

    /// Drops (0, 0) and anything far outside the SEPTA region.
    private static func isPlausible(lat: Double, lon: Double) -> Bool {
        (38.5...41.5).contains(lat) && (-77.0 ... -73.5).contains(lon)
    }

    /// SEPTA uses large sentinel values (e.g. 998/999) for "no estimate".
    private static func normalizedLateness(_ minutes: Int?) -> Int? {
        guard let minutes, abs(minutes) < 900 else { return nil }
        return minutes
    }
}
