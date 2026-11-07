import SwiftUI
import MapKit

/// Destination search and transit route recommendations.
///
/// Presented full screen, never over the live map: Google's terms forbid using Routes API
/// content with a non-Google map, and the live map is MapKit. Route results are lists only.
struct TripPlannerView: View {
    @EnvironmentObject private var store: VehicleStore
    @EnvironmentObject private var location: LocationService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @StateObject private var search = PlaceSearch()
    @StateObject private var planner = TripPlanner()
    @State private var resolveError: String?

    var body: some View {
        NavigationStack {
            List {
                if let destination = planner.destination {
                    destinationSection(destination)
                    resultsSection
                } else {
                    suggestionsSection
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $search.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Where to?")
            .navigationTitle("Directions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .navigationDestination(for: TransitRoute.self) { route in
                RouteDetailView(route: route, showOnMap: showOnMap)
            }
            .onChange(of: planner.preference) {
                Task { await planner.plan(using: location) }
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var suggestionsSection: some View {
        if let resolveError {
            Section { Label(resolveError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        }
        if search.query.isEmpty {
            Section {
                Text("Search for an address or place to get transit directions from your current location.")
                    .foregroundStyle(.secondary)
            }
        } else {
            Section {
                ForEach(search.suggestions, id: \.self) { suggestion in
                    Button {
                        Task { await choose(suggestion) }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(suggestion.title).foregroundStyle(.primary)
                            if !suggestion.subtitle.isEmpty {
                                Text(suggestion.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func destinationSection(_ destination: Place) -> some View {
        Section {
            HStack {
                VStack(alignment: .leading) {
                    Text(destination.name).font(.headline)
                    if let subtitle = destination.subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Change") { planner.clear() }
                    .buttonStyle(.borderless)
            }
            if planner.client != nil {
                Picker("Prefer", selection: $planner.preference) {
                    ForEach(GoogleRoutesClient.Preference.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if let url = planner.googleMapsURL {
                Button {
                    openURL(url)
                } label: {
                    Label("Open in Google Maps", systemImage: "arrow.up.forward.app")
                }
            }
        } header: {
            Text("To")
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        if planner.isLoading {
            Section { HStack { Spacer(); ProgressView(); Spacer() } }
        } else if let message = planner.errorMessage {
            Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        } else if planner.client == nil {
            Section {
                Text("In-app route recommendations need a Google Maps API key. See “Directions setup” in the README. You can still open the trip in Google Maps.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if planner.hasResults && planner.routes.isEmpty {
            Section { Text("No transit routes found.").foregroundStyle(.secondary) }
        } else if !planner.routes.isEmpty {
            Section {
                ForEach(planner.routes) { route in
                    NavigationLink(value: route) { RouteRow(route: route) }
                }
            } header: {
                Text("Routes")
            } footer: {
                GoogleAttribution()
            }
        }
    }

    // MARK: Actions

    private func choose(_ suggestion: MKLocalSearchCompletion) async {
        resolveError = nil
        do {
            planner.destination = try await search.resolve(suggestion)
            search.query = ""
            await planner.plan(using: location)
        } catch {
            resolveError = error.localizedDescription
        }
    }

    /// Filters the live map to one line and closes directions. Only SEPTA's own vehicle
    /// data goes on the map, never Google's route content.
    private func showOnMap(_ info: LiveLineMatcher.LiveInfo, mode: TransitMode?) {
        store.selectedRoutes = [info.route]
        if let mode { store.enabledModes.insert(mode) }
        dismiss()
    }
}

// MARK: - Rows

private struct RouteRow: View {
    let route: TransitRoute

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(route.durationText ?? route.duration.map(minutesText) ?? "—")
                    .font(.title3.weight(.semibold))
                Spacer()
                if let first = route.firstDeparture, let last = route.lastArrival {
                    Text("\(first, style: .time) – \(last, style: .time)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 4) {
                if route.rides.isEmpty {
                    Label("Walk", systemImage: "figure.walk").font(.caption)
                }
                ForEach(Array(route.rides.enumerated()), id: \.offset) { index, ride in
                    if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) }
                    LineChip(ride: ride)
                }
            }
            HStack(spacing: 12) {
                if route.walkingDuration > 0 {
                    Label(minutesText(route.walkingDuration), systemImage: "figure.walk")
                }
                if let fare = route.fareText {
                    Label(fare, systemImage: "creditcard")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct LineChip: View {
    let ride: TransitRoute.Ride

    var body: some View {
        Label(ride.displayName, systemImage: ride.isRail ? "train.side.front.car" : "bus.fill")
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .foregroundStyle(Color(hex: ride.lineTextColor) ?? .white)
            .background(Color(hex: ride.lineColor) ?? .gray, in: RoundedRectangle(cornerRadius: 5))
    }
}

/// Required when showing Routes API results without a Google map.
/// TODO: Google's attribution guidelines call for the Google logo image, not just text;
/// add their official asset before release.
struct GoogleAttribution: View {
    var body: some View {
        Text("Directions powered by Google")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}

func minutesText(_ seconds: TimeInterval) -> String {
    let minutes = max(1, Int((seconds / 60).rounded()))
    return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) hr \(minutes % 60) min"
}

extension Color {
    /// "#RRGGBB" or "RRGGBB"; nil for anything else.
    init?(hex: String?) {
        guard var hex = hex?.trimmingCharacters(in: .whitespaces) else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
