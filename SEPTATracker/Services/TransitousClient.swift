import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // Linux only; lets the parser tests run off-Mac.
#endif

/// Transit directions from Transitous (https://transitous.org), a free, community-run
/// routing service (MOTIS) built on open transit data and OpenStreetMap.
///
/// Usage policy (https://transitous.org/api/), summarized:
/// - For non-commercial, open-source apps; light prototype testing is fine before publishing.
/// - Every request must send a User-Agent with app name, version and a contact (URL or email).
/// - Show a visible link to https://transitous.org/sources/ and follow OpenStreetMap attribution.
/// - Heavy use (> ~720 plan requests/day) should be discussed with them first.
/// - Best effort; they may stop serving any client at any time.
///
/// In captured responses, SEPTA buses/trolleys had live predictions but Regional Rail did not.
struct TransitousClient {
    static let endpoint = URL(string: "https://api.transitous.org/api/v1/plan")!
    static let sourcesURL = URL(string: "https://transitous.org/sources/")!
    static let contactURL = "https://github.com/kingxpaimon/septa-tracker"

    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "SEPTA-Live/\(version) (+\(contactURL))"
    }

    var session: URLSession = .shared

    /// - Parameters:
    ///   - time: departure time, or the arrival deadline when `arriveBy` is true. Nil = now.
    func transitRoutes(from origin: GeoPoint, to destination: GeoPoint, time: Date? = nil, arriveBy: Bool = false) async throws -> [TransitRoute] {
        var request = URLRequest(url: Self.url(from: origin, to: destination, time: time, arriveBy: arriveBy))
        request.timeoutInterval = 20
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TransitousError.badStatus(http.statusCode)
        }
        return try Self.parseRoutes(data)
    }

    static func url(from origin: GeoPoint, to destination: GeoPoint, time: Date?, arriveBy: Bool = false) -> URL {
        var c = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "fromPlace", value: "\(origin.latitude),\(origin.longitude)"),
            URLQueryItem(name: "toPlace", value: "\(destination.latitude),\(destination.longitude)"),
        ]
        if let time {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            items.append(URLQueryItem(name: "time", value: f.string(from: time)))
        }
        // Checked against the live API: with arriveBy=true every itinerary ends by `time`.
        if arriveBy { items.append(URLQueryItem(name: "arriveBy", value: "true")) }
        c.queryItems = items
        return c.url!
    }

    // MARK: - Parsing

    static func parseRoutes(_ data: Data) throws -> [TransitRoute] {
        let plan: DTO.Plan
        do {
            plan = try JSONDecoder().decode(DTO.Plan.self, from: data)
        } catch {
            throw TransitousError.unexpectedFormat(String(describing: error))
        }
        let itineraries = (plan.itineraries ?? []) + (plan.direct ?? [])
        return itineraries.enumerated().map { index, it in route(it, id: index) }
    }

    private static func route(_ it: DTO.Itinerary, id: Int) -> TransitRoute {
        var segments: [TransitRoute.Segment] = []
        var warnings: [String] = []
        for leg in it.legs ?? [] {
            if leg.mode == "WALK" || leg.mode == "BIKE" || leg.mode == "CAR" {
                let walk = TransitRoute.Walk(duration: leg.duration ?? 0, distanceMeters: Int(leg.distance ?? 0))
                if case .walk(var w)? = segments.last {
                    w.duration += walk.duration
                    w.distanceMeters += walk.distanceMeters
                    segments[segments.count - 1] = .walk(w)
                } else {
                    segments.append(.walk(walk))
                }
                continue
            }
            let isRail = leg.mode == "REGIONAL_RAIL" || leg.mode == "RAIL" || leg.mode == "LONG_DISTANCE"
            let departure = date(leg.from?.departure ?? leg.startTime)
            let scheduled = date(leg.from?.scheduledDeparture ?? leg.scheduledStartTime)
            let delay: Int? = (leg.realTime == true && departure != nil && scheduled != nil)
                ? Int(departure!.timeIntervalSince(scheduled!)) : nil
            let short = leg.routeShortName.flatMap { $0.isEmpty ? nil : $0 }
            let septaTrip = septaTripID(leg.tripId)
            segments.append(.ride(TransitRoute.Ride(
                lineName: leg.routeLongName.flatMap { $0.isEmpty ? nil : $0 },
                lineShortName: isRail ? nil : short,
                lineColor: leg.routeColor.map { "#" + $0 },
                lineTextColor: leg.routeTextColor.map { "#" + $0 },
                vehicleType: vehicleType(leg.mode),
                vehicleName: vehicleName(leg.mode),
                agencyNames: leg.agencyName.map { [$0] } ?? [],
                headsign: leg.headsign,
                departureStopName: leg.from?.name,
                departureStop: leg.from.flatMap { f in f.lat.flatMap { lat in f.lon.map { GeoPoint(latitude: lat, longitude: $0) } } },
                arrivalStopName: leg.to?.name,
                departureTime: departure,
                arrivalTime: date(leg.to?.arrival ?? leg.endTime),
                departureTimeText: nil,
                arrivalTimeText: nil,
                stopCount: leg.intermediateStops.map { $0.count + 1 },
                duration: leg.duration,
                tripID: septaTrip,
                trainNumber: isRail ? trainNumber(leg.tripShortName) : nil,
                liveDelaySeconds: delay,
                routeShortName: short
            )))
            for alert in leg.alerts ?? [] {
                let text = [short ?? leg.routeLongName, alert.headerText, alert.descriptionText]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
                if !text.isEmpty && !warnings.contains(text) { warnings.append(text) }
            }
        }
        let duration = it.duration.map(TimeInterval.init)
        return TransitRoute(id: id, duration: duration, durationText: duration.map(minutesText), distanceText: nil,
                            fareText: nil, segments: segments, warnings: warnings)
    }

    /// "20261107_20:08_us-pa-SEPTA-Bus_968699" → "968699" (SEPTA's GTFS trip_id).
    static func septaTripID(_ tripId: String?) -> String? {
        guard let tripId else { return nil }
        for marker in ["SEPTA-Bus_", "SEPTA-Rail_"] {
            if let r = tripId.range(of: marker) { return String(tripId[r.upperBound...]) }
        }
        return nil
    }

    /// "LAN3562" → "3562".
    static func trainNumber(_ shortName: String?) -> String? {
        guard let digits = shortName?.drop(while: { $0.isLetter }), !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return String(digits)
    }

    static func vehicleType(_ mode: String?) -> String {
        switch mode {
        case "REGIONAL_RAIL": return "COMMUTER_TRAIN"
        case "TRAM": return "TRAM"
        case "SUBWAY", "METRO": return "SUBWAY"
        case "BUS", "COACH": return "BUS"
        default: return mode ?? "TRANSIT"
        }
    }

    static func vehicleName(_ mode: String?) -> String {
        switch mode {
        case "REGIONAL_RAIL", "RAIL": return "Regional Rail"
        case "TRAM": return "Trolley"
        case "SUBWAY", "METRO": return "Subway"
        default: return "Bus"
        }
    }

    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    private enum DTO {
        struct Plan: Decodable {
            let itineraries: [Itinerary]?
            let direct: [Itinerary]?
        }
        struct Itinerary: Decodable {
            let duration: Int?
            let legs: [Leg]?
        }
        struct Leg: Decodable {
            let mode: String?
            let from: Place?
            let to: Place?
            let duration: Double?
            let distance: Double?
            let startTime: String?
            let endTime: String?
            let scheduledStartTime: String?
            let realTime: Bool?
            let headsign: String?
            let routeShortName: String?
            let routeLongName: String?
            let routeColor: String?
            let routeTextColor: String?
            let agencyName: String?
            let tripId: String?
            let tripShortName: String?
            let intermediateStops: [Place]?
            let alerts: [Alert]?
        }
        struct Place: Decodable {
            let name: String?
            let lat: Double?
            let lon: Double?
            let departure: String?
            let scheduledDeparture: String?
            let arrival: String?
        }
        struct Alert: Decodable {
            let headerText: String?
            let descriptionText: String?
        }
    }
}

enum TransitousError: LocalizedError {
    case badStatus(Int)
    case unexpectedFormat(String)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "Transitous returned HTTP \(code)."
        case .unexpectedFormat(let detail): return "Unexpected response from Transitous: \(detail)"
        }
    }
}
