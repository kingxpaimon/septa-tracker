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
