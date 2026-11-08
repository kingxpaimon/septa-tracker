import Foundation

/// A searched place. Search uses Apple's MKLocalSearch; only the coordinate is sent to a planner.
struct Place: Hashable, Codable {
    let name: String
    let subtitle: String?
    let point: GeoPoint

    /// Same spot (within ~25 m), regardless of name.
    func isNear(_ other: Place) -> Bool { point.distance(to: other.point) < 25 }
}

/// Home, Work and starred places, kept on the device (UserDefaults). Never uploaded.
struct SavedPlaces: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case home, work, starred
        var title: String {
            switch self {
            case .home: return "Home"
            case .work: return "Work"
            case .starred: return "Starred"
            }
        }
        var systemImage: String {
            switch self {
            case .home: return "house.fill"
            case .work: return "briefcase.fill"
            case .starred: return "star.fill"
            }
        }
    }

    struct Entry: Codable, Identifiable, Hashable {
        var id = UUID()
        var kind: Kind
        var place: Place
        /// Shown instead of the place name, e.g. "Mom's". Starred places only.
        var label: String?
        var displayName: String { kind == .starred ? (label ?? place.name) : kind.title }
    }

    private(set) var entries: [Entry] = []

    var home: Entry? { entries.first { $0.kind == .home } }
    var work: Entry? { entries.first { $0.kind == .work } }
    var starred: [Entry] { entries.filter { $0.kind == .starred } }
    /// Home, Work, then starred in the order they were added.
    var all: [Entry] { [home, work].compactMap { $0 } + starred }

    /// Sets Home or Work (replacing the previous one), or stars a place.
    /// Starring a place that's already starred does nothing.
    mutating func save(_ place: Place, as kind: Kind, label: String? = nil) {
        switch kind {
        case .home, .work:
            entries.removeAll { $0.kind == kind }
            entries.append(Entry(kind: kind, place: place))
        case .starred:
            guard !starred.contains(where: { $0.place.isNear(place) }) else { return }
            entries.append(Entry(kind: .starred, place: place, label: label))
        }
    }

    mutating func remove(id: Entry.ID) {
        entries.removeAll { $0.id == id }
    }

    mutating func unstar(_ place: Place) {
        entries.removeAll { $0.kind == .starred && $0.place.isNear(place) }
    }

    func isStarred(_ place: Place) -> Bool {
        starred.contains { $0.place.isNear(place) }
    }

    /// Saved entry at this spot, if any (Home/Work first).
    func entry(at place: Place) -> Entry? {
        all.first { $0.place.isNear(place) }
    }

    // MARK: Persistence

    static let defaultsKey = "savedPlaces.v1"

    static func load(from defaults: UserDefaults = .standard) -> SavedPlaces {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(SavedPlaces.self, from: data)
        else { return SavedPlaces() }
        return decoded
    }

    func store(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
