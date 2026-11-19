import Foundation
import CoreGraphics
import UIKit

enum PaperTemplate: String, CaseIterable, Identifiable, Codable {
    case blank = "blank"
    case lined = "lined"
    case grid = "grid"
    case dot = "dot"
    case cornell = "cornell"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .blank: return "Blank"
        case .lined: return "Ruled"
        case .grid: return "Grid"
        case .dot: return "Dot Grid"
        case .cornell: return "Cornell"
        }
    }

    func draw(in ctx: CGContext, size: CGSize) {
        let w = size.width
        let h = size.height
        ctx.saveGState()
        ctx.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        ctx.fill(CGRect(origin: .zero, size: size))

        switch self {
        case .blank:
            break

        case .lined:
            ctx.setStrokeColor(red: 0.65, green: 0.78, blue: 0.92, alpha: 1.0)
            ctx.setLineWidth(0.8)
            var y: CGFloat = 68
            while y <= h - 42 {
                ctx.move(to: CGPoint(x: 36, y: y))
                ctx.addLine(to: CGPoint(x: w - 36, y: y))
                y += 28
            }
            ctx.strokePath()
            // Subtle vertical margin rule
            ctx.setStrokeColor(red: 0.94, green: 0.66, blue: 0.66, alpha: 0.75)
            ctx.setLineWidth(0.9)
            ctx.move(to: CGPoint(x: 78, y: 36))
            ctx.addLine(to: CGPoint(x: 78, y: h - 36))
            ctx.strokePath()

        case .grid:
            ctx.setStrokeColor(red: 0.78, green: 0.82, blue: 0.88, alpha: 1.0)
            ctx.setLineWidth(0.65)
            let step: CGFloat = 18.0
            var x: CGFloat = 36
            while x <= w - 36 {
                ctx.move(to: CGPoint(x: x, y: 36))
                ctx.addLine(to: CGPoint(x: x, y: h - 36))
                x += step
            }
            var y: CGFloat = 36
            while y <= h - 36 {
                ctx.move(to: CGPoint(x: 36, y: y))
                ctx.addLine(to: CGPoint(x: w - 36, y: y))
                y += step
            }
            ctx.strokePath()

        case .dot:
            ctx.setFillColor(red: 0.54, green: 0.58, blue: 0.65, alpha: 1.0)
            let step: CGFloat = 18.0
            let r: CGFloat = 1.25
            var x: CGFloat = 36
            while x <= w - 36 {
                var y: CGFloat = 36
                while y <= h - 36 {
                    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                    y += step
                }
                x += step
            }

        case .cornell:
            ctx.setStrokeColor(red: 0.65, green: 0.78, blue: 0.92, alpha: 1.0)
            ctx.setLineWidth(0.75)
            var y: CGFloat = 112
            while y <= h - 155 {
                ctx.move(to: CGPoint(x: 175, y: y))
                ctx.addLine(to: CGPoint(x: w - 36, y: y))
                y += 26
            }
            ctx.strokePath()

            ctx.setStrokeColor(red: 0.89, green: 0.48, blue: 0.48, alpha: 1.0)
            ctx.setLineWidth(1.1)
            ctx.move(to: CGPoint(x: 36, y: 84))
            ctx.addLine(to: CGPoint(x: w - 36, y: 84))
            ctx.move(to: CGPoint(x: 175, y: 84))
            ctx.addLine(to: CGPoint(x: 175, y: h - 140))
            ctx.move(to: CGPoint(x: 36, y: h - 140))
            ctx.addLine(to: CGPoint(x: w - 36, y: h - 140))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }
}

struct BlankPage: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var anchor: Int
    var parent: String?
    var ord: Int
    var w: Double
    var h: Double
    var t: Int64
    var src: Int?
    var pattern: String?
    var kind: String?
    var monday: String?
    var ym: String?
    var title: String?
    var tag: String?
    var noteNum: Int?
    var glossPage: Int?

    init(
        id: String,
        anchor: Int,
        parent: String? = nil,
        ord: Int = 0,
        w: Double = 595,
        h: Double = 842,
        t: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        src: Int? = nil,
        pattern: String? = nil
    ) {
        self.id = id
        self.anchor = anchor
        self.parent = parent
        self.ord = ord
        self.w = w
        self.h = h
        self.t = t
        self.src = src
        self.pattern = pattern
    }

    enum CodingKeys: String, CodingKey {
        case id, anchor, parent, ord, w, h, t, src, pattern, kind, monday, ym, title, tag, noteNum, glossPage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        anchor = (try? c.decode(Int.self, forKey: .anchor)) ?? 0
        parent = try? c.decode(String.self, forKey: .parent)
        ord = (try? c.decode(Int.self, forKey: .ord)) ?? 0
        let rw = (try? c.decode(Double.self, forKey: .w)) ?? 595
        let rh = (try? c.decode(Double.self, forKey: .h)) ?? 842
        w = rw > 0 ? rw : 595
        h = rh > 0 ? rh : 842
        if let ti = try? c.decode(Int64.self, forKey: .t) { t = ti } else if let td = try? c.decode(Double.self, forKey: .t) { t = Int64(td.rounded()) } else { t = 0 }
        src = try? c.decode(Int.self, forKey: .src)
        pattern = try? c.decode(String.self, forKey: .pattern)
        kind = try? c.decode(String.self, forKey: .kind)
        monday = try? c.decode(String.self, forKey: .monday)
        ym = try? c.decode(String.self, forKey: .ym)
        title = try? c.decode(String.self, forKey: .title)
        tag = try? c.decode(String.self, forKey: .tag)
        noteNum = try? c.decode(Int.self, forKey: .noteNum)
        glossPage = try? c.decode(Int.self, forKey: .glossPage)
    }
}

