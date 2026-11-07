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

    /// TransitView reports buses and trolleys together, keyed by route, with no mode field.
    /// Route keys seen in a live response (Nov 2026): T1–T5, G1, M1, plus `D1_BUS` and
    /// `D2_BUS` (bus substitutes on the Media/Sharon Hill lines, so they stay buses).
    /// Old numeric trolley routes and plain D1/D2 are kept in case they reappear.
    /// M1 (Norristown High Speed Line) is light rail; it's grouped with trolleys because
    /// the app has no separate mode for it. An unknown rail route shows up as a bus.
    static let trolleyRoutes: Set<String> = [
        "10", "11", "13", "15", "34", "36", "101", "102",
        "T1", "T2", "T3", "T4", "T5", "D1", "D2", "G1", "M1",
    ]

    static func forSurfaceRoute(_ route: String) -> TransitMode {
        trolleyRoutes.contains(route.uppercased()) ? .trolley : .bus
    }
}
