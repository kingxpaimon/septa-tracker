import Foundation

enum ZipError: LocalizedError {
    case notAZip
    case truncated
    case unsupported(String)
    case corrupt(String)
    case missingEntry(String)

    var errorDescription: String? {
        switch self {
        case .notAZip: return "The schedule download isn't a zip file."
        case .truncated: return "The schedule download is incomplete."
        case .unsupported(let d): return "The schedule zip uses an unsupported feature: \(d)."
        case .corrupt(let d): return "The schedule zip is corrupt: \(d)."
        case .missingEntry(let n): return "The schedule zip has no \(n)."
        }
    }
}

/// Minimal read-only zip reader: stored and deflated entries, no encryption, no ZIP64.
/// Enough for SEPTA's GTFS bundle. iOS has no public zip API, and this avoids a dependency.
struct ZipArchive {
    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    let bytes: [UInt8]
    let entries: [Entry]

    init(_ data: Data) throws { try self.init(bytes: [UInt8](data)) }

    init(bytes: [UInt8]) throws {
        self.bytes = bytes
        // End of central directory: signature 0x06054b50, within the last 64 KiB + 22 bytes.
        guard bytes.count >= 22 else { throw ZipError.notAZip }
        var eocd: Int?
        var i = bytes.count - 22
        let floor = max(0, bytes.count - 22 - 65_535)
        while i >= floor {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard let eocd else { throw ZipError.notAZip }
        let count = Int(Self.u16(bytes, eocd + 10))
        let directoryOffset = Int(Self.u32(bytes, eocd + 16))
        guard directoryOffset != 0xFFFF_FFFF else { throw ZipError.unsupported("ZIP64") }

        var entries: [Entry] = []
        var p = directoryOffset
        for _ in 0..<count {
            guard p + 46 <= bytes.count, Self.u32(bytes, p) == 0x0201_4B50 else { throw ZipError.corrupt("central directory") }
            let flags = Self.u16(bytes, p + 8)
            guard flags & 1 == 0 else { throw ZipError.unsupported("encryption") }
            let nameLength = Int(Self.u16(bytes, p + 28))
            let extraLength = Int(Self.u16(bytes, p + 30))
            let commentLength = Int(Self.u16(bytes, p + 32))
            guard p + 46 + nameLength <= bytes.count else { throw ZipError.truncated }
            entries.append(Entry(
                name: String(decoding: bytes[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self),
                method: Self.u16(bytes, p + 10),
                compressedSize: Int(Self.u32(bytes, p + 20)),
                uncompressedSize: Int(Self.u32(bytes, p + 24)),
                localHeaderOffset: Int(Self.u32(bytes, p + 42))
            ))
            p += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    /// The entry whose file name (ignoring folders) is `name`.
    func entry(named name: String) -> Entry? {
        entries.first { $0.name == name || $0.name.hasSuffix("/" + name) }
    }

    func contents(of name: String) throws -> [UInt8] {
        guard let entry = entry(named: name) else { throw ZipError.missingEntry(name) }
        return try contents(of: entry)
    }

    func contents(of entry: Entry) throws -> [UInt8] {
        let h = entry.localHeaderOffset
        guard h + 30 <= bytes.count, Self.u32(bytes, h) == 0x0403_4B50 else { throw ZipError.corrupt("local header for \(entry.name)") }
        let start = h + 30 + Int(Self.u16(bytes, h + 26)) + Int(Self.u16(bytes, h + 28))
        let end = start + entry.compressedSize
        guard end <= bytes.count else { throw ZipError.truncated }
        switch entry.method {
        case 0:
            return Array(bytes[start..<end])
        case 8:
            let out = try Inflate.decompress(bytes, range: start..<end, expectedSize: entry.uncompressedSize)
            guard out.count == entry.uncompressedSize else { throw ZipError.corrupt("size mismatch for \(entry.name)") }
            return out
        default:
            throw ZipError.unsupported("compression method \(entry.method)")
        }
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}

/// Raw DEFLATE (RFC 1951) decoder.
enum Inflate {
    private static let lengthBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distBase: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    private static let distExtra: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    private static let codeLengthOrder: [Int] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    static func decompress(_ input: [UInt8], range: Range<Int>? = nil, expectedSize: Int? = nil) throws -> [UInt8] {
        let r = range ?? 0..<input.count
        var out: [UInt8] = []
        out.reserveCapacity(expectedSize ?? r.count * 4)
        try input.withUnsafeBufferPointer { buffer in
            var reader = BitReader(buffer: buffer, position: r.lowerBound, end: r.upperBound)
            try run(&reader, &out)
        }
        return out
    }

    private static func run(_ reader: inout BitReader, _ out: inout [UInt8]) throws {
        let fixedLit = Huffman(lengths: (0..<288).map { $0 < 144 ? 8 : $0 < 256 ? 9 : $0 < 280 ? 7 : 8 })
        let fixedDist = Huffman(lengths: Array(repeating: 5, count: 30))
        var last = false
        repeat {
            last = try reader.bits(1) == 1
            switch try reader.bits(2) {
            case 0:
                reader.alignToByte()
                let len = try reader.bits(16)
                let nlen = try reader.bits(16)
                guard len == (~nlen & 0xFFFF) else { throw ZipError.corrupt("stored block length") }
                try reader.copyBytes(len, into: &out)
            case 1:
                try inflateBlock(&reader, &out, fixedLit, fixedDist)
            case 2:
                let (lit, dist) = try dynamicTables(&reader)
                try inflateBlock(&reader, &out, lit, dist)
            default:
                throw ZipError.corrupt("block type 3")
            }
        } while !last
    }

    private static func dynamicTables(_ reader: inout BitReader) throws -> (Huffman, Huffman) {
        let hlit = try reader.bits(5) + 257
        let hdist = try reader.bits(5) + 1
        let hclen = try reader.bits(4) + 4
        var clLengths = [Int](repeating: 0, count: 19)
        for i in 0..<hclen { clLengths[codeLengthOrder[i]] = try reader.bits(3) }
        let clCode = Huffman(lengths: clLengths)

        var lengths: [Int] = []
        lengths.reserveCapacity(hlit + hdist)
        while lengths.count < hlit + hdist {
            let sym = try clCode.decode(&reader)
            switch sym {
            case 0...15: lengths.append(sym)
            case 16:
                guard let prev = lengths.last else { throw ZipError.corrupt("repeat with no previous length") }
                lengths.append(contentsOf: repeatElement(prev, count: 3 + (try reader.bits(2))))
            case 17: lengths.append(contentsOf: repeatElement(0, count: 3 + (try reader.bits(3))))
            default: lengths.append(contentsOf: repeatElement(0, count: 11 + (try reader.bits(7))))
            }
        }
        guard lengths.count == hlit + hdist else { throw ZipError.corrupt("code lengths overflow") }
        return (Huffman(lengths: Array(lengths[0..<hlit])), Huffman(lengths: Array(lengths[hlit...])))
    }

    private static func inflateBlock(_ reader: inout BitReader, _ out: inout [UInt8], _ lit: Huffman, _ dist: Huffman) throws {
        while true {
            let sym = try lit.decode(&reader)
            if sym < 256 {
                out.append(UInt8(sym))
            } else if sym == 256 {
                return
            } else {
                let li = sym - 257
                guard li < 29 else { throw ZipError.corrupt("length symbol") }
                let length = lengthBase[li] + (try reader.bits(lengthExtra[li]))
                let di = try dist.decode(&reader)
                guard di < 30 else { throw ZipError.corrupt("distance symbol") }
                let distance = distBase[di] + (try reader.bits(distExtra[di]))
                guard distance <= out.count else { throw ZipError.corrupt("distance too far back") }
                var from = out.count - distance
                for _ in 0..<length {
                    out.append(out[from])
                    from += 1
                }
            }
        }
    }

    /// Canonical Huffman decoder with a 9-bit lookup table and a bit-by-bit fallback.
    private struct Huffman {
        static let fastBits = 9
        /// Indexed by the next `fastBits` stream bits: (symbol << 4) | length, or -1 for "longer code".
        var fast = [Int32](repeating: -1, count: 1 << fastBits)
        var counts = [Int](repeating: 0, count: 16)
        var symbols: [Int] = []

        init(lengths: [Int]) {
            for l in lengths { counts[l] += 1 }
            counts[0] = 0
            var offsets = [Int](repeating: 0, count: 16)
            for l in 1..<16 { offsets[l] = offsets[l - 1] + counts[l - 1] }
            symbols = [Int](repeating: 0, count: lengths.count)
            for (sym, l) in lengths.enumerated() where l != 0 {
                symbols[offsets[l]] = sym
                offsets[l] += 1
            }
            // Assign canonical codes and fill the fast table (codes are stored bit-reversed in the stream).
            var code = 0
            var next = [Int](repeating: 0, count: 16)
            for l in 1..<16 {
                code = (code + counts[l - 1]) << 1
                next[l] = code
            }
            for (sym, l) in lengths.enumerated() where l != 0 && l <= Self.fastBits {
                let c = next[l]
                next[l] += 1
                var reversed = 0
                for b in 0..<l where c & (1 << b) != 0 { reversed |= 1 << (l - 1 - b) }
                var index = reversed
                while index < (1 << Self.fastBits) {
                    fast[index] = Int32(sym << 4 | l)
                    index += 1 << l
                }
            }
        }

        func decode(_ reader: inout BitReader) throws -> Int {
            let entry = fast[reader.peek(Self.fastBits)]
            if entry >= 0 {
                try reader.consume(Int(entry & 15))
                return Int(entry >> 4)
            }
            // Slow path (puff-style): codes longer than fastBits.
            var code = 0, first = 0, index = 0
            for len in 1..<16 {
                code |= try reader.bits(1)
                let count = counts[len]
                if code - count < first { return symbols[index + (code - first)] }
                index += count
                first = (first + count) << 1
                code <<= 1
            }
            throw ZipError.corrupt("bad Huffman code")
        }
    }

    private struct BitReader {
        let buffer: UnsafeBufferPointer<UInt8>
        var position: Int
        let end: Int
        var bitBuffer: UInt64 = 0
        var bitCount = 0

        init(buffer: UnsafeBufferPointer<UInt8>, position: Int, end: Int) {
            self.buffer = buffer
            self.position = position
            self.end = end
        }

        mutating func refill() {
            while bitCount <= 56 && position < end {
                bitBuffer |= UInt64(buffer[position]) << UInt64(bitCount)
                position += 1
                bitCount += 8
            }
        }

        /// Next `n` bits without consuming; zero-padded past the end of input.
        mutating func peek(_ n: Int) -> Int {
            if bitCount < n { refill() }
            return Int(bitBuffer & ((1 << UInt64(n)) - 1))
        }

        mutating func consume(_ n: Int) throws {
            if bitCount < n { refill() }
            guard bitCount >= n else { throw ZipError.truncated }
            bitBuffer >>= UInt64(n)
            bitCount -= n
        }

        mutating func bits(_ n: Int) throws -> Int {
            if n == 0 { return 0 }
            let v = peek(n)
            try consume(n)
            return v
        }

        mutating func alignToByte() {
            let drop = bitCount % 8
            bitBuffer >>= UInt64(drop)
            bitCount -= drop
        }

        mutating func copyBytes(_ n: Int, into out: inout [UInt8]) throws {
            // Drain whole bytes still in the bit buffer first.
            var remaining = n
            while remaining > 0 && bitCount >= 8 {
                out.append(UInt8(bitBuffer & 0xFF))
                bitBuffer >>= 8
                bitCount -= 8
                remaining -= 1
            }
            guard position + remaining <= end else { throw ZipError.truncated }
            out.append(contentsOf: buffer[position..<(position + remaining)])
            position += remaining
        }
    }
}