struct PageMark: Codable, Equatable, Sendable {
    var on: Bool
    var t: Int64
    var title: String?
    var tag: String?

    init(on: Bool, t: Int64 = Int64(Date().timeIntervalSince1970 * 1000), title: String? = nil, tag: String? = nil) {
        self.on = on
        self.t = t
        self.title = title
        self.tag = tag
    }

    enum CodingKeys: String, CodingKey {
        case on, t, title, tag
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let b = try? c.decode(Bool.self, forKey: .on) {
            on = b
        } else if let n = try? c.decode(Int.self, forKey: .on) {
            on = n != 0
        } else {
            on = false
        }
        if let ti = try? c.decode(Int64.self, forKey: .t) {
            t = ti
        } else if let td = try? c.decode(Double.self, forKey: .t) {
            t = Int64(td.rounded())
        } else {
            t = 0
        }
        title = try? c.decode(String.self, forKey: .title)
        tag = try? c.decode(String.self, forKey: .tag)
    }
}

struct PageSlot: Identifiable, Equatable {
    let index: Int
    let key: String       // "1" for PDF page 1, or "b:<blankId>" for inserted/duplicated page
    let pdfN: Int?        // 1-based original PDF page
    let srcN: Int?        // 1-based duplicated PDF page source
    let blank: BlankPage?
    let size: CGSize

    var id: String { key }
    var isAddedPage: Bool { blank != nil }
    var effectivePDFPageNumber: Int? { pdfN ?? srcN }
    var template: PaperTemplate {
        PaperTemplate(rawValue: blank?.pattern ?? "blank") ?? .blank
    }
}

struct InkPoint: Equatable {
    var x: CGFloat
    var y: CGFloat
    var p: CGFloat
    var t: Double
}

struct InkStroke: Codable, Identifiable, Equatable, Sendable {
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
    var blanks: [String: BlankPage]
    var bookmarks: [String: PageMark]
    var removed: [String: PageMark]

    enum CodingKeys: String, CodingKey {
        case version, name, pages, deleted, updated, blanks, bookmarks, removed
    }

    init(
        version: Int = 1,
        name: String = "",
        pages: [String: [InkStroke]] = [:],
        deleted: [String: Int64] = [:],
        updated: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        blanks: [String: BlankPage] = [:],
        bookmarks: [String: PageMark] = [:],
        removed: [String: PageMark] = [:]
    ) {
        self.version = version
        self.name = name
        self.pages = pages
        self.deleted = deleted
        self.updated = updated
        self.blanks = blanks
        self.bookmarks = bookmarks
        self.removed = removed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        pages = (try? c.decode([String: [InkStroke]].self, forKey: .pages)) ?? [:]
        deleted = (try? c.decode([String: Int64].self, forKey: .deleted)) ?? [:]
        updated = (try? c.decode(Int64.self, forKey: .updated)) ?? 0
        blanks = (try? c.decode([String: BlankPage].self, forKey: .blanks)) ?? [:]
        bookmarks = (try? c.decode([String: PageMark].self, forKey: .bookmarks)) ?? [:]
        removed = (try? c.decode([String: PageMark].self, forKey: .removed)) ?? [:]
    }

    static func blankKey(_ id: String) -> String { "b:" + id }

    static func empty(name: String) -> InkDocument {
        InkDocument(name: name)
    }

    func isBookmarked(_ key: String) -> Bool {
        bookmarks[key]?.on == true
    }

    func isRemoved(pdfN: Int) -> Bool {
        removed[String(pdfN)]?.on == true
    }

    var removedCount: Int {
        removed.values.filter { $0.on }.count
    }

