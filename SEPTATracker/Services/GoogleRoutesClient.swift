import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // Linux only; lets the parser tests run off-Mac.
#endif

enum GoogleRoutesError: LocalizedError {
    case missingAPIKey
    case api(status: Int, message: String)
    case unexpectedFormat(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No Google Maps API key is configured. See README → Directions setup."
        case .api(let status, let message):
            return "Google Routes returned HTTP \(status): \(message)"
        case .unexpectedFormat(let detail):
            return "Unexpected response from Google Routes: \(detail)"
        }
    }
}

/// Transit directions from the Google Routes API (`directions/v2:computeRoutes`).
/// https://developers.google.com/maps/documentation/routes/transit-route
///
/// The API key ships inside the app, so anyone can extract it. Restrict it in Google Cloud
/// to this app's bundle ID and to the Routes API only, and set a daily quota.
struct GoogleRoutesClient {
    static let endpoint = URL(string: "https://routes.googleapis.com/directions/v2:computeRoutes")!

    /// Only the fields the app shows. The field mask is required, and it also limits what's billed.
    /// No polylines: route geometry would only be useful on a map, and this app can't put
    /// Google content on its (Apple) map.
    static let fieldMask = [
        "routes.duration",
        "routes.distanceMeters",
        "routes.localizedValues",
        "routes.warnings",
        "routes.legs.steps.travelMode",
        "routes.legs.steps.staticDuration",
        "routes.legs.steps.distanceMeters",
        "routes.legs.steps.transitDetails",
    ].joined(separator: ",")

    enum Preference: String, CaseIterable, Identifiable {
        case fastest, fewerTransfers, lessWalking
        var id: String { rawValue }
        var title: String {
            switch self {
            case .fastest: return "Fastest"
            case .fewerTransfers: return "Fewer transfers"
            case .lessWalking: return "Less walking"
            }
        }
        var apiValue: String? {
            switch self {
            case .fastest: return nil
            case .fewerTransfers: return "FEWER_TRANSFERS"
            case .lessWalking: return "LESS_WALKING"
            }
        }
    }

    let apiKey: String
    var bundleIdentifier: String? = Bundle.main.bundleIdentifier
    var session: URLSession = .shared

    /// Reads `GoogleMapsAPIKey` from Info.plist (filled from `GOOGLE_MAPS_API_KEY` in
    /// Config/Secrets.xcconfig). Nil when it's missing, empty, or an unexpanded `$(...)`.
    static func fromInfoPlist(_ bundle: Bundle = .main) -> GoogleRoutesClient? {
        guard let key = bundle.object(forInfoDictionaryKey: "GoogleMapsAPIKey") as? String,
              !key.trimmingCharacters(in: .whitespaces).isEmpty,
              !key.hasPrefix("$(")
        else { return nil }
        return GoogleRoutesClient(apiKey: key)
    }

