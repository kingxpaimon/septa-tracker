import SwiftUI

/// Step-by-step view of one recommended route, with live SEPTA info for each ride.
struct RouteDetailView: View {
    @EnvironmentObject private var store: VehicleStore
    let route: TransitRoute
    let source: TripPlanner.Engine
    let showOnMap: (LiveLineMatcher.LiveInfo, TransitMode?) -> Void
    @State private var showingFullMap = false

    /// Google routes can't be drawn on this app's Apple map (Google's terms).
    private var canDraw: Bool { source != .google && route.allPoints.count >= 2 }

    /// Live vehicles running this route's exact trips.
    private var tripVehicles: [Vehicle] {
        route.rides.compactMap { LiveLineMatcher.liveInfo(for: $0, in: store.allVehicles)?.tripVehicle }
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
            Section {
                ForEach(Array(route.segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .walk(let walk):
                        WalkRow(walk: walk)
                    case .ride(let ride):
                        RideRow(ride: ride, live: LiveLineMatcher.liveInfo(for: ride, in: store.allVehicles), showOnMap: showOnMap)
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
    let showOnMap: (LiveLineMatcher.LiveInfo, TransitMode?) -> Void

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
                Label(liveSummary(live), systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.green)
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
