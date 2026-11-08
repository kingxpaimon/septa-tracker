import Foundation

/// One vehicle from a GTFS-realtime `VehiclePositions` feed.
struct RealtimeVehiclePosition: Hashable {
    /// `VehicleDescriptor.id`. For SEPTA buses/trolleys this is the fleet number
    /// (same as TransitView `label`); for Regional Rail it's the consist, e.g. "859,860,831,832".
    let vehicleID: String
    let label: String?
    /// `TripDescriptor.trip_id`. Missing for vehicles that aren't in service.
    let tripID: String?
    /// `TripDescriptor.route_id`. Matches TransitView route keys for buses/trolleys;
    /// for rail it's a line code such as "PAO" or "TRE".
    let routeID: String?
    let latitude: Double
    let longitude: Double
    let bearing: Double?
    let timestamp: Date?

    /// Regional Rail trip IDs look like `PAO9566_20261019_SID189798`; the digits after the
    /// line code are the train number TrainView calls `trainno`.
    var trainNumber: String? {
        guard let tripID, let underscore = tripID.firstIndex(of: "_") else { return nil }
        let digits = tripID[..<underscore].drop { $0.isLetter }
        return !digits.isEmpty && digits.allSatisfy(\.isNumber) ? String(digits) : nil
    }
}

/// One trip from a GTFS-realtime `TripUpdates` feed.
struct RealtimeTripUpdate: Hashable {
    struct StopUpdate: Hashable {
        let stopSequence: Int?
        let stopID: String?
        /// Absolute predicted times (Unix seconds), when given (SEPTA buses).
        let arrivalTime: Int64?
        let departureTime: Int64?
        /// Delay in seconds relative to schedule, when given (SEPTA rail).
        let arrivalDelay: Int?
        let departureDelay: Int?
        /// The vehicle won't stop here.
        let skipped: Bool
    }

    let tripID: String
    let routeID: String?
    /// yyyymmdd, when given.
    let startDate: String?
    let canceled: Bool
    let vehicleID: String?
    let stopUpdates: [StopUpdate]
}

/// Decodes the subset of the GTFS-realtime protobuf schema the app uses
/// (https://gtfs.org/realtime/reference/). Written by hand to avoid a SwiftProtobuf
/// dependency; unknown fields are skipped, so schema additions don't break it.
enum GTFSRealtime {
    static func parseVehiclePositions(_ data: Data) throws -> [RealtimeVehiclePosition] {
        var feed = ProtobufReader(data)
        var result: [RealtimeVehiclePosition] = []
        var sawHeader = false
        while let (field, value) = try feed.next() {
            switch (field, value) {
            case (1, .bytes): sawHeader = true          // FeedMessage.header
            case (2, .bytes(let entity)):               // FeedMessage.entity
                if let vehicle = try parseEntity(entity) { result.append(vehicle) }
            default: continue
            }
        }
        guard sawHeader else { throw ProtobufError.malformed("no FeedHeader") }
        return result
    }

    static func parseTripUpdates(_ data: Data) throws -> [RealtimeTripUpdate] {
        var feed = ProtobufReader(data)
        var result: [RealtimeTripUpdate] = []
        var sawHeader = false
        while let (field, value) = try feed.next() {
            switch (field, value) {
            case (1, .bytes): sawHeader = true
            case (2, .bytes(let entity)):
                var e = ProtobufReader(entity)
                while let (f, v) = try e.next() {
                    if f == 2, case .varint(let deleted) = v, deleted != 0 { break }
                    if f == 3, case .bytes(let b) = v, let update = try parseTripUpdate(b) { result.append(update) }
                }
            default: continue
            }
        }
        guard sawHeader else { throw ProtobufError.malformed("no FeedHeader") }
        return result
    }

    private static func parseTripUpdate(_ bytes: [UInt8]) throws -> RealtimeTripUpdate? {
        var reader = ProtobufReader(bytes)
        var tripID: String?, routeID: String?, startDate: String?, vehicleID: String?
        var canceled = false
        var stops: [RealtimeTripUpdate.StopUpdate] = []
        while let (field, value) = try reader.next() {
            switch (field, value) {
            case (1, .bytes(let trip)):                  // TripDescriptor
                var t = ProtobufReader(trip)
                while let (f, v) = try t.next() {
                    switch (f, v) {
                    case (1, .bytes(let b)): tripID = nonEmpty(b)
                    case (3, .bytes(let b)): startDate = nonEmpty(b)
                    case (4, .varint(let rel)): canceled = rel == 3   // CANCELED
                    case (5, .bytes(let b)): routeID = nonEmpty(b)
                    default: break
                    }
                }
            case (2, .bytes(let stu)):                   // StopTimeUpdate
                var u = ProtobufReader(stu)
                var seq: Int?, stopID: String?, skipped = false
                var arr: (Int?, Int64?) = (nil, nil), dep: (Int?, Int64?) = (nil, nil)
                while let (f, v) = try u.next() {
                    switch (f, v) {
                    case (1, .varint(let n)): seq = Int(n)
                    case (2, .bytes(let b)): arr = try stopTimeEvent(b)
                    case (3, .bytes(let b)): dep = try stopTimeEvent(b)
                    case (4, .bytes(let b)): stopID = nonEmpty(b)
                    case (5, .varint(let rel)): skipped = rel == 1   // SKIPPED
                    default: break
                    }
                }
                stops.append(.init(stopSequence: seq, stopID: stopID, arrivalTime: arr.1, departureTime: dep.1,
                                   arrivalDelay: arr.0, departureDelay: dep.0, skipped: skipped))
            case (3, .bytes(let vd)):                    // VehicleDescriptor
                var d = ProtobufReader(vd)
                while let (f, v) = try d.next() {
                    if f == 1, case .bytes(let b) = v { vehicleID = nonEmpty(b) }
                }
            default: continue
            }
        }
        guard let tripID else { return nil }
        return RealtimeTripUpdate(tripID: tripID, routeID: routeID, startDate: startDate, canceled: canceled,
                                  vehicleID: vehicleID, stopUpdates: stops)
    }

