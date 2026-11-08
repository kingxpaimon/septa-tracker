import Foundation

/// Google's encoded polyline format (also used by Transitous/MOTIS with precision 7).
/// https://developers.google.com/maps/documentation/utilities/polylinealgorithm
enum Polyline {
    static func decode(_ encoded: String, precision: Int = 5) -> [GeoPoint] {
        let factor = pow(10.0, Double(precision))
        let bytes = Array(encoded.utf8)
        var points: [GeoPoint] = []
        var index = 0
        var lat = 0, lon = 0

        func next() -> Int? {
            var result = 0, shift = 0
            while index < bytes.count {
                let b = Int(bytes[index]) - 63
                index += 1
                result |= (b & 0x1F) << shift
                shift += 5
                if b < 0x20 { return (result & 1) != 0 ? ~(result >> 1) : (result >> 1) }
            }
            return nil   // truncated
        }

        while index < bytes.count {
            guard let dLat = next(), let dLon = next() else { break }
            lat += dLat
            lon += dLon
            points.append(GeoPoint(latitude: Double(lat) / factor, longitude: Double(lon) / factor))
        }
        return points
    }
}
