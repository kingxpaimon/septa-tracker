import Foundation
import Combine

/// App-wide Home/Work/starred places, shared by the map and the directions screen.
/// Persisted to UserDefaults on every change; never leaves the device.
@MainActor
final class SavedPlacesStore: ObservableObject {
    @Published var places: SavedPlaces {
        didSet { places.store(to: defaults) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.places = SavedPlaces.load(from: defaults)
    }
}
