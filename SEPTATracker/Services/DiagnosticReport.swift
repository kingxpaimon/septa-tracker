import Foundation

/// What the app saw at a moment, for reporting a problem from a real trip.
/// Built only when the user taps "Share diagnostic snapshot" and shared only through the
/// share sheet they choose. Contains their location, so the UI says so before sharing.
struct DiagnosticReport: Codable {
    struct VehicleSnapshot: Codable {
        let id: String
        let route: String
        let label: String
        let latitude: Double
        let longitude: Double
        let reportedAt: Date?
        let minutesLate: Int?
        let destination: String?
        let tripID: String?
        let source: String
    }

    struct RideSnapshot: Codable {
        let vehicleID: String
        let since: Date
        let feedLagSeconds: Double?
        let feedOffsetMeters: Double?
    }

    let appVersion: String
    let createdAt: Date
    let note: String
    let userLatitude: Double?
    let userLongitude: Double?
    let userAccuracyMeters: Double?
    let feedUpdatedAt: Date?
    let feedErrors: [String]
    /// Vehicles within `radiusMeters` of the user (or all, capped, when location is unknown).
    let nearbyVehicles: [VehicleSnapshot]
    let waitingVehicleCount: Int
    let ride: RideSnapshot?

    static let radiusMeters = 1_500.0

    static func make(note: String, user: (point: GeoPoint, accuracy: Double)?, vehicles: [Vehicle], waitingCount: Int,
                     feedUpdatedAt: Date?, feedErrors: [String], ride: RideDetector.Ride?,
                     appVersion: String, now: Date = Date()) -> DiagnosticReport {
        var chosen = vehicles
        if let user {
            chosen = vehicles.filter { user.point.distance(to: GeoPoint(latitude: $0.latitude, longitude: $0.longitude)) <= radiusMeters }
        }
        return DiagnosticReport(
            appVersion: appVersion, createdAt: now, note: note,
            userLatitude: user?.point.latitude, userLongitude: user?.point.longitude, userAccuracyMeters: user?.accuracy,
            feedUpdatedAt: feedUpdatedAt, feedErrors: feedErrors,
            nearbyVehicles: chosen.prefix(200).map {
                VehicleSnapshot(id: $0.id, route: $0.route, label: $0.label, latitude: $0.latitude, longitude: $0.longitude,
                                reportedAt: $0.reportedAt, minutesLate: $0.minutesLate, destination: $0.destination,
                                tripID: $0.tripID, source: $0.positionSource.rawValue)
            },
            waitingVehicleCount: waitingCount,
            ride: ride.map { RideSnapshot(vehicleID: $0.vehicleID, since: $0.since, feedLagSeconds: $0.feedLagSeconds, feedOffsetMeters: $0.feedOffsetMeters) })
    }

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
