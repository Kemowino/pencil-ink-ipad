import Foundation
import Compression
import CryptoKit

/// Exact wire-format codec matching Obsidian Pencil Ink (`src/wire.ts` & `src/logs.ts`):
/// - Base36 delta-encoded flat `[x, y, p]` stroke points
/// - Standard RFC 1952 gzip compression/decompression with dual Foundation + Compression fallback
/// - Defensive JSON decoders so remote shards from Obsidian Mac/Windows/iOS NEVER silently fail
enum WireCodec {
    // MARK: - Base36 Delta Point Codec (Matches `src/wire.ts`)

    static func encodePts(_ pts: [Double]) -> String {
        var px = 0
        var py = 0
        var pz = 0
        var out: [String] = []
        out.reserveCapacity(pts.count)
        var i = 0
        while i + 2 < pts.count {
            let fx = pts[i], fy = pts[i + 1], fz = pts[i + 2]
            if fx.isFinite && fy.isFinite && fz.isFinite {
                let x = Int((fx * 100.0).rounded())
                let y = Int((fy * 100.0).rounded())
                let z = Int((fz * 100.0).rounded())
                out.append(String(x - px, radix: 36))
                out.append(String(y - py, radix: 36))
                out.append(String(z - pz, radix: 36))
                px = x
                py = y
                pz = z
            }
            i += 3
        }
        return out.joined(separator: " ")
    }

    static func decodePts(_ text: String) -> [Double]? {
        if text.isEmpty { return [] }
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count % 3 == 0 else { return nil }
        var out: [Double] = []
        out.reserveCapacity(tokens.count)
        var px = 0, py = 0, pz = 0
        var i = 0
        while i + 2 < tokens.count {
            guard let dx = Int(tokens[i], radix: 36),
                  let dy = Int(tokens[i + 1], radix: 36),
                  let dz = Int(tokens[i + 2], radix: 36) else {
                return nil
            }
            px += dx
            py += dy
            pz += dz
            out.append(Double(px) / 100.0)
            out.append(Double(py) / 100.0)
            out.append(Double(pz) / 100.0)
            i += 3
        }
        return out
    }

    // MARK: - Defensive Compact Stroke & Log Shard Structs

    struct CompactStroke: Codable {
        var id: String
        var t: Int64
        var tool: String
        var style: String?
        var color: String
        var size: Double
        var d: String
        var bs: Int?
        var sh: String?
        var st: Int?

        init(from stroke: InkStroke) {
            self.id = stroke.id
            self.t = stroke.t
            self.tool = stroke.tool
            self.style = stroke.style
            self.color = stroke.color
            self.size = stroke.size
            self.d = WireCodec.encodePts(stroke.pts)
            self.bs = (stroke._bakedSmooth == true) ? 1 : nil
            self.sh = stroke._smartShape
            self.st = (stroke.straight == true) ? 1 : nil
        }

        enum CodingKeys: String, CodingKey {
            case id, t, tool, style, color, size, d, bs, sh, st
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            if let ti = try? c.decode(Int64.self, forKey: .t) {
                t = ti
            } else if let td = try? c.decode(Double.self, forKey: .t) {
                t = Int64(td.rounded())
            } else {
                t = 0
            }
            tool = (try? c.decode(String.self, forKey: .tool)) ?? "pen"
            style = try? c.decode(String.self, forKey: .style)
            color = (try? c.decode(String.self, forKey: .color)) ?? "#1c1c1e"
            size = (try? c.decode(Double.self, forKey: .size)) ?? 2.4
            d = (try? c.decode(String.self, forKey: .d)) ?? ""
            if let v = try? c.decode(Int.self, forKey: .bs) { bs = v }
            else if let b = try? c.decode(Bool.self, forKey: .bs) { bs = b ? 1 : 0 }
            else { bs = nil }
            sh = try? c.decode(String.self, forKey: .sh)
            if let v = try? c.decode(Int.self, forKey: .st) { st = v }
            else if let b = try? c.decode(Bool.self, forKey: .st) { st = b ? 1 : 0 }
            else { st = nil }
        }

        func expand() -> InkStroke? {
            guard let pts = WireCodec.decodePts(d) else { return nil }
            return InkStroke(
                id: id,
                t: t,
                tool: tool,
                style: style,
                color: color,
                size: size,
                pts: pts,
                straight: (st == 1) ? true : nil,
                _bakedSmooth: (bs == 1) ? true : nil,
                _smoothLevel: nil,
                _sens: nil,
                _smartShape: sh
            )
        }
    }

    struct PageShardPayload: Codable {
        var v: Int
        var key: String
        var s: [CompactStroke]
    }

    struct EraseLogPayload: Codable {
        var v: Int
        var erased: [String: Int64]

        init(v: Int = 1, erased: [String: Int64]) {
            self.v = v
            self.erased = erased
        }

