import SwiftUI

/// Step-by-step view of one recommended route, with live SEPTA info for each ride.
struct RouteDetailView: View {
    @EnvironmentObject private var store: VehicleStore
    let route: TransitRoute
    let showOnMap: (LiveLineMatcher.LiveInfo, TransitMode?) -> Void

    var body: some View {
        List {
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
                    GoogleAttribution()
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(route.durationText ?? "Route")
        .navigationBarTitleDisplayMode(.inline)
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
                timeLine("Board at \(stop)", ride.departureTimeText)
            }
            if let count = ride.stopCount {
                Text("\(count) stop\(count == 1 ? "" : "s")" + (ride.duration.map { " · \(minutesText($0))" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let stop = ride.arrivalStopName {
                timeLine("Get off at \(stop)", ride.arrivalTimeText)
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
        } else if ride.isSEPTA {
            Text("No live SEPTA vehicles matched this line.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func liveSummary(_ live: LiveLineMatcher.LiveInfo) -> String {
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
