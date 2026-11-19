import Foundation
import CoreGraphics
import UIKit

/// Lossless JSON wrapper so unknown Obsidian Pencil Ink fields (blanks, bookmarks, Hobonichi metadata, etc.)
/// are preserved untouched whenever the iPad app saves `.ink.json`.
enum AnyCodable: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([AnyCodable])
    case object([String: AnyCodable])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Int64.self) {
            self = .int(v)
        } else if let v = try? container.decode(Double.self) {
            self = .double(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode([AnyCodable].self) {
            self = .array(v)
        } else if let v = try? container.decode([String: AnyCodable].self) {
            self = .object(v)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let v):
            try container.encode(v)
        case .int(let v):
            try container.encode(v)
        case .double(let v):
            try container.encode(v)
        case .string(let v):
            try container.encode(v)
        case .array(let v):
            try container.encode(v)
        case .object(let v):
            try container.encode(v)
        }
    }
}

struct InkPoint: Equatable {
    var x: CGFloat
    var y: CGFloat
    var p: CGFloat
    var t: Double
}

struct InkStroke: Codable, Identifiable, Equatable {
    var id: String
    var t: Int64
    var tool: String          // "pen" | "highlighter"
    var style: String?        // "ball" | "fountain" | "brush"
    var color: String         // "#rrggbb"
    var size: Double
    var pts: [Double]         // Flat [x0, y0, p0, x1, y1, p1, ...] in PDF points (top-left origin)
    var straight: Bool?
    var _bakedSmooth: Bool?
    var _smoothLevel: Int?
    var _sens: Double?
    var _smartShape: String?

    var pointCount: Int { pts.count / 3 }

    func boundingBox() -> CGRect {
        let n = pts.count / 3
        guard n > 0 else { return .zero }
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for i in 0..<n {
            let x = CGFloat(pts[i * 3])
            let y = CGFloat(pts[i * 3 + 1])
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    static func newID() -> String {
        let ts = String(Int64(Date().timeIntervalSince1970 * 1000), radix: 36)
        let rand = String(UInt32.random(in: 0..<UInt32.max), radix: 36).prefix(6)
        return "\(ts)-\(rand)"
    }
}

struct InkDocument: Codable {
    var version: Int
    var name: String
    var pages: [String: [InkStroke]]
    var deleted: [String: Int64]
    var updated: Int64
    var blanks: [String: AnyCodable]?
    var bookmarks: [String: AnyCodable]?
    var removed: [String: AnyCodable]?

    static func empty(name: String) -> InkDocument {
        InkDocument(
            version: 1,
            name: name,
            pages: [:],
            deleted: [:],
            updated: Int64(Date().timeIntervalSince1970 * 1000),
            blanks: [:],
            bookmarks: [:],
            removed: [:]
        )
    }

    static func sidecarURL(for pdfURL: URL) -> URL {
        URL(fileURLWithPath: pdfURL.path + ".ink.json")
    }

    static func load(for pdfURL: URL) -> InkDocument {
        let url = sidecarURL(for: pdfURL)
        var loadedData: Data?
        var coordError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { coordURL in
            if FileManager.default.fileExists(atPath: coordURL.path) {
                loadedData = try? Data(contentsOf: coordURL)
            }
        }
        if loadedData == nil, FileManager.default.fileExists(atPath: url.path) {
            loadedData = try? Data(contentsOf: url)
        }
        guard let data = loadedData,
              let decoded = try? JSONDecoder().decode(InkDocument.self, from: data) else {
            return .empty(name: pdfURL.lastPathComponent)
        }
        return decoded
    }

    func save(for pdfURL: URL) throws {
        var copy = self
        copy.updated = Int64(Date().timeIntervalSince1970 * 1000)
        let encoder = JSONEncoder()
        let data = try encoder.encode(copy)
        let url = InkDocument.sidecarURL(for: pdfURL)
        var coordError: NSError?
        var writeError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { coordURL in
            do {
                try data.write(to: coordURL, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let err = writeError ?? coordError {
            throw err
        }
    }
}

extension UIColor {
    convenience init(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        var rgb: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&rgb)
        if cleaned.count == 6 {
            self.init(
                red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
                green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
                blue: CGFloat(rgb & 0xFF) / 255.0,
                alpha: 1.0
            )
        } else {
            self.init(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)
        }
    }

    func toHexString() -> String {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        if getRed(&r, green: &g, blue: &b, alpha: &a) {
            return String(
                format: "#%02x%02x%02x",
                Int(round(max(0, min(1, r)) * 255)),
                Int(round(max(0, min(1, g)) * 255)),
                Int(round(max(0, min(1, b)) * 255))
            )
        }
        return "#1c1c1e"
    }
}