        enum CodingKeys: String, CodingKey { case v, erased }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            v = (try? c.decode(Int.self, forKey: .v)) ?? 1
            if let map = try? c.decode([String: Int64].self, forKey: .erased) {
                erased = map
            } else if let dmap = try? c.decode([String: Double].self, forKey: .erased) {
                erased = dmap.mapValues { Int64($0.rounded()) }
            } else {
                erased = [:]
            }
        }
    }

    struct BlanksLogPayload: Codable {
        var v: Int
        var blanks: [BlankPage]

        init(v: Int = 1, blanks: [BlankPage]) {
            self.v = v
            self.blanks = blanks
        }

        enum CodingKeys: String, CodingKey { case v, blanks }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            v = (try? c.decode(Int.self, forKey: .v)) ?? 1
            blanks = (try? c.decode([BlankPage].self, forKey: .blanks)) ?? []
        }
    }

    struct MarksLogPayload: Codable {
        var v: Int
        var bookmarks: [String: PageMark]
        var removed: [String: PageMark]

        init(v: Int = 1, bookmarks: [String: PageMark], removed: [String: PageMark]) {
            self.v = v
            self.bookmarks = bookmarks
            self.removed = removed
        }

        enum CodingKeys: String, CodingKey { case v, bookmarks, removed }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            v = (try? c.decode(Int.self, forKey: .v)) ?? 1
            bookmarks = (try? c.decode([String: PageMark].self, forKey: .bookmarks)) ?? [:]
            removed = (try? c.decode([String: PageMark].self, forKey: .removed)) ?? [:]
        }
    }

    static func encodePageShard(key: String, strokes: [InkStroke]) throws -> Data {
        let payload = PageShardPayload(v: 1, key: key, s: strokes.map { CompactStroke(from: $0) })
        let raw = try JSONEncoder().encode(payload)
        return try gzipCompress(raw)
    }

    static func decodePageShard(_ data: Data) -> (key: String, strokes: [InkStroke])? {
        guard !data.isEmpty else { return nil }
        let raw: Data
        if isGzip(data) {
            guard let unzipped = try? gzipDecompress(data) else { return nil }
            raw = unzipped
        } else {
            raw = data
        }
        guard let payload = try? JSONDecoder().decode(PageShardPayload.self, from: raw),
              payload.v == 1 else {
            return nil
        }
        var strokes: [InkStroke] = []
        strokes.reserveCapacity(payload.s.count)
        for cs in payload.s {
            if let st = cs.expand() {
                strokes.append(st)
            }
        }
        return (payload.key, strokes)
    }

    // MARK: - MD5 Helper

    static func md5Hex(_ data: Data) -> String {
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - RFC 1952 Gzip (Header/Trailer + Dual Foundation/Compression Raw DEFLATE)

    private static let crc32Table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let idx = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = crc32Table[idx] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    static func isGzip(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1F && data[data.index(after: data.startIndex)] == 0x8B
    }

    static func gzipCompress(_ data: Data) throws -> Data {
        let deflated: Data
        if data.isEmpty {
            deflated = Data([0x03, 0x00])
        } else {
            deflated = try (data as NSData).compressed(using: .zlib) as Data
        }
        var out = Data(capacity: 10 + deflated.count + 8)
        out.append(contentsOf: [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03])
        out.append(deflated)
        var crcLE = crc32(data).littleEndian
        var sizeLE = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &crcLE) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &sizeLE) { out.append(contentsOf: $0) }
        return out
    }

    static func gzipDecompress(_ data: Data) throws -> Data {
        guard data.count >= 18 else { return data }
        let bytes = [UInt8](data)
        guard bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 0x08 else {
            return data
        }
        let flg = bytes[3]
        var offset = 10
        if (flg & 0x04) != 0 {
            guard offset + 2 <= bytes.count else { throw NSError(domain: "WireCodec", code: 1) }
            let xlen = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            offset += 2 + xlen
        }
        if (flg & 0x08) != 0 {
            while offset < bytes.count && bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if (flg & 0x10) != 0 {
            while offset < bytes.count && bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if (flg & 0x02) != 0 {
            offset += 2
        }
        guard offset <= bytes.count - 8 else {
            throw NSError(domain: "WireCodec", code: 2)
        }
        let payload = Data(bytes[offset..<(bytes.count - 8)])
        if payload.count == 2 && payload[0] == 0x03 && payload[1] == 0x00 {
            return Data()
        }
        if let fast = try? (payload as NSData).decompressed(using: .zlib) as Data {
            return fast
        }
        // Fallback via Compression streaming decoder (handles arbitrary expansion ratios & Chromium gzip streams)
        return try streamInflateRawDeflate(payload)
    }

    private static func streamInflateRawDeflate(_ payload: Data) throws -> Data {
        var output = Data()
        let filter = try OutputFilter(.decompress, using: .zlib) { chunk in
            if let chunk = chunk { output.append(chunk) }
        }
        let pageSize = 32_768
        var idx = 0
        while idx < payload.count {
            let end = min(payload.count, idx + pageSize)
            try filter.write(payload.subdata(in: idx..<end))
            idx = end
        }
        try filter.finalize()
        return output
    }
}
