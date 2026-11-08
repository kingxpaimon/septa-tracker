import SwiftUI

/// Step-by-step view of one recommended route, with live SEPTA info for each ride.
struct RouteDetailView: View {
    @EnvironmentObject private var store: VehicleStore
    @EnvironmentObject private var alerts: TripAlerts
    let route: TransitRoute
    let source: TripPlanner.Engine
    let showOnMap: (LiveLineMatcher.LiveInfo, TransitMode?) -> Void
    @State private var showingFullMap = false

    /// Google routes can't be drawn on this app's Apple map (Google's terms).
    private var canDraw: Bool { source != .google && route.allPoints.count >= 2 }

    /// Live vehicles running this route's exact trips.
    private var tripVehicles: [Vehicle] {
        route.rides.compactMap { LiveLineMatcher.liveInfo(for: $0, in: store.allVehicles, waiting: store.waitingVehicles)?.tripVehicle }
    }

    var body: some View {
        List {
            if canDraw {
                Section {
                    RouteMapView(route: route, liveVehicles: tripVehicles, interactive: false)
                        .frame(height: 260)
                        .listRowInsets(EdgeInsets())
                        .overlay(alignment: .topTrailing) {
                            Button { showingFullMap = true } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 14, weight: .semibold))
                                    .frame(width: 34, height: 34)
                                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(.separator)))
                            }
                            .padding(8)
                            .accessibilityLabel("Expand map")
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { showingFullMap = true }
                    RouteLegend(route: route)
                }
            }
            if let leave = leaveTime, let first = route.rides.first, leave > Date() {
                Section {
                    reminderToggle(id: leaveAlertID, title: "Remind me when to leave",
                                   detail: "2 min before \(leave.formatted(date: .omitted, time: .shortened))") {
                        TripAlert(id: leaveAlertID, kind: .leave, title: "Time to leave",
                                  message: "Head out for the \(first.displayName) at \(first.departureStopName ?? "your stop")",
                                  eventTime: leave, leadMinutes: 2, tripID: first.tripID)
                    }
                } footer: {
                    if alerts.permissionDenied {
                        Text("Notifications are off for SEPTA Live. Turn them on in Settings to get reminders.")
                    } else {
                        Text("Reminders use the predicted time when you set them. Nearby keeps departure reminders up to date while the app is open.")
                    }
                }
            }
            Section {
                ForEach(Array(route.segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .walk(let walk):
                        WalkRow(walk: walk)
                    case .ride(let ride):
                        RideRow(ride: ride, live: LiveLineMatcher.liveInfo(for: ride, in: store.allVehicles, waiting: store.waitingVehicles),
                                bunch: LiveLineMatcher.liveInfo(for: ride, in: store.allVehicles)?.tripVehicle.flatMap { store.bunching[$0.id] },
                                showOnMap: showOnMap)
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(route.warnings, id: \.self) { Text($0) }
                    switch source {
                    case .google: GoogleAttribution()
                    case .transitous: TransitousAttribution()
                    case .septa: EmptyView()
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.getOffReminder, getOffReminder)
        .navigationTitle(route.durationText ?? "Route")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingFullMap) {
            NavigationStack {
                RouteMapView(route: route, liveVehicles: tripVehicles)
                    .ignoresSafeArea(edges: .bottom)
                    .safeAreaInset(edge: .bottom) {
                        RouteLegend(route: route)
                            .padding()
                            .background(Color(.systemBackground))
                    }
                    .navigationTitle(route.durationText ?? "Route")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingFullMap = false }
                        }
                    }
            }
        }
    }
}

extension RouteDetailView {
    /// When to start walking to the first stop.
    private var leaveTime: Date? {
        guard let first = route.rides.first?.departureTime else { return nil }
        if case .walk(let w)? = route.segments.first { return first.addingTimeInterval(-w.duration) }
        return first
    }

    private var leaveAlertID: String {
        "leave-" + route.rides.map { $0.tripID ?? $0.displayName }.joined(separator: "+")
    }

