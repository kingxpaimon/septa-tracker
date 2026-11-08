import SwiftUI

/// "Share diagnostic snapshot": a note plus what the app saw right now, as a JSON file the
/// user shares however they like (Mail, Messages, AirDrop…). Nothing is sent automatically.
struct DiagnosticSheet: View {
    @EnvironmentObject private var store: VehicleStore
    @EnvironmentObject private var location: LocationService
    @EnvironmentObject private var rideTracker: RideTracker
    @Environment(\.dismiss) private var dismiss

    @State private var note = ""
    @State private var fileURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What looks wrong? e.g. \"Route 21 bus not shown at Broad & Walnut\"", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("Your note")
                }
                Section {
                    Label("Your current location", systemImage: "location")
                    Label("Live vehicles within 1.5 km (route, position, lateness, trip)", systemImage: "bus")
                    Label("Feed status and ride detection state", systemImage: "waveform.path.ecg")
                } header: {
                    Text("Included")
                } footer: {
                    Text("Saved as a file you share yourself. Nothing is uploaded by the app.")
                }
                Section {
                    if let fileURL {
                        ShareLink(item: fileURL) {
                            Label("Share snapshot", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        Button {
                            Task { await makeFile() }
                        } label: {
                            Label("Create snapshot", systemImage: "doc.badge.plus")
                        }
                    }
                    if let errorMessage { Text(errorMessage).foregroundStyle(.orange) }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Report a problem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .onChange(of: note) { fileURL = nil }   // re-create after edits
        }
        .keyboardDismissButton()
    }

    private func makeFile() async {
        errorMessage = nil
        var user: (GeoPoint, Double)?
        if let fix = try? await location.currentLocation() {
            user = (GeoPoint(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude), fix.horizontalAccuracy)
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let report = DiagnosticReport.make(note: note, user: user, vehicles: store.allVehicles,
                                           waitingCount: store.waitingVehicles.count,
                                           feedUpdatedAt: store.lastUpdated, feedErrors: store.errors,
                                           ride: rideTracker.ride, appVersion: version)
        do {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("SEPTA-Live-snapshot-\(stamp).json")
            try report.jsonData().write(to: url, options: .atomic)
            fileURL = url
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
