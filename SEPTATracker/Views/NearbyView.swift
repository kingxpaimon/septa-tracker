import SwiftUI

/// Next departures around you, one card per line and direction, refreshed every minute.
/// Uses the on-device SEPTA schedule plus SEPTA's live predictions.
struct NearbyView: View {
    @EnvironmentObject private var location: LocationService
    @EnvironmentObject private var store: VehicleStore
    @EnvironmentObject private var alerts: TripAlerts
    @Environment(\.dismiss) private var dismiss

    @State private var lines: [LineDepartures] = []
    @State private var status: String?
    @State private var errorMessage: String?
    @State private var note: String?
    @State private var lastRefresh: Date?

    static let refreshInterval: Duration = .seconds(60)

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else if lines.isEmpty, let status {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(status).foregroundStyle(.secondary)
                    }
                } else if lines.isEmpty && lastRefresh != nil {
                    ContentUnavailableView("No departures nearby",
                                           systemImage: "bus",
                                           description: Text("Nothing leaves within 500 m of you in the next 90 minutes."))
                }
                ForEach(lines) { line in
                    NearbyLineRow(line: line, showOnMap: line.routeType == 1 ? nil : { showOnMap(line) })
                }
                if !lines.isEmpty {
                    Section {
                        EmptyView()
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("• = live SEPTA prediction; other times are scheduled.")
                            if let note { Text(note) }
                            if let lastRefresh { Text("Updated \(lastRefresh, style: .relative) ago") }
                        }
                        .font(.caption2)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await refresh() }
            .navigationTitle("Nearby")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task {
                while !Task.isCancelled {
                    await refresh()
                    try? await Task.sleep(for: Self.refreshInterval)
                }
            }
        }
    }

    private func refresh() async {
        errorMessage = nil
        do {
            if lines.isEmpty { status = "Finding your location…" }
            let here = try await location.currentLocation().coordinate
            if lines.isEmpty { status = "Loading departures…" }
            let result = try await ScheduleStore.shared.departures(near: GeoPoint(latitude: here.latitude, longitude: here.longitude)) { phase in
                Task { @MainActor in if !phase.message.isEmpty { status = phase.message } }
            }
            lines = result.lines
            lastRefresh = Date()
            status = nil
            var notes: [String] = []
            if let warning = result.staleScheduleWarning { notes.append(warning) }
            if result.liveTrips == nil { notes.append("Live predictions are unavailable right now.") }
            note = notes.isEmpty ? nil : notes.joined(separator: " ")
            // Keep departure reminders in step with the latest predictions.
            var times: [String: Date] = [:]
            for line in result.lines { for d in line.departures { times[DepartureChip.alertID(d, line)] = d.time } }
            await alerts.update(eventTimes: times)
        } catch is CancellationError {
            return
        } catch {
            if (error as? URLError)?.code == .cancelled { return }
            status = nil
            errorMessage = location.isDenied
                ? "Turn on location for SEPTA Live in Settings to see departures near you."
                : error.localizedDescription
        }
    }

    private func showOnMap(_ line: LineDepartures) {
        store.selectedRoutes = [line.displayName]
        store.enabledModes.insert(line.isRail ? .regionalRail : TransitMode.forSurfaceRoute(line.routeShortName))
        dismiss()
    }
}

private struct NearbyLineRow: View {
    let line: LineDepartures
    let showOnMap: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                RouteBadge(name: line.displayName, systemImage: line.systemImage, color: line.color, textColor: line.textColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("to \(line.headsign)").font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("\(line.stopName) · \(minutesText(line.walkMeters / 1.3)) walk")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let showOnMap {
                    Button(action: showOnMap) {
                        Image(systemName: "map").imageScale(.medium)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Show \(line.displayName) on the map")
                }
            }
            HStack(spacing: 14) {
                ForEach(line.departures) { departure in
                    DepartureChip(departure: departure, line: line)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// "4 min •" with a bell menu for a reminder before it leaves.
private struct DepartureChip: View {
    @EnvironmentObject private var alerts: TripAlerts
    let departure: LineDepartures.Departure
    let line: LineDepartures

    private var alertID: String { Self.alertID(departure, line) }

    static func alertID(_ departure: LineDepartures.Departure, _ line: LineDepartures) -> String {
        "departure-\(departure.id)-\(line.stopID)"
    }

    var body: some View {
        Menu {
            Text("\(line.displayName) at \(departure.time.formatted(date: .omitted, time: .shortened))")
            if let delay = departure.delaySeconds {
                Text(delay >= 60 ? "\(delay / 60) min late" : delay <= -60 ? "\(-delay / 60) min early" : "On time")
            }
            Divider()
            if alerts.alert(id: alertID) != nil {
                Button(role: .destructive) { alerts.cancel(id: alertID) } label: { Label("Cancel reminder", systemImage: "bell.slash") }
            } else {
                ForEach([2, 5, 10], id: \.self) { lead in
                    Button {
                        Task { await alerts.schedule(reminder(lead: lead)) }
                    } label: {
                        Label("Remind me \(lead) min before", systemImage: "bell")
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(countdown).font(.body.monospacedDigit().weight(.semibold))
                if departure.isLive {
                    Image(systemName: "dot.radiowaves.left.and.right").font(.caption2).foregroundStyle(.green)
                }
                if alerts.alert(id: alertID) != nil {
                    Image(systemName: "bell.fill").font(.caption2).foregroundStyle(.orange)
                }
            }
            .foregroundStyle(.primary)
        }
        .accessibilityLabel("\(countdown)\(departure.isLive ? ", live" : ", scheduled")")
    }

    private var countdown: String {
        let minutes = Int(departure.time.timeIntervalSinceNow / 60)
        return minutes <= 0 ? "Now" : "\(minutes) min"
    }

    private func reminder(lead: Int) -> TripAlert {
        TripAlert(id: alertID, kind: .departure,
                  title: "\(line.displayName) to \(line.headsign)",
                  message: "Leaves \(line.stopName)",
                  eventTime: departure.time, leadMinutes: lead, tripID: departure.tripID)
    }
}

/// Colored route badge used in lists ("21", "T1", "Trenton").
struct RouteBadge: View {
    let name: String
    let systemImage: String
    let color: String?
    let textColor: String?

    var body: some View {
        Label(name, systemImage: systemImage)
            .font(.subheadline.weight(.bold))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .foregroundStyle(Color(hex: textColor) ?? .white)
            .background(Color(hex: color) ?? .blue, in: RoundedRectangle(cornerRadius: 6))
    }
}
