import SwiftUI
import MapKit

struct RootView: View {
    @EnvironmentObject private var store: VehicleStore
    @EnvironmentObject private var location: LocationService
    @EnvironmentObject private var saved: SavedPlacesStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    @State private var cameraPosition: MapCameraPosition = .region(Self.philadelphia)
    @State private var selectedVehicleID: Vehicle.ID?
    @State private var showingFilters = false
    @State private var directions: DirectionsRequest?
    @State private var droppedPin: DroppedPin?
    @State private var showingLocationDenied = false
    /// Waiting for the permission prompt's answer before centering.
    @State private var centerWhenAuthorized = false

    @AppStorage("map.style") private var mapStyleChoice = MapStyleChoice.standard
    @AppStorage("map.showsTraffic") private var showsTraffic = false
    @AppStorage("map.showsPlaces") private var showsPlaces = false

    static let philadelphia = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 39.9526, longitude: -75.1652),
        span: MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.12)
    )

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $cameraPosition, selection: $selectedVehicleID) {
                    UserAnnotation()
                    ForEach(store.visibleVehicles) { vehicle in
                        Marker(vehicle.route, systemImage: vehicle.mode.systemImage, coordinate: vehicle.coordinate)
                            .tint(vehicle.mode.tint)
                            .tag(vehicle.id)
                    }
                    ForEach(saved.places.all) { entry in
                        Marker(entry.displayName, systemImage: entry.kind.systemImage, coordinate: entry.place.point.coordinate)
                            .tint(entry.kind == .starred ? .yellow : .indigo)
                    }
                    if let droppedPin {
                        Marker(droppedPin.place.name, systemImage: "mappin", coordinate: droppedPin.place.point.coordinate)
                            .tint(.red)
                    }
                }
                .mapStyle(mapStyle)
                .mapControls {
                    MapCompass()
                    MapPitchToggle()
                    MapScaleView()
                }
                // Long-press anywhere to drop a pin. Simultaneous so panning/zooming still work.
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.5)
                        .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                        .onEnded { value in
                            guard case .second(true, let drag?) = value,
                                  let coordinate = proxy.convert(drag.location, from: .local) else { return }
                            dropPin(at: coordinate)
                        }
                )
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .trailing, spacing: 10) {
                    MapButtons(
                        styleChoice: $mapStyleChoice,
                        showsTraffic: $showsTraffic,
                        showsPlaces: $showsPlaces,
                        locateIcon: locateIcon,
                        onLocate: locateTapped,
                        onShowArea: { withAnimation { cameraPosition = .region(Self.philadelphia) } }
                    )
                    .padding(.trailing, 12)
                    StatusBar()
                }
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
                        openDirections(DirectionsRequest())
                    } label: {
                        Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond")
                    }
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
            // Full screen, not a sheet over the map: Google route content must not be
            // shown together with this (Apple) map.
            .fullScreenCover(item: $directions) { request in
                TripPlannerView(initialDestination: request.destination, initialStart: request.start)
                    .environmentObject(store)
                    .environmentObject(location)
                    .environmentObject(saved)
            }
            .sheet(isPresented: detailBinding) {
                if let id = selectedVehicleID {
                    VehicleDetailView(vehicleID: id)
                        .presentationDetents([.fraction(0.35), .medium])
                        .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.35)))
                }
            }
            .sheet(item: $droppedPin) { pin in
                DroppedPinSheet(
                    pin: pin,
                    directionsTo: { openDirections(DirectionsRequest(destination: pin.place)) },
                    directionsFrom: { openDirections(DirectionsRequest(start: pin.place)) },
                    remove: { droppedPin = nil }
                )
                .environmentObject(saved)
                .presentationDetents([.height(320)])
                .presentationBackgroundInteraction(.enabled)
            }
            .alert("Location is off", isPresented: $showingLocationDenied) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Allow SEPTA Live to use your location in Settings to center the map on you.")
            }
        }
        .onAppear { location.requestPermissionIfNeeded() }
        .onChange(of: location.authorizationStatus) {
            if centerWhenAuthorized, !location.isDenied, location.authorizationStatus != .notDetermined {
                centerWhenAuthorized = false
                withAnimation { cameraPosition = .userLocation(fallback: .region(Self.philadelphia)) }
            }
        }
        // Poll only while the app is in the foreground; changing phase cancels the loop.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await store.pollUntilCancelled()
        }
    }

    // MARK: Map style

    private var mapStyle: MapStyle {
        let places: PointOfInterestCategories = showsPlaces ? .all : .excludingAll
        switch mapStyleChoice {
        case .standard: return .standard(elevation: .realistic, pointsOfInterest: places, showsTraffic: showsTraffic)
        case .hybrid: return .hybrid(elevation: .realistic, pointsOfInterest: places, showsTraffic: showsTraffic)
        case .satellite: return .imagery(elevation: .realistic)
        }
    }

    // MARK: Locate / follow

    /// Off → center and follow you → follow with heading (map turns with you) → follow.
    private func locateTapped() {
        if location.isDenied {
            showingLocationDenied = true
            return
        }
        if location.authorizationStatus == .notDetermined {
            centerWhenAuthorized = true
            location.requestPermissionIfNeeded()
            return
        }
        withAnimation {
            if cameraPosition.followsUserLocation && !cameraPosition.followsUserHeading {
                cameraPosition = .userLocation(followsHeading: true, fallback: .region(Self.philadelphia))
            } else {
                cameraPosition = .userLocation(fallback: .region(Self.philadelphia))
            }
        }
    }

    private var locateIcon: String {
        if location.isDenied { return "location.slash" }
        if cameraPosition.followsUserHeading { return "location.north.line.fill" }
        if cameraPosition.followsUserLocation { return "location.fill" }
        return "location"
    }

    // MARK: Pins and directions

    private func dropPin(at coordinate: CLLocationCoordinate2D) {
        selectedVehicleID = nil   // one sheet at a time
        let point = GeoPoint(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let pin = DroppedPin(place: Place(name: "Dropped pin", subtitle: nil, point: point))
        droppedPin = pin
        Task {
            guard let named = await Self.reverseGeocode(point), droppedPin?.id == pin.id else { return }
            droppedPin = DroppedPin(id: pin.id, place: named)
        }
    }

    /// Street address for a coordinate, via Apple's geocoder. Nil if it fails (e.g. offline).
    private static func reverseGeocode(_ point: GeoPoint) async -> Place? {
        let location = CLLocation(latitude: point.latitude, longitude: point.longitude)
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
        let street = [placemark.subThoroughfare, placemark.thoroughfare].compactMap { $0 }.joined(separator: " ")
        let name = placemark.name ?? (street.isEmpty ? "Dropped pin" : street)
        let area = [placemark.locality, placemark.administrativeArea].compactMap { $0 }.joined(separator: ", ")
        return Place(name: name, subtitle: area.isEmpty ? nil : area, point: point)
    }

    private func openDirections(_ request: DirectionsRequest) {
        selectedVehicleID = nil
        droppedPin = nil
        directions = request
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

// MARK: - Supporting types

enum MapStyleChoice: String, CaseIterable, Identifiable {
    case standard, hybrid, satellite
    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: return "Standard"
        case .hybrid: return "Hybrid"
        case .satellite: return "Satellite"
        }
    }
}