    func transitRoutes(
        from origin: GeoPoint,
        to destination: GeoPoint,
        departure: Date? = nil,
        preference: Preference = .fastest
    ) async throws -> [TransitRoute] {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue(Self.fieldMask, forHTTPHeaderField: "X-Goog-FieldMask")
        // Needed when the key is restricted to iOS apps.
        if let bundleIdentifier { request.setValue(bundleIdentifier, forHTTPHeaderField: "X-Ios-Bundle-Identifier") }
        request.httpBody = try Self.requestBody(from: origin, to: destination, departure: departure, preference: preference)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw GoogleRoutesError.api(status: http.statusCode, message: Self.errorMessage(in: data) ?? "no details")
        }
        return try Self.parseRoutes(data)
    }

    // MARK: - Request

    static func requestBody(from origin: GeoPoint, to destination: GeoPoint, departure: Date?, preference: Preference) throws -> Data {
        func waypoint(_ p: GeoPoint) -> [String: Any] {
            ["location": ["latLng": ["latitude": p.latitude, "longitude": p.longitude]]]
        }
        var body: [String: Any] = [
            "origin": waypoint(origin),
            "destination": waypoint(destination),
            "travelMode": "TRANSIT",
            "computeAlternativeRoutes": true,
            "languageCode": "en-US",
            "units": "IMPERIAL",
        ]
        if let departure {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            body["departureTime"] = formatter.string(from: departure)
        }
        if let value = preference.apiValue {
            body["transitPreferences"] = ["routingPreference": value]
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    // MARK: - Response

    static func parseRoutes(_ data: Data) throws -> [TransitRoute] {
        let response: DTO.Response
        do {
            response = try JSONDecoder().decode(DTO.Response.self, from: data)
        } catch {
            throw GoogleRoutesError.unexpectedFormat(String(describing: error))
        }
        // An empty object (`{}`) is how the API says "no routes found".
        return (response.routes ?? []).enumerated().map { index, route in
            TransitRoute(
                id: index,
                duration: seconds(route.duration),
                durationText: route.localizedValues?.duration?.text,
                distanceText: route.localizedValues?.distance?.text,
                fareText: route.localizedValues?.transitFare?.text,
                segments: segments(route.legs ?? []),
                warnings: route.warnings ?? []
            )
        }
    }

    private static func segments(_ legs: [DTO.Leg]) -> [TransitRoute.Segment] {
        var result: [TransitRoute.Segment] = []
        for step in legs.flatMap({ $0.steps ?? [] }) {
            if let t = step.transitDetails {
                let line = t.transitLine
                result.append(.ride(TransitRoute.Ride(
                    lineName: line?.name,
                    lineShortName: line?.nameShort,
                    lineColor: line?.color,
                    lineTextColor: line?.textColor,
                    vehicleType: line?.vehicle?.type,
                    vehicleName: line?.vehicle?.name?.text,
                    agencyNames: (line?.agencies ?? []).compactMap(\.name),
                    headsign: t.headsign,
                    departureStopName: t.stopDetails?.departureStop?.name,
                    departureStop: t.stopDetails?.departureStop?.location?.latLng.map {
                        GeoPoint(latitude: $0.latitude, longitude: $0.longitude)
                    },
                    arrivalStopName: t.stopDetails?.arrivalStop?.name,
                    departureTime: date(t.stopDetails?.departureTime),
                    arrivalTime: date(t.stopDetails?.arrivalTime),
                    departureTimeText: t.localizedValues?.departureTime?.time?.text,
                    arrivalTimeText: t.localizedValues?.arrivalTime?.time?.text,
                    stopCount: t.stopCount,
                    duration: seconds(step.staticDuration)
                )))
            } else {
                // Walking (Google returns many small walking steps; merge them).
                let duration = seconds(step.staticDuration) ?? 0
                let distance = step.distanceMeters ?? 0
                if case .walk(var walk)? = result.last {
                    walk.duration += duration
                    walk.distanceMeters += distance
                    result[result.count - 1] = .walk(walk)
                } else {
                    result.append(.walk(TransitRoute.Walk(duration: duration, distanceMeters: distance)))
                }
            }
        }
        return result
    }

    /// Google encodes durations as strings like "1234s" (fractions allowed).
    static func seconds(_ value: String?) -> TimeInterval? {
        guard let value, value.hasSuffix("s") else { return nil }
        return TimeInterval(value.dropLast())
    }

    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: value) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
    }

    static func errorMessage(in data: Data) -> String? {
        struct Envelope: Decodable { struct E: Decodable { let message: String? }; let error: E? }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.error?.message
    }

    /// Wire format, per the Routes API reference. Every field optional: the field mask
    /// and route type decide what's present.
    private enum DTO {
        struct Response: Decodable { let routes: [Route]? }
        struct Route: Decodable {
            let duration: String?
            let distanceMeters: Int?
            let localizedValues: RouteLocalized?
            let warnings: [String]?
            let legs: [Leg]?
        }
        struct RouteLocalized: Decodable {
            let duration: Text?
            let distance: Text?
            let transitFare: Text?
        }
        struct Text: Decodable { let text: String? }
        struct Leg: Decodable { let steps: [Step]? }
        struct Step: Decodable {
            let travelMode: String?
            let staticDuration: String?
            let distanceMeters: Int?
            let transitDetails: TransitDetails?
        }
        struct TransitDetails: Decodable {
            let stopDetails: StopDetails?
            let localizedValues: TransitLocalized?
            let headsign: String?
            let transitLine: Line?
            let stopCount: Int?
        }
        struct StopDetails: Decodable {
            let arrivalStop: Stop?
            let departureStop: Stop?
            let arrivalTime: String?
            let departureTime: String?
        }
        struct Stop: Decodable {
            let name: String?
            let location: Location?
        }
        struct Location: Decodable { let latLng: LatLng? }
        struct LatLng: Decodable { let latitude: Double; let longitude: Double }
        struct TransitLocalized: Decodable {
            let arrivalTime: LocalizedTime?
            let departureTime: LocalizedTime?
        }
        struct LocalizedTime: Decodable { let time: Text? }
        struct Line: Decodable {
            let agencies: [Agency]?
            let name: String?
            let nameShort: String?
            let color: String?
            let textColor: String?
            let vehicle: LineVehicle?
        }
        struct Agency: Decodable { let name: String? }
        struct LineVehicle: Decodable {
            let name: Text?
            let type: String?
        }
    }
}