    /// (delay seconds, absolute Unix time). Both are signed int varints on the wire.
    private static func stopTimeEvent(_ bytes: [UInt8]) throws -> (Int?, Int64?) {
        var r = ProtobufReader(bytes)
        var delay: Int?, time: Int64?
        while let (f, v) = try r.next() {
            guard case .varint(let raw) = v else { continue }
            if f == 1 { delay = Int(Int32(truncatingIfNeeded: Int64(bitPattern: raw))) }
            if f == 2 { time = Int64(bitPattern: raw) }
        }
        return (delay, time)
    }

    private static func parseEntity(_ bytes: [UInt8]) throws -> RealtimeVehiclePosition? {
        var reader = ProtobufReader(bytes)
        var entityID: String?
        var vehicle: [UInt8]?
        while let (field, value) = try reader.next() {
            switch (field, value) {
            case (1, .bytes(let b)): entityID = String(decoding: b, as: UTF8.self)
            case (2, .varint(let deleted)) where deleted != 0: return nil   // is_deleted
            case (4, .bytes(let b)): vehicle = b
            default: continue
            }
        }
        guard let vehicle else { return nil }
        return try parseVehiclePosition(vehicle, entityID: entityID)
    }

    private static func parseVehiclePosition(_ bytes: [UInt8], entityID: String?) throws -> RealtimeVehiclePosition? {
        var reader = ProtobufReader(bytes)
        var tripID: String?, routeID: String?
        var lat: Float?, lon: Float?, bearing: Float?
        var timestamp: UInt64?
        var vehicleID: String?, label: String?

        while let (field, value) = try reader.next() {
            switch (field, value) {
            case (1, .bytes(let trip)):                  // TripDescriptor
                var t = ProtobufReader(trip)
                while let (f, v) = try t.next() {
                    if case .bytes(let b) = v {
                        if f == 1 { tripID = nonEmpty(b) }
                        if f == 5 { routeID = nonEmpty(b) }
                    }
                }
            case (2, .bytes(let position)):              // Position
                var p = ProtobufReader(position)
                while let (f, v) = try p.next() {
                    if case .fixed32(let bits) = v {
                        if f == 1 { lat = Float(bitPattern: bits) }
                        if f == 2 { lon = Float(bitPattern: bits) }
                        if f == 3 { bearing = Float(bitPattern: bits) }
                    }
                }
            case (5, .varint(let ts)): timestamp = ts
            case (8, .bytes(let descriptor)):            // VehicleDescriptor
                var d = ProtobufReader(descriptor)
                while let (f, v) = try d.next() {
                    if case .bytes(let b) = v {
                        if f == 1 { vehicleID = nonEmpty(b) }
                        if f == 2 { label = nonEmpty(b) }
                    }
                }
            default: continue
            }
        }

        guard let lat, let lon, let id = vehicleID ?? label ?? entityID else { return nil }
        return RealtimeVehiclePosition(
            vehicleID: id,
            label: label,
            tripID: tripID,
            routeID: routeID,
            latitude: Double(lat),
            longitude: Double(lon),
            bearing: bearing.map(Double.init),
            timestamp: timestamp.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
        )
    }

    private static func nonEmpty(_ bytes: [UInt8]) -> String? {
        let s = String(decoding: bytes, as: UTF8.self)
        return s.isEmpty ? nil : s
    }
}

enum ProtobufError: LocalizedError {
    case truncated
    case unsupportedWireType(Int)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .truncated: return "GTFS-realtime data ended unexpectedly."
        case .unsupportedWireType(let t): return "GTFS-realtime data uses unsupported wire type \(t)."
        case .malformed(let detail): return "GTFS-realtime data is malformed: \(detail)."
        }
    }
}

/// Minimal protobuf wire-format reader: iterates (field number, value) pairs of one message.
struct ProtobufReader {
    enum Value {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes([UInt8])
        case fixed32(UInt32)
    }

    private let bytes: [UInt8]
    private var index = 0

    init(_ data: Data) { self.bytes = [UInt8](data) }
    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func next() throws -> (Int, Value)? {
        guard index < bytes.count else { return nil }
        let key = try readVarint()
        let field = Int(key >> 3)
        switch Int(key & 7) {
        case 0:
            return (field, .varint(try readVarint()))
        case 1:
            return (field, .fixed64(try readLittleEndian(8)))
        case 2:
            let length = try readVarint()
            guard length <= UInt64(bytes.count - index) else { throw ProtobufError.truncated }
            let end = index + Int(length)
            defer { index = end }
            return (field, .bytes(Array(bytes[index..<end])))
        case 5:
            return (field, .fixed32(UInt32(try readLittleEndian(4))))
        case let other:
            throw ProtobufError.unsupportedWireType(other)
        }
    }

    private mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard index < bytes.count else { throw ProtobufError.truncated }
            guard shift < 64 else { throw ProtobufError.malformed("varint too long") }
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte < 0x80 { return result }
            shift += 7
        }
    }

    private mutating func readLittleEndian(_ count: Int) throws -> UInt64 {
        guard bytes.count - index >= count else { throw ProtobufError.truncated }
        var result: UInt64 = 0
        for i in 0..<count { result |= UInt64(bytes[index + i]) << (8 * UInt64(i)) }
        index += count
        return result
    }
}
