import SwiftUI
import MapKit

/// A recommended route drawn on the map: each ride in its line's color (rail drawn
/// thicker), walking as a dotted gray line, with start, boarding/transfer stops, the
/// destination, and any live vehicles running those exact trips.
///
/// Only for Transitous and on-device SEPTA routes. Google's terms forbid showing Routes
/// API content on a non-Google map, so Google routes never reach this view.
struct RouteMapView: View {
    let route: TransitRoute
    var liveVehicles: [Vehicle] = []
    var interactive = true

    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $position, interactionModes: interactive ? .all : []) {
            // White casing under each ride line so colors stay legible on the map.
            ForEach(lines.filter { !$0.isWalk }) { line in
                MapPolyline(coordinates: line.coordinates)
                    .stroke(.white, style: StrokeStyle(lineWidth: line.width + 3, lineCap: .round, lineJoin: .round))
            }
            ForEach(lines) { line in
                MapPolyline(coordinates: line.coordinates)
                    .stroke(line.color, style: line.style)
            }
            ForEach(stops) { stop in
                Annotation(stop.title, coordinate: stop.coordinate, anchor: .center) {
                    Image(systemName: stop.icon)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(stop.color, in: Circle())
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
            if let end = route.allPoints.last {
                Marker("Destination", systemImage: "mappin", coordinate: end.coordinate)
                    .tint(.red)
            }
            ForEach(liveVehicles) { vehicle in
                Marker("\(vehicle.route) #\(vehicle.label)", systemImage: vehicle.mode.systemImage, coordinate: vehicle.coordinate)
                    .tint(vehicle.mode.tint)
            }
            UserAnnotation()
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .onAppear { position = Self.fit(route.allPoints + liveVehicles.map { GeoPoint(latitude: $0.latitude, longitude: $0.longitude) }) }
    }

    // MARK: Lines and stops

    private struct Line: Identifiable {
        let id: Int
        let coordinates: [CLLocationCoordinate2D]
        let color: Color
        let width: CGFloat
        let isWalk: Bool
        var style: StrokeStyle {
            isWalk
                ? StrokeStyle(lineWidth: width, lineCap: .round, dash: [1, 8])
                : StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
        }
    }

    private struct Stop: Identifiable {
        let id: Int
        let title: String
        let coordinate: CLLocationCoordinate2D
        let color: Color
        let icon: String
    }

    private var lines: [Line] {
        route.segments.enumerated().compactMap { index, segment in
            switch segment {
            case .walk(let w):
                guard w.path.count >= 2 else { return nil }
                return Line(id: index, coordinates: w.path.map(\.coordinate), color: .gray, width: 5, isWalk: true)
            case .ride(let r):
                guard r.path.count >= 2 else { return nil }
                return Line(id: index, coordinates: r.path.map(\.coordinate), color: Self.color(for: r),
                            width: r.isRail ? 7 : 5, isWalk: false)
            }
        }
    }

    private var stops: [Stop] {
        var result: [Stop] = []
        if let start = route.allPoints.first {
            result.append(Stop(id: -1, title: "Start", coordinate: start.coordinate, color: .green, icon: "figure.walk"))
        }
        for (index, ride) in route.rides.enumerated() {
            if let board = ride.path.first {
                result.append(Stop(id: index * 2, title: ride.departureStopName ?? ride.displayName,
                                   coordinate: board.coordinate, color: Self.color(for: ride),
                                   icon: ride.isRail ? "tram.fill" : "bus.fill"))
            }
            // Where you get off, unless it's the last ride (the destination marker covers it).
            if index < route.rides.count - 1, let alight = ride.path.last {
                result.append(Stop(id: index * 2 + 1, title: ride.arrivalStopName ?? "Transfer",
                                   coordinate: alight.coordinate, color: Self.color(for: ride),
                                   icon: "arrow.triangle.swap"))
            }
        }
        return result
    }

    /// The line's own color when the data has one; otherwise a per-mode default.
    static func color(for ride: TransitRoute.Ride) -> Color {
        if let c = Color(hex: ride.lineColor) { return c }
        switch ride.vehicleType {
        case "COMMUTER_TRAIN", "HEAVY_RAIL", "RAIL": return .purple
        case "SUBWAY": return .orange
        case "TRAM": return .green
        default: return .blue
        }
    }

    /// Camera framing all points with some padding.
    static func fit(_ points: [GeoPoint]) -> MapCameraPosition {
        guard !points.isEmpty else { return .automatic }
        let mapPoints = points.map { MKMapPoint($0.coordinate) }
        let minX = mapPoints.map(\.x).min()!, maxX = mapPoints.map(\.x).max()!
        let minY = mapPoints.map(\.y).min()!, maxY = mapPoints.map(\.y).max()!
        let minSize = MKMapPointsPerMeterAtLatitude(points[0].latitude) * 400
        let w = max(maxX - minX, minSize), h = max(maxY - minY, minSize)
        let rect = MKMapRect(x: (minX + maxX - w) / 2, y: (minY + maxY - h) / 2, width: w, height: h)
        return .rect(rect.insetBy(dx: -w * 0.15, dy: -h * 0.2))
    }
}

/// Legend under the map: each part of the trip with its line style.
struct RouteLegend: View {
    let route: TransitRoute

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(route.segments.enumerated()), id: \.offset) { index, segment in
                    if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) }
                    switch segment {
                    case .walk(let w):
                        Label(minutesText(w.duration), systemImage: "figure.walk")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .ride(let r):
                        LineChip(ride: r)
                    }
                }
            }
        }
    }
}
