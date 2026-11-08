import SwiftUI

struct VehicleDetailView: View {
    @EnvironmentObject private var store: VehicleStore
    @EnvironmentObject private var rideTracker: RideTracker
    let vehicleID: Vehicle.ID

    var body: some View {
        NavigationStack {
            Group {
                if let vehicle = store.vehicle(withID: vehicleID) {
                    List {
                        Section {
                            row("Vehicle", vehicle.mode == .regionalRail ? "Train \(vehicle.label)" : "#\(vehicle.label)")
                            if let destination = vehicle.destination { row("To", destination) }
                            if let direction = vehicle.direction { row("Direction", direction) }
                            if let nextStop = vehicle.nextStop { row("Next stop", nextStop) }
                            row("Status", vehicle.lateDescription)
                            if let occupancy = vehicle.occupancy {
                                LabeledContent("Crowding") { OccupancyView(occupancy: occupancy) }
                            }
                            if let track = vehicle.track {
                                LabeledContent("Track") {
                                    HStack(spacing: 4) {
                                        Text(track).font(.body.weight(.semibold))
                                        if vehicle.trackChanged {
                                            Text("changed").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                                        }
                                    }
                                }
                            }
                            if let cars = vehicle.cars { row("Train length", "\(cars) car\(cars == 1 ? "" : "s")") }
                            if let service = vehicle.service, service.uppercased() != "LOCAL" { row("Service", service.capitalized) }
                            if let current = vehicle.currentStop { row("At / leaving", current) }
                            if let reportedAt = vehicle.reportedAt {
                                row("Last GPS report", Self.age(since: reportedAt))
                            }
                            row("Position from", vehicle.positionSource.title)
                        }
                        if let bunch = store.bunching[vehicle.id] {
                            Section {
                                Label {
                                    Text("Running with #\(bunch.otherLabel), \(Self.distance(bunch.meters)) apart. The next bus after these two may be a long wait.")
                                } icon: {
                                    Image(systemName: "arrow.left.and.right.square").foregroundStyle(.orange)
                                }
                                .font(.callout)
                            } header: {
                                Text("Bunched")
                            }
                        }
                        if let ride = rideTracker.ride, ride.vehicleID == vehicle.id {
                            Section {
                                Label("You're on this vehicle", systemImage: "figure.seated.side")
                                    .foregroundStyle(.green)
                                if let lag = ride.feedLagSeconds, let meters = ride.feedOffsetMeters {
                                    row("SEPTA's report", "\(Int(lag)) s old, \(Self.distance(meters)) from your phone")
                                }
                                Text("The map shows this vehicle at your phone's position.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("I'm not on this vehicle", role: .destructive) { rideTracker.reject() }
                            } header: {
                                Text("Ride detection")
                            }
                        }
                    }
                    .listStyle(.plain)
                    .navigationTitle(title(for: vehicle))
                } else {
                    ContentUnavailableView(
                        "No longer reporting",
                        systemImage: "location.slash",
                        description: Text("This vehicle dropped out of SEPTA's latest update.")
                    )
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func title(for vehicle: Vehicle) -> String {
        switch vehicle.mode {
        case .regionalRail: return vehicle.route
        case .bus, .trolley: return "\(vehicle.mode.title) \(vehicle.route)"
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value)
    }

    private static func distance(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
    }

    private static func age(since date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        return seconds < 60 ? "\(seconds)s ago" : "\(seconds / 60) min ago"
    }
}

/// Four-bar crowding gauge plus a label ("Few seats").
struct OccupancyView: View {
    let occupancy: Vehicle.Occupancy

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(1...4, id: \.self) { bar in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(bar <= occupancy.level ? color : Color(.systemGray4))
                        .frame(width: 4, height: CGFloat(4 + bar * 3))
                }
            }
            .frame(height: 16, alignment: .bottom)
            Text(occupancy.title)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Crowding: \(occupancy.title)")
    }

    private var color: Color {
        switch occupancy.level {
        case 1: return .green
        case 2: return .yellow
        case 3: return .orange
        default: return .red
        }
    }
}
