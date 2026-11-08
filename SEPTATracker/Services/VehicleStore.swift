import Foundation
import Combine

@MainActor
final class VehicleStore: ObservableObject {
    @Published private(set) var surfaceVehicles: [Vehicle] = []
    @Published private(set) var trains: [Vehicle] = []
    /// Buses only GTFS-RT reports (waiting at their first stop / between trips). Not on the map.
    @Published private(set) var waitingVehicles: [Vehicle] = []
    /// Buses running bunched with another on the same route and direction.
    @Published private(set) var bunching: [Vehicle.ID: VehicleInsights.Bunch] = [:]
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false
    /// One message per failing feed. A failing feed keeps its last good data.
    @Published private(set) var errors: [String] = []

    @Published var enabledModes: Set<TransitMode> = Set(TransitMode.allCases)
    /// Empty means every route.
    @Published var selectedRoutes: Set<String> = []

    /// SEPTA's vehicle positions update roughly every 30 seconds; polling faster gains little.
    let pollInterval: Duration = .seconds(20)

    private let client: SEPTAClient

    init(client: SEPTAClient = SEPTAClient()) {
        self.client = client
    }

    var allVehicles: [Vehicle] { surfaceVehicles + trains }

    var visibleVehicles: [Vehicle] {
        allVehicles.filter { vehicle in
            enabledModes.contains(vehicle.mode)
                && (selectedRoutes.isEmpty || selectedRoutes.contains(vehicle.route))
        }
    }

    func routes(for mode: TransitMode) -> [String] {
        let names = Set(allVehicles.filter { $0.mode == mode }.map(\.route))
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func vehicle(withID id: Vehicle.ID) -> Vehicle? {
        allVehicles.first { $0.id == id }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        async let surfaceResult = Self.capture { try await self.client.fetchSurfaceVehicles() }
        async let trainResult = Self.capture { try await self.client.fetchTrains() }
        let (surface, rail) = await (surfaceResult, trainResult)

        var newErrors: [String] = []
        switch surface {
        case .success(let feed):
            surfaceVehicles = feed.vehicles
            waitingVehicles = feed.waiting
            bunching = VehicleInsights.bunching(feed.vehicles)
        case .failure(let error): newErrors.append("Buses/trolleys: \(error.localizedDescription)")
        }
        switch rail {
        case .success(let vehicles): trains = vehicles
        case .failure(let error): newErrors.append("Regional Rail: \(error.localizedDescription)")
        }
        errors = newErrors
        if newErrors.count < 2 { lastUpdated = Date() }
    }

    /// Refreshes on a timer until the calling task is cancelled
    /// (e.g. the view disappears or the app leaves the foreground).
    func pollUntilCancelled() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: pollInterval)
        }
    }

    private static func capture<T>(_ work: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }
}
