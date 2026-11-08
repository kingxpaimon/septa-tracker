import Foundation
import MapKit

/// Destination autocomplete, biased to the SEPTA region.
@MainActor
final class PlaceSearch: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var query = "" {
        didSet { completer.queryFragment = query }
    }
    @Published private(set) var suggestions: [MKLocalSearchCompletion] = []

    private let completer = MKLocalSearchCompleter()

    static let region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 40.0, longitude: -75.2),
        span: MKCoordinateSpan(latitudeDelta: 0.8, longitudeDelta: 0.8)
    )

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        completer.region = Self.region
    }

    func resolve(_ completion: MKLocalSearchCompletion) async throws -> Place {
        let request = MKLocalSearch.Request(completion: completion)
        request.region = Self.region
        let response = try await MKLocalSearch(request: request).start()
        guard let item = response.mapItems.first else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "That place couldn't be found."])
        }
        let c = item.placemark.coordinate
        return Place(
            name: item.name ?? completion.title,
            subtitle: completion.subtitle.isEmpty ? nil : completion.subtitle,
            point: GeoPoint(latitude: c.latitude, longitude: c.longitude)
        )
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in self.suggestions = results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.suggestions = [] }
    }
}

/// State for the directions screen.
@MainActor
final class TripPlanner: ObservableObject {
    enum Engine: String, CaseIterable, Identifiable {
        /// Transitous (free community service): quick, street-level walking, live bus data,
        /// SEPTA alerts; no live rail. The default.
        case transitous
        /// On-device RAPTOR over SEPTA's schedule plus SEPTA's live TripUpdates. Free, no key,
        /// live rail delays; the first search downloads and compiles the schedule.
        case septa
        /// Google Routes API. Needs a key; results can't be shown on the (Apple) map.
        case google
        var id: String { rawValue }
        var title: String {
            switch self {
            case .transitous: return "Transitous"
            case .septa: return "SEPTA"
            case .google: return "Google"
            }
        }
    }

    enum TimeMode: String, CaseIterable, Identifiable {
        case now, leaveAt, arriveBy
        var id: String { rawValue }
        var title: String {
            switch self {
            case .now: return "Leave now"
            case .leaveAt: return "Leave at"
            case .arriveBy: return "Arrive by"
            }
        }
    }

    /// Everything that changes the results; the view re-plans (debounced) when it changes.
    struct Request: Hashable {
        let start: Place?
        let destination: Place?
        let engine: Engine
        let preference: GoogleRoutesClient.Preference
        let timeMode: TimeMode
        let time: Date?
    }

    @Published var destination: Place?
    /// Nil = current location.
    @Published var start: Place?
    @Published var engine: Engine = .transitous
    @Published var preference: GoogleRoutesClient.Preference = .fastest
    @Published var timeMode: TimeMode = .now {
        didSet {
            // Start from a sensible time: now for "leave at", an hour from now for "arrive by".
            let now = Date()
            if timeMode == .leaveAt && time < now { time = now }
            if timeMode == .arriveBy && time < now.addingTimeInterval(10 * 60) { time = now.addingTimeInterval(3600) }
        }
    }
    @Published var time = Date()

    @Published private(set) var origin: GeoPoint?
    @Published private(set) var routes: [TransitRoute] = []
    @Published private(set) var isLoading = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasResults = false
    /// Shown under results: live-data coverage, schedule version, or a stale-data warning.
    @Published private(set) var resultNote: String?

    /// Nil when no Google key is configured; then Google isn't offered.
    let googleClient: GoogleRoutesClient?
    let transitous: TransitousClient
    let schedule: ScheduleStore
    /// Guards against an older, slower search overwriting a newer one's results.
    private var generation = 0

    init(googleClient: GoogleRoutesClient? = .fromInfoPlist(), transitous: TransitousClient = TransitousClient(),
         schedule: ScheduleStore = .shared) {
        self.googleClient = googleClient
        self.transitous = transitous
        self.schedule = schedule
    }