    @ViewBuilder
    private func reminderToggle(id: String, title: String, detail: String, make: @escaping () -> TripAlert) -> some View {
        let isOn = alerts.alert(id: id) != nil
        Button {
            if isOn { alerts.cancel(id: id) } else { Task { await alerts.schedule(make()) } }
        } label: {
            HStack {
                Label(title, systemImage: isOn ? "bell.fill" : "bell")
                Spacer()
                Text(isOn ? "On" : detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Passed to ride rows so they can offer "Alert me before my stop".
    private var getOffReminder: GetOffReminder {
        GetOffReminder(isOn: { alerts.alert(id: $0) != nil },
                       toggle: { ride in
                           guard let arrival = ride.arrivalTime else { return }
                           let id = GetOffReminder.id(for: ride)
                           if alerts.alert(id: id) != nil { alerts.cancel(id: id); return }
                           Task {
                               await alerts.schedule(TripAlert(id: id, kind: .getOff, title: "Get off soon",
                                                               message: ride.arrivalStopName ?? "Your stop",
                                                               eventTime: arrival, leadMinutes: 2, tripID: ride.tripID))
                           }
                       })
    }
}

/// "Alert me before my stop" plumbing from RouteDetailView to its ride rows.
struct GetOffReminder {
    var isOn: (String) -> Bool = { _ in false }
    var toggle: (TransitRoute.Ride) -> Void = { _ in }
    static func id(for ride: TransitRoute.Ride) -> String {
        "getoff-\(ride.tripID ?? ride.displayName)-\(ride.arrivalStopName ?? "")"
    }
}

private struct GetOffReminderKey: EnvironmentKey {
    static let defaultValue = GetOffReminder()
}

extension EnvironmentValues {
    var getOffReminder: GetOffReminder {
        get { self[GetOffReminderKey.self] }
        set { self[GetOffReminderKey.self] = newValue }
    }
}

private struct WalkRow: View {
    let walk: TransitRoute.Walk

    var body: some View {
        Label {
            Text("Walk \(minutesText(walk.duration))")
                + Text(walk.distanceMeters > 0 ? " · \(Self.distance(Double(walk.distanceMeters)))" : "")
                    .foregroundColor(.secondary)   // Text-returning modifier, so `+` still works
        } icon: {
            Image(systemName: "figure.walk")
        }
    }

    static func distance(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }
}

private struct RideRow: View {
    let ride: TransitRoute.Ride
    let live: LiveLineMatcher.LiveInfo?
    var bunch: VehicleInsights.Bunch? = nil
    let showOnMap: (LiveLineMatcher.LiveInfo, TransitMode?) -> Void
    @Environment(\.getOffReminder) private var getOffReminder

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                LineChip(ride: ride)
                if let headsign = ride.headsign {
                    Text("toward \(headsign)").font(.subheadline)
                }
            }
            if let stop = ride.departureStopName {
                timeLine("Board at \(stop)", ride.departureTimeText ?? ride.departureTime.map(Self.time))
            }
            if let train = ride.trainNumber {
                Text("Train \(train)").font(.caption).foregroundStyle(.secondary)
            }
            if let delay = ride.liveDelaySeconds {
                Label(Self.delayText(delay), systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(delay > 120 ? Color.orange : Color.green)
            }
            if let count = ride.stopCount {
                Text("\(count) stop\(count == 1 ? "" : "s")" + (ride.duration.map { " · \(minutesText($0))" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let stop = ride.arrivalStopName {
                timeLine("Get off at \(stop)", ride.arrivalTimeText ?? ride.arrivalTime.map(Self.time))
            }
            if let arrival = ride.arrivalTime, arrival > Date() {
                let on = getOffReminder.isOn(GetOffReminder.id(for: ride))
                Button { getOffReminder.toggle(ride) } label: {
                    Label(on ? "Stop alert on (2 min before)" : "Alert me before my stop", systemImage: on ? "bell.fill" : "bell")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
            }
            liveSection
        }
        .padding(.vertical, 4)
    }

    private func timeLine(_ text: String, _ time: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).font(.subheadline)
            Spacer()
            if let time { Text(time).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder
    private var liveSection: some View {
        if let live {
            VStack(alignment: .leading, spacing: 4) {
                Label(liveSummary(live), systemImage: live.tripVehicleIsWaiting ? "clock" : "dot.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(live.tripVehicleIsWaiting ? Color.blue : Color.green)
                if let vehicle = live.tripVehicle, vehicle.mode == .regionalRail, vehicle.track != nil || vehicle.cars != nil {
                    // Where to stand: platform and train length.
                    HStack(spacing: 10) {
                        if let track = vehicle.track {
                            Label("Track \(track)\(vehicle.trackChanged ? " (changed)" : "")", systemImage: "signpost.right")
                                .foregroundStyle(vehicle.trackChanged ? Color.orange : Color.primary)
                        }
                        if let cars = vehicle.cars {
                            Label("\(cars) car\(cars == 1 ? "" : "s")", systemImage: "tram")
                        }
                    }
                    .font(.caption.weight(.semibold))
                }
                if let occupancy = live.tripVehicle?.occupancy {
                    OccupancyView(occupancy: occupancy).font(.caption)
                }
                if let bunch {
                    Label("Bunched with #\(bunch.otherLabel) (\(WalkRow.distance(bunch.meters)) apart)", systemImage: "arrow.left.and.right.square")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button {
                    showOnMap(live, live.nearest?.mode)
                } label: {
                    Text("Show \(live.route) on live map").font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
            }
        } else if ride.isSEPTA && ride.liveDelaySeconds == nil {
            Text(ride.tripID == nil ? "No live SEPTA vehicles matched this line." : "No live data for this trip yet (scheduled time).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func delayText(_ seconds: Int) -> String {
        let minutes = Int((Double(seconds) / 60).rounded())
        if minutes == 0 { return "Live: on time" }
        return minutes > 0 ? "Live: \(minutes) min late (times adjusted)" : "Live: \(-minutes) min early (times adjusted)"
    }

    private func liveSummary(_ live: LiveLineMatcher.LiveInfo) -> String {
        if let vehicle = live.tripVehicle, live.tripVehicleIsWaiting {
            return "Your \(vehicle.mode.title.lowercased()) #\(vehicle.label) is waiting at its first stop"
        }
        if let vehicle = live.tripVehicle {
            let noun = vehicle.mode == .regionalRail ? "Your train" : "Your \(vehicle.mode.title.lowercased()) #\(vehicle.label)"
            var text = noun + " is live"
            if let meters = live.tripVehicleDistanceMeters {
                text += ", \(WalkRow.distance(meters)) from your stop"
            }
            return text
        }
        var text = "\(live.vehicleCount) live on \(live.route)"
        if let nearest = live.nearest, let meters = live.nearestDistanceMeters {
            text += " · closest is \(WalkRow.distance(meters)) from your stop (may already have passed it)"
            if let late = nearest.minutesLate {
                text += late == 0 ? ", on time" : (late > 0 ? ", \(late) min late" : ", \(-late) min early")
            }
        }
        return text
    }
}