    /// Exact port of Obsidian Pencil Ink's `layoutBlanks` tree-ordering algorithm.
    mutating func layoutBlanks() {
        guard !blanks.isEmpty else { return }

        // Ensure legacy blanks without parent get chained under their anchor
        var legacyGroups: [Int: [BlankPage]] = [:]
        for b in blanks.values where b.parent == nil {
            let a = max(0, b.anchor)
            legacyGroups[a, default: []].append(b)
        }
        for (anchor, var grp) in legacyGroups {
            grp.sort {
                if $0.ord != $1.ord { return $0.ord < $1.ord }
                if $0.t != $1.t { return $0.t < $1.t }
                return $0.id < $1.id
            }
            var prev = anchor == 0 ? "0" : String(anchor)
            for var b in grp {
                b.anchor = anchor
                b.parent = prev
                blanks[b.id] = b
                prev = InkDocument.blankKey(b.id)
            }
        }

        let ids = Set(blanks.keys)
        let rootOf: (Int) -> String = { $0 <= 0 ? "0" : String($0) }
        var kids: [String: [BlankPage]] = [:]
        for b in blanks.values {
            let par = b.parent ?? rootOf(b.anchor)
            let orphan = par.hasPrefix("b:") && !ids.contains(String(par.dropFirst(2)))
            let key = orphan ? rootOf(b.anchor) : par
            kids[key, default: []].append(b)
        }

        for key in kids.keys {
            kids[key]?.sort { x, y in
                let xHobo = (x.kind ?? "").hasPrefix("hobo-")
                let yHobo = (y.kind ?? "").hasPrefix("hobo-")
                if xHobo && yHobo {
                    return x.t != y.t ? x.t < y.t : x.id < y.id
                }
                return x.t != y.t ? x.t > y.t : x.id > y.id
            }
        }

        var visited = Set<String>()
        var roots = Set<String>(["0"])
        for b in blanks.values { roots.insert(rootOf(b.anchor)) }

        for r in roots {
            let anchor = (r == "0") ? 0 : (Int(r) ?? 0)
            var seq = 0
            var stack: [(list: [BlankPage], idx: Int)] = [(kids[r] ?? [], 0)]
            while !stack.isEmpty {
                let topIdx = stack.count - 1
                if stack[topIdx].idx >= stack[topIdx].list.count {
                    stack.removeLast()
                    continue
                }
                let b = stack[topIdx].list[stack[topIdx].idx]
                stack[topIdx].idx += 1
                if visited.contains(b.id) { continue }
                visited.insert(b.id)
                if var stored = blanks[b.id] {
                    stored.anchor = anchor
                    stored.ord = seq
                    blanks[b.id] = stored
                    seq += 1
                }
                if let childList = kids[InkDocument.blankKey(b.id)], !childList.isEmpty {
                    stack.append((childList, 0))
                }
            }
        }
    }

    static func placeBlankTree(after slot: PageSlot?) -> (parent: String, anchor: Int, t: Int64) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        guard let slot = slot else { return ("0", 0, now) }
        if let blank = slot.blank {
            return (blankKey(blank.id), blank.anchor, now)
        }
        let n = slot.pdfN ?? 0
        return (n <= 0 ? "0" : String(n), max(0, n), now)
    }

    /// Builds the ordered list of visible page slots (original non-removed PDF pages + interleaved blank/duplicated pages).
    mutating func buildPageSlots(pdfPageSizes: [CGSize], defaultSize: CGSize = CGSize(width: 595, height: 842)) -> [PageSlot] {
        layoutBlanks()
        let numPages = pdfPageSizes.count
        var groups: [Int: [BlankPage]] = [:]
        for b in blanks.values {
            let a = max(0, min(numPages, b.anchor))
            groups[a, default: []].append(b)
        }
        for k in groups.keys {
            groups[k]?.sort { $0.ord != $1.ord ? $0.ord < $1.ord : $0.id < $1.id }
        }

        var out: [PageSlot] = []
        func appendBlanks(for anchor: Int) {
            for b in groups[anchor] ?? [] {
                let sz = CGSize(width: b.w > 0 ? b.w : Double(defaultSize.width), height: b.h > 0 ? b.h : Double(defaultSize.height))
                out.append(PageSlot(
                    index: out.count,
                    key: InkDocument.blankKey(b.id),
                    pdfN: nil,
                    srcN: b.src,
                    blank: b,
                    size: sz
                ))
            }
        }

        appendBlanks(for: 0)
        if numPages > 0 {
            for n in 1...numPages {
                if !isRemoved(pdfN: n) {
                    let sz = pdfPageSizes[n - 1]
                    out.append(PageSlot(
                        index: out.count,
                        key: String(n),
                        pdfN: n,
                        srcN: nil,
                        blank: nil,
                        size: sz
                    ))
                }
                appendBlanks(for: n)
            }
        }
        return out
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
