import SwiftUI

enum TransitMode: String, CaseIterable, Identifiable, Hashable {
    case bus
    case trolley
    case regionalRail

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bus: return "Bus"
        case .trolley: return "Trolley"
        case .regionalRail: return "Regional Rail"
        }
    }

    var systemImage: String {
        switch self {
        case .bus: return "bus.fill"
        case .trolley: return "tram.fill"
        case .regionalRail: return "train.side.front.car"
        }
    }

    var tint: Color {
        switch self {
        case .bus: return .blue
        case .trolley: return .green
        case .regionalRail: return .purple
        }
    }

    /// TransitView reports buses and trolleys together, keyed by route. These are the
    /// trolley routes under both the old numbering and the 2025 metro renaming. The list
    /// is maintained by hand; an unknown trolley route shows up as a bus.
    static let trolleyRoutes: Set<String> = [
        "10", "11", "13", "15", "34", "36", "101", "102",
        "T1", "T2", "T3", "T4", "T5", "D1", "D2", "G1",
    ]

    static func forSurfaceRoute(_ route: String) -> TransitMode {
        trolleyRoutes.contains(route.uppercased()) ? .trolley : .bus
    }
}
