import SwiftUI

@main
struct SEPTATrackerApp: App {
    @StateObject private var vehicleStore = VehicleStore()
    @StateObject private var locationService = LocationService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(vehicleStore)
                .environmentObject(locationService)
        }
    }
}