    var availableEngines: [Engine] {
        Engine.allCases.filter { $0 != .google || googleClient != nil }
    }

    var request: Request {
        Request(start: start, destination: destination, engine: engine, preference: preference,
                timeMode: timeMode, time: timeMode == .now ? nil : time)
    }

    func plan(using location: LocationService) async {
        guard let destination else { return }
        generation += 1
        let mine = generation
        isLoading = true
        errorMessage = nil
        resultNote = nil
        func current() -> Bool { mine == generation }
        defer { if current() { isLoading = false; statusMessage = nil } }

        let requestTime: Date? = timeMode == .now ? nil : time
        let arriveBy = timeMode == .arriveBy
        do {
            let from: GeoPoint
            if let start {
                from = start.point
            } else {
                statusMessage = "Finding your location…"
                let here = try await location.currentLocation().coordinate
                from = GeoPoint(latitude: here.latitude, longitude: here.longitude)
            }
            guard current() else { return }
            origin = from

            var found: [TransitRoute]
            var note: String?
            switch engine {
            case .septa:
                let result = try await schedule.plan(from: from, to: destination.point, time: requestTime, arriveBy: arriveBy) { phase in
                    Task { @MainActor [weak self] in
                        guard let self, mine == self.generation else { return }
                        self.statusMessage = phase.message.isEmpty ? "Planning…" : phase.message
                    }
                }
                found = result.routes
                var notes: [String] = []
                if let warning = result.staleScheduleWarning { notes.append(warning) }
                if let live = result.liveTrips {
                    notes.append("Times include SEPTA live predictions where available (\(live) trips right now).")
                } else {
                    notes.append("SEPTA live predictions are unavailable; times are scheduled.")
                }
                notes.append("Schedule: SEPTA GTFS \(result.feedVersion).")
                note = notes.joined(separator: " ")
            case .transitous:
                statusMessage = "Asking Transitous…"
                found = try await transitous.transitRoutes(from: from, to: destination.point, time: requestTime, arriveBy: arriveBy)
                note = "Live predictions for SEPTA buses and trolleys where available; Regional Rail times are scheduled."
            case .google:
                guard let googleClient else { throw GoogleRoutesError.missingAPIKey }
                found = try await googleClient.transitRoutes(from: from, to: destination.point, time: requestTime,
                                                             arriveBy: arriveBy, preference: preference)
            }
            if arriveBy {
                // Latest departure first, like Google Maps.
                found.sort { ($0.firstDeparture ?? .distantPast) > ($1.firstDeparture ?? .distantPast) }
            }
            guard current() else { return }
            routes = found
            resultNote = note
            hasResults = true
        } catch {
            // A newer search, or the view going away, cancels this one; stay quiet.
            guard current(), !Task.isCancelled, !(error is CancellationError),
                  (error as? URLError)?.code != .cancelled else { return }
            routes = []
            hasResults = false
            errorMessage = error.localizedDescription
        }
    }

    func clear() {
        generation += 1
        destination = nil
        routes = []
        hasResults = false
        errorMessage = nil
        isLoading = false
    }

    /// Opens Google Maps (app or web) with transit directions. Works without an API key.
    /// The URL scheme has no departure/arrival time, so Google Maps uses "now".
    /// https://developers.google.com/maps/documentation/urls/get-started#directions-action
    var googleMapsURL: URL? {
        guard let destination else { return nil }
        var components = URLComponents(string: "https://www.google.com/maps/dir/")!
        var items = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "destination", value: "\(destination.point.latitude),\(destination.point.longitude)"),
            URLQueryItem(name: "travelmode", value: "transit"),
        ]
        if let origin = start?.point ?? origin {
            items.append(URLQueryItem(name: "origin", value: "\(origin.latitude),\(origin.longitude)"))
        }
        components.queryItems = items
        return components.url
    }
}
