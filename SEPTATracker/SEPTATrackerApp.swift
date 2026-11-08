import SwiftUI

@main
struct SEPTATrackerApp: App {
    @StateObject private var vehicleStore = VehicleStore()
    @StateObject private var locationService = LocationService()
    @StateObject private var savedPlaces = SavedPlacesStore()
    @StateObject private var rideTracker = RideTracker()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(vehicleStore)
                .environmentObject(locationService)
                .environmentObject(savedPlaces)
                .environmentObject(rideTracker)
        }
    }
}
