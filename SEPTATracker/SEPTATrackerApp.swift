import SwiftUI
import Network

@main
struct SEPTATrackerApp: App {
    @StateObject private var vehicleStore = VehicleStore()
    @StateObject private var locationService = LocationService()
    @StateObject private var savedPlaces = SavedPlacesStore()
    @StateObject private var rideTracker = RideTracker()
    @StateObject private var tripAlerts = TripAlerts()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(vehicleStore)
                .environmentObject(locationService)
                .environmentObject(savedPlaces)
                .environmentObject(rideTracker)
                .environmentObject(tripAlerts)
                .task { await Self.prefetchScheduleOnWiFi() }
        }
    }

    /// Downloads SEPTA's schedule (~27 MB) in the background on Wi-Fi / unmetered networks,
    /// so "Nearby" and the SEPTA planner don't make the user wait the first time.
    private static func prefetchScheduleOnWiFi() async {
        guard !(await ScheduleStore.shared.hasSchedule()) else { return }
        let path = await currentPath()
        guard path.status == .satisfied, !path.isExpensive, !path.isConstrained else { return }
        await ScheduleStore.shared.prefetch()
    }

    private static func currentPath() async -> NWPath {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "septa.path")
            let once = ResumeOnce()   // the handler can fire more than once
            monitor.pathUpdateHandler = { path in
                guard once.claim() else { return }
                monitor.cancel()
                continuation.resume(returning: path)
            }
            monitor.start(queue: queue)
        }
    }
}

/// Lets a callback resume a continuation exactly once.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
