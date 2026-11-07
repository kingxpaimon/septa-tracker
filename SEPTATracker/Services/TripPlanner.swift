import Foundation
import MapKit

/// A searched place. Search uses Apple's MKLocalSearch; only the coordinate is sent to Google.
struct Place: Hashable {
    let name: String
    let subtitle: String?
    let point: GeoPoint
}

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
    @Published var destination: Place?
    @Published var preference: GoogleRoutesClient.Preference = .fastest
    @Published private(set) var origin: GeoPoint?
    @Published private(set) var routes: [TransitRoute] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasResults = false

    /// Nil when no API key is configured; the screen then offers only the Google Maps hand-off.
    let client: GoogleRoutesClient?

    init(client: GoogleRoutesClient? = .fromInfoPlist()) {
        self.client = client
    }

    func plan(using location: LocationService) async {
        guard let destination else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let here = try await location.currentLocation().coordinate
            let start = GeoPoint(latitude: here.latitude, longitude: here.longitude)
            origin = start
            guard let client else {
                routes = []
                hasResults = false
                return
            }
            routes = try await client.transitRoutes(from: start, to: destination.point, preference: preference)
            hasResults = true
        } catch is CancellationError {
            return
        } catch {
            routes = []
            hasResults = false
            errorMessage = error.localizedDescription
        }
    }

    func clear() {
        destination = nil
        routes = []
        hasResults = false
        errorMessage = nil
    }

    /// Opens Google Maps (app or web) with transit directions. Works without an API key.
    /// https://developers.google.com/maps/documentation/urls/get-started#directions-action
    var googleMapsURL: URL? {
        guard let destination else { return nil }
        var components = URLComponents(string: "https://www.google.com/maps/dir/")!
        var items = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "destination", value: "\(destination.point.latitude),\(destination.point.longitude)"),
            URLQueryItem(name: "travelmode", value: "transit"),
        ]
        if let origin {
            items.append(URLQueryItem(name: "origin", value: "\(origin.latitude),\(origin.longitude)"))
        }
        components.queryItems = items
        return components.url
    }
}
