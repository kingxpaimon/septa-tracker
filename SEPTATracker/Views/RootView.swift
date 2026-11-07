import SwiftUI
import MapKit

struct RootView: View {
    @EnvironmentObject private var store: VehicleStore
    @EnvironmentObject private var location: LocationService
    @Environment(\.scenePhase) private var scenePhase

    @State private var cameraPosition: MapCameraPosition = .region(Self.philadelphia)
    @State private var selectedVehicleID: Vehicle.ID?
    @State private var showingFilters = false

    static let philadelphia = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 39.9526, longitude: -75.1652),
        span: MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.12)
    )

    var body: some View {
        NavigationStack {
            Map(position: $cameraPosition, selection: $selectedVehicleID) {
                UserAnnotation()
                ForEach(store.visibleVehicles) { vehicle in
                    Marker(vehicle.route, systemImage: vehicle.mode.systemImage, coordinate: vehicle.coordinate)
                        .tint(vehicle.mode.tint)
                        .tag(vehicle.id)
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .mapControls {
                MapUserLocationButton()
                MapCompass()
                MapScaleView()
            }
            .safeAreaInset(edge: .bottom) {
                StatusBar()
            }
            .navigationTitle("SEPTA Live")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await store.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.isRefreshing)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingFilters = true
                    } label: {
                        Label("Filter", systemImage: isFiltered
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .sheet(isPresented: $showingFilters) {
                FilterView()
            }
            .sheet(isPresented: detailBinding) {
                if let id = selectedVehicleID {
                    VehicleDetailView(vehicleID: id)
                        .presentationDetents([.fraction(0.35), .medium])
                        .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.35)))
                }
            }
        }
        .onAppear { location.requestPermissionIfNeeded() }
        // Poll only while the app is in the foreground; changing phase cancels the loop.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await store.pollUntilCancelled()
        }
    }

    private var isFiltered: Bool {
        !store.selectedRoutes.isEmpty || store.enabledModes.count < TransitMode.allCases.count
    }

    private var detailBinding: Binding<Bool> {
        Binding(
            get: { selectedVehicleID != nil },
            set: { if !$0 { selectedVehicleID = nil } }
        )
    }
}

private struct StatusBar: View {
    @EnvironmentObject private var store: VehicleStore

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(store.visibleVehicles.count) vehicles")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                } else if let updated = store.lastUpdated {
                    Text("Updated \(updated, style: .relative) ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(store.errors, id: \.self) { message in
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }
}