/// What to prefill when opening directions from the map.
struct DirectionsRequest: Identifiable {
    let id = UUID()
    var destination: Place? = nil
    var start: Place? = nil
}

struct DroppedPin: Identifiable, Equatable {
    var id = UUID()
    var place: Place
}

extension GeoPoint {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

// MARK: - Floating map buttons

/// Bottom-right buttons, in the style of Apple Maps: map style menu and locate/follow.
private struct MapButtons: View {
    @Binding var styleChoice: MapStyleChoice
    @Binding var showsTraffic: Bool
    @Binding var showsPlaces: Bool
    let locateIcon: String
    let onLocate: () -> Void
    let onShowArea: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Menu {
                Picker("Map style", selection: $styleChoice) {
                    ForEach(MapStyleChoice.allCases) { Text($0.title).tag($0) }
                }
                if styleChoice != .satellite {
                    Toggle("Traffic", isOn: $showsTraffic)
                    Toggle("Points of interest", isOn: $showsPlaces)
                }
                Divider()
                Button { onShowArea() } label: {
                    Label("Show all of Philadelphia", systemImage: "arrow.up.left.and.arrow.down.right")
                }
            } label: {
                Image(systemName: "map")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Map options")
            Divider().frame(width: 44)
            Button(action: onLocate) {
                Image(systemName: locateIcon)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Center on my location")
        }
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(.tint)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }
}

// MARK: - Dropped pin sheet

private struct DroppedPinSheet: View {
    @EnvironmentObject private var saved: SavedPlacesStore
    let pin: DroppedPin
    let directionsTo: () -> Void
    let directionsFrom: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pin.place.name).font(.title3.weight(.semibold))
                    Text(pin.place.subtitle ?? String(format: "%.5f, %.5f", pin.place.point.latitude, pin.place.point.longitude))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive, action: remove) {
                    Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary)
                }
                .accessibilityLabel("Remove pin")
            }

            HStack(spacing: 10) {
                Button(action: directionsTo) {
                    Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button(action: directionsFrom) {
                    Label("From here", systemImage: "figure.walk.departure")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)

            HStack(spacing: 10) {
                saveButton(saved.places.isStarred(pin.place) ? "Starred" : "Star",
                           icon: saved.places.isStarred(pin.place) ? "star.fill" : "star") {
                    if saved.places.isStarred(pin.place) { saved.places.unstar(pin.place) }
                    else { saved.places.save(pin.place, as: .starred) }
                }
                saveButton("Set Home", icon: "house") { saved.places.save(pin.place, as: .home) }
                saveButton("Set Work", icon: "briefcase") { saved.places.save(pin.place, as: .work) }
            }
            Spacer(minLength: 0)
        }
        .padding()
    }

    private func saveButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }
}

// MARK: - Status bar

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
