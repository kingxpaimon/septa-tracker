import Foundation

/// Fast CSV reader over raw bytes (GTFS files are UTF-8, comma-separated, optionally quoted).
struct CSVReader {
    let bytes: [UInt8]
    let columns: [String: Int]
    private let bodyStart: Int

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        var start = 0
        // Skip a UTF-8 byte-order mark.
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { start = 3 }
        var header: [String] = []
        var end = start
        Self.parseLine(bytes, from: start) { fields, next in
            header = fields.map { String(decoding: bytes[$0], as: UTF8.self).trimmingCharacters(in: .whitespaces) }
            end = next
        }
        // A quoted header field keeps its quotes in the range; strip them.
        self.columns = Dictionary(header.enumerated().map { ($1.trimmingCharacters(in: CharacterSet(charactersIn: "\"")), $0) },
                                  uniquingKeysWith: { a, _ in a })
        self.bodyStart = end
    }

    func column(_ name: String) -> Int? { columns[name] }

    /// Calls `body` once per data row. Rows are only valid during the call.
    func forEachRow(_ body: (Row) throws -> Void) rethrows {
        var position = bodyStart
        while position < bytes.count {
            var row: Row?
            var next = bytes.count
            Self.parseLine(bytes, from: position) { fields, n in
                row = Row(bytes: bytes, fields: fields)
                next = n
            }
            position = next
            if let row, !(row.fields.count == 1 && row.fields[0].isEmpty) {
                try body(row)
            }
        }
    }

    struct Row {
        let bytes: [UInt8]
        let fields: [Range<Int>]

        func string(_ column: Int?) -> String {
            guard let column, column < fields.count else { return "" }
            let r = fields[column]
            guard !r.isEmpty else { return "" }
            if bytes[r.lowerBound] == UInt8(ascii: "\"") {
                // Quoted: strip quotes and un-double embedded quotes.
                let inner = bytes[(r.lowerBound + 1)..<max(r.lowerBound + 1, r.upperBound - 1)]
                return String(decoding: inner, as: UTF8.self).replacingOccurrences(of: "\"\"", with: "\"")
            }
            return String(decoding: bytes[r], as: UTF8.self)
        }

        func int(_ column: Int?) -> Int? {
            guard let column, column < fields.count else { return nil }
            var value = 0, sawDigit = false, negative = false
            for i in fields[column] {
                let b = bytes[i]
                if b >= 48 && b <= 57 { value = value * 10 + Int(b - 48); sawDigit = true }
                else if b == UInt8(ascii: "-") && !sawDigit { negative = true }
                else if b == UInt8(ascii: ".") { break }
                else if b != 32 && b != UInt8(ascii: "\"") { return nil }
            }
            return sawDigit ? (negative ? -value : value) : nil
        }

        func double(_ column: Int?) -> Double? {
            Double(string(column).trimmingCharacters(in: .whitespaces))
        }

        /// GTFS time "H:MM:SS" (hours may exceed 23) → seconds after service-day start.
        func time(_ column: Int?) -> Int32? {
            guard let column, column < fields.count else { return nil }
            var parts = [0, 0, 0], index = 0, sawDigit = false
            for i in fields[column] {
                let b = bytes[i]
                if b >= 48 && b <= 57 { parts[index] = parts[index] * 10 + Int(b - 48); sawDigit = true }
                else if b == UInt8(ascii: ":") { index += 1; if index > 2 { return nil } }
                else if b != 32 && b != UInt8(ascii: "\"") { return nil }
            }
            guard sawDigit, index == 2 else { return nil }
            return Int32(parts[0] * 3600 + parts[1] * 60 + parts[2])
        }
    }

    /// Splits one line starting at `from`; returns field ranges and the start of the next line.
    private static func parseLine(_ b: [UInt8], from: Int, _ result: ([Range<Int>], Int) -> Void) {
        var fields: [Range<Int>] = []
        fields.reserveCapacity(16)
        var i = from
        var fieldStart = from
        var inQuotes = false
        let n = b.count
        while i < n {
            let c = b[i]
            if inQuotes {
                if c == UInt8(ascii: "\"") {
                    if i + 1 < n && b[i + 1] == UInt8(ascii: "\"") { i += 2; continue }
                    inQuotes = false
                }
                i += 1
                continue
            }
            switch c {
            case UInt8(ascii: "\""):
                inQuotes = true
            case UInt8(ascii: ","):
                fields.append(fieldStart..<i)
                fieldStart = i + 1
            case UInt8(ascii: "\n"), UInt8(ascii: "\r"):
                fields.append(fieldStart..<i)
                var next = i + 1
                if c == UInt8(ascii: "\r") && next < n && b[next] == UInt8(ascii: "\n") { next += 1 }
                result(fields, next)
                return
            default:
                break
            }
            i += 1
        }
        fields.append(fieldStart..<n)
        result(fields, n)
    }
}
