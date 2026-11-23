import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct CoverPalette: Identifiable, Equatable {
    let id: Int
    let name: String
    let bgHex: String
    let spineHex: String
    let isHobonichi: Bool

    var bgColor: PlatformColor { PlatformColor(hex: bgHex) }
    var spineColor: PlatformColor { PlatformColor(hex: spineHex) }
}

enum HobonichiEngine {
    static let pageWidth: CGFloat = 1190
    static let pageHeight: CGFloat = 842
    static let pageSize = CGSize(width: 1190, height: 842)

    static let creamColor = PlatformColor(red: 0.984, green: 0.973, blue: 0.937, alpha: 1.0)
    static let creamDark = PlatformColor(red: 0.953, green: 0.937, blue: 0.886, alpha: 1.0)
    static let gridColor = PlatformColor(red: 0.541, green: 0.510, blue: 0.447, alpha: 0.24)
    static let gridStrong = PlatformColor(red: 0.471, green: 0.439, blue: 0.384, alpha: 0.44)
    static let inkColor = PlatformColor(red: 0.173, green: 0.165, blue: 0.157, alpha: 1.0)
    static let mutedColor = PlatformColor(red: 0.471, green: 0.447, blue: 0.408, alpha: 1.0)
    static let redColor = PlatformColor(red: 0.784, green: 0.294, blue: 0.192, alpha: 1.0)
    static let blueColor = PlatformColor(red: 0.290, green: 0.420, blue: 0.510, alpha: 1.0)

    static let monthsFull = ["JANUARY", "FEBRUARY", "MARCH", "APRIL", "MAY", "JUNE", "JULY", "AUGUST", "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER"]
    static let monthsShort = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    static let days = ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"]
    static let daysMini = ["M", "T", "W", "T", "F", "S", "S"]

    static let notebookPalettes: [CoverPalette] = [
        CoverPalette(id: 0, name: "Deep Navy", bgHex: "#1d3557", spineHex: "#13233a", isHobonichi: false),
        CoverPalette(id: 1, name: "Emerald Sage", bgHex: "#2a7f62", spineHex: "#1b5440", isHobonichi: false),
        CoverPalette(id: 2, name: "Terracotta", bgHex: "#c85a48", spineHex: "#8e3c2f", isHobonichi: false),
        CoverPalette(id: 3, name: "Ochre Gold", bgHex: "#c28b2c", spineHex: "#8a611c", isHobonichi: false),
        CoverPalette(id: 4, name: "Royal Plum", bgHex: "#64447c", spineHex: "#432c54", isHobonichi: false),
        CoverPalette(id: 5, name: "Slate Graphite", bgHex: "#374151", spineHex: "#1f2937", isHobonichi: false),
        CoverPalette(id: 6, name: "Coastal Ocean", bgHex: "#1e607a", spineHex: "#123d4e", isHobonichi: false)
    ]

    static let hoboPalettes: [CoverPalette] = [
        CoverPalette(id: 100, name: "Bow & Tie Forest", bgHex: "#1e3a2f", spineHex: "#12241d", isHobonichi: true),
        CoverPalette(id: 101, name: "Strawberry Milk", bgHex: "#d88c9a", spineHex: "#b56576", isHobonichi: true),
        CoverPalette(id: 102, name: "Champagne Gold", bgHex: "#c5a880", spineHex: "#9c7e54", isHobonichi: true),
        CoverPalette(id: 103, name: "Classic Navy", bgHex: "#1c2841", spineHex: "#101829", isHobonichi: true),
        CoverPalette(id: 104, name: "Vermilion Red", bgHex: "#b83b2b", spineHex: "#872619", isHobonichi: true),
        CoverPalette(id: 105, name: "Charcoal Slate", bgHex: "#2f3237", spineHex: "#1c1e22", isHobonichi: true)
    ]

    static func palette(for name: String, customID: Int?) -> CoverPalette {
        if let cid = customID {
            if let hp = hoboPalettes.first(where: { $0.id == cid }) { return hp }
            if let np = notebookPalettes.first(where: { $0.id == cid }) { return np }
        }
        var hash: Int = 0
        for u in name.unicodeScalars {
            hash = (hash &* 31 &+ Int(u.value)) & 0x7FFFFFFF
        }
        return notebookPalettes[abs(hash) % notebookPalettes.count]
    }

    // MARK: - Date Helpers

    static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2 // Monday
        return cal
    }()

    private static let isoCalendar: Calendar = {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone
        return iso
    }()

    private static let spineGradient: CGGradient? = {
        let colors = [
            PlatformColor(red: 0.47, green: 0.43, blue: 0.37, alpha: 0.0).cgColor,
            PlatformColor(red: 0.43, green: 0.39, blue: 0.33, alpha: 0.07).cgColor,
            PlatformColor(red: 0.29, green: 0.27, blue: 0.22, alpha: 0.18).cgColor,
            PlatformColor(red: 0.43, green: 0.39, blue: 0.33, alpha: 0.07).cgColor,
            PlatformColor(red: 0.47, green: 0.43, blue: 0.37, alpha: 0.0).cgColor
        ] as CFArray
        let locs: [CGFloat] = [0.0, 0.42, 0.5, 0.58, 1.0]
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGGradient(colorsSpace: cs, colors: colors, locations: locs)
    }()

    static func mondayOf(_ date: Date) -> Date {
        let cal = calendar
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        let midnight = cal.date(from: comps) ?? date
        let weekday = cal.component(.weekday, from: midnight) // Sun=1, Mon=2..Sat=7
        let offset = (weekday == 1) ? -6 : (2 - weekday)
        return cal.date(byAdding: .day, value: offset, to: midnight) ?? midnight
    }

    static func dateStr(_ date: Date) -> String {
        let cal = calendar
        let y = cal.component(.year, from: date)
        let m = cal.component(.month, from: date)
        let d = cal.component(.day, from: date)
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    static func parseDate(_ str: String?) -> Date {
        guard let str = str, !str.isEmpty else { return Date() }
        let parts = str.split(separator: "-").compactMap { Int($0) }
        var c = DateComponents()
        if parts.count >= 3 {
            c.year = parts[0]; c.month = parts[1]; c.day = parts[2]
        } else if parts.count == 2 {
            c.year = parts[0]; c.month = parts[1]; c.day = 1
        } else {
            return Date()
        }
        return calendar.date(from: c) ?? Date()
    }

    static func isoWeekNumber(_ date: Date) -> Int {
        isoCalendar.component(.weekOfYear, from: date)
    }

    // MARK: - Detection & Metadata

    static func isHobonichi(doc: InkDocument, pdfPageCount: Int, firstPageSize: CGSize?) -> Bool {
        if doc.bookmarks["__hobo__"] != nil { return true }
        if pdfPageCount == 2, let sz = firstPageSize,
           abs(sz.width - pageWidth) < 2.0, abs(sz.height - pageHeight) < 2.0 {
            return true
        }
        for b in doc.blanks.values {
            if (b.kind ?? "").hasPrefix("hobo-") { return true }
        }
        return false
    }

    static func slotKind(for slot: PageSlot, isHobo: Bool) -> String? {
        if let k = slot.blank?.kind, k.hasPrefix("hobo-") { return k }
        guard isHobo else { return nil }
        if slot.pdfN == 1 { return "hobo-index" }
        if slot.pdfN == 2 { return "hobo-notes" }
        if let b = slot.blank { return b.anchor == 2 ? "hobo-notes" : "hobo-memo" }
        return nil
    }

    static func slotLabel(for slot: PageSlot, doc: InkDocument) -> String {
        if slot.pdfN == 1 { return "Index & Glossary" }
        if slot.blank?.kind == "hobo-glossary" { return "Glossary P.\(slot.blank?.glossPage ?? 2)" }
        let customTitle = slot.blank?.title ?? doc.bookmarks[slot.key]?.title ?? ""
        if slot.pdfN == 2 { return customTitle.isEmpty ? "Notes 1" : "Notes 1: \(customTitle)" }
        guard let b = slot.blank else { return "Page \(slot.index + 1)" }
        if b.kind == "hobo-month", let ym = b.ym {
            let d = parseDate(ym)
            let m = calendar.component(.month, from: d) - 1
            let y = calendar.component(.year, from: d)
            return "\(monthsShort[max(0, min(11, m))]) \(y) (Month)"
        }
        if b.kind == "hobo-week", let mon = b.monday {
            let d = parseDate(mon)
            let m = calendar.component(.month, from: d) - 1
            let day = calendar.component(.day, from: d)
            let y = calendar.component(.year, from: d)
            return "\(monthsShort[max(0, min(11, m))]) \(day), \(y) (W\(isoWeekNumber(d)))"
        }
        if b.kind == "hobo-notes" {
            let base = b.noteNum != nil ? "Notes \(b.noteNum!)" : "Notes"
            return customTitle.isEmpty ? base : "\(base): \(customTitle)"
        }
        return customTitle.isEmpty ? "\(slot.index + 1) · added" : "\(slot.index + 1) · \(customTitle)"
    }

    // MARK: - Planner Page Generator (100% Compatible with Obsidian `hoboBuildPlannerEntries`)

    static func buildPlannerEntries(
        startDate: Date,
        numWeeks: Int,
        existingBlanks: [String: BlankPage] = [:],
        startNotePages: Int = 5
    ) -> [BlankPage] {
        var added: [BlankPage] = []
        let cal = calendar
        let curMon = mondayOf(startDate)
        var haveIds = Set(existingBlanks.keys)

        for w in 0..<max(0, numWeeks) {
            let mon = cal.date(byAdding: .day, value: w * 7, to: curMon) ?? curMon
            let sun = cal.date(byAdding: .day, value: 6, to: mon) ?? mon
            let monY = cal.component(.year, from: mon)
            let monM = cal.component(.month, from: mon)
            let monD = cal.component(.day, from: mon)
            let sunY = cal.component(.year, from: sun)
            let sunM = cal.component(.month, from: sun)

            var monthsToEnsure: [(y: Int, m: Int)] = []
            if w == 0 {
                monthsToEnsure.append((monY, monM))
            }
            if monM != sunM || monD == 1 {
                let target = (monD == 1) ? (monY, monM) : (sunY, sunM)
                if !monthsToEnsure.contains(where: { $0.y == target.0 && $0.m == target.1 }) {
                    monthsToEnsure.append(target)
                }
            }

            for ym in monthsToEnsure {
                let mStr = String(format: "%04d-%02d", ym.y, ym.m)
                let mId = "hm-\(mStr)"
                if !haveIds.contains(mId) {
                    haveIds.insert(mId)
                    var fc = DateComponents(); fc.year = ym.y; fc.month = ym.m; fc.day = 1
                    let firstDay = cal.date(from: fc) ?? mon
                    let firstMon = mondayOf(firstDay)
                    let sortMs = min(
                        Int64(firstDay.timeIntervalSince1970 * 1000),
                        Int64(firstMon.timeIntervalSince1970 * 1000)
                    ) - 3_600_000
                    var b = BlankPage(id: mId, anchor: 1, parent: "1", ord: 0, w: Double(pageWidth), h: Double(pageHeight), t: sortMs)
                    b.kind = "hobo-month"
                    b.ym = mStr
                    added.append(b)
                }
            }

            let dStr = dateStr(mon)
            let wId = "hw-\(dStr)"
            if !haveIds.contains(wId) {
                haveIds.insert(wId)
                var b = BlankPage(
                    id: wId, anchor: 1, parent: "1", ord: 0,
                    w: Double(pageWidth), h: Double(pageHeight),
                    t: Int64(mon.timeIntervalSince1970 * 1000)
                )
                b.kind = "hobo-week"
                b.monday = dStr
                added.append(b)
            }
        }

        if startNotePages >= 2 {
            for np in 2...startNotePages {
                let nId = "hn-\(np)"
                if !haveIds.contains(nId) {
                    haveIds.insert(nId)
                    var b = BlankPage(
                        id: nId, anchor: 2, parent: "2", ord: np,
                        w: Double(pageWidth), h: Double(pageHeight),
                        t: Int64(1000 + np)
                    )
                    b.kind = "hobo-notes"
                    b.noteNum = np
                    added.append(b)
                }
            }
        }
        return added
    }

    // MARK: - Obsidian-Compatible PDF Generators (New Notebook + New Hobonichi Journal)

    static func createNotebookPDF(template: PaperTemplate, size: CGSize = CGSize(width: 595, height: 842)) -> Data {
        PlatformGraphics.makePDFData(pageSizes: [size]) { _, cgCtx, _ in
            template.draw(in: cgCtx, size: size)
        }
    }

    static func createHobonichiBasePDF() -> Data {
        PlatformGraphics.makePDFData(pageSizes: [pageSize, pageSize]) { _, cgCtx, rect in
            cgCtx.setFillColor(creamColor.cgColor)
            cgCtx.fill(rect)
        }
    }

    // MARK: - CoreGraphics Vector Spread Renderer

    static func drawSpread(
        in ctx: CGContext,
        slot: PageSlot,
        doc: InkDocument,
        allSlots: [PageSlot],
        isHobo: Bool
    ) {
        guard let kind = slotKind(for: slot, isHobo: isHobo) else { return }
        let W = slot.size.width
        let H = slot.size.height
        let mid = W * 0.5

        ctx.saveGState()
        PlatformGraphics.pushFlippedContext(ctx)
        defer {
            PlatformGraphics.popFlippedContext()
            ctx.restoreGState()
        }
        drawBasePaper(in: ctx, W: W, H: H)

        switch kind {
        case "hobo-week":
            drawWeekSpread(in: ctx, W: W, H: H, mid: mid, mondayStr: slot.blank?.monday)
        case "hobo-month":
            drawMonthSpread(in: ctx, W: W, H: H, ymStr: slot.blank?.ym)
        case "hobo-index":
            drawIndexSpread(in: ctx, W: W, H: H, mid: mid, doc: doc, allSlots: allSlots)
        default:
            drawNotesSpread(in: ctx, W: W, H: H, mid: mid, slot: slot, doc: doc, kind: kind)
        }
    }

    private static func drawBasePaper(in ctx: CGContext, W: CGFloat, H: CGFloat) {
        ctx.setFillColor(creamColor.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

        let mid = W * 0.5
        if let grad = spineGradient {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: mid - 22, y: 0, width: 44, height: H))
            ctx.drawLinearGradient(grad, start: CGPoint(x: mid - 22, y: 0), end: CGPoint(x: mid + 22, y: 0), options: [])
            ctx.restoreGState()
        }
        ctx.setStrokeColor(PlatformColor(red: 0.35, green: 0.32, blue: 0.27, alpha: 0.28).cgColor)
        ctx.setLineWidth(0.8)
        ctx.move(to: CGPoint(x: mid, y: 0))
        ctx.addLine(to: CGPoint(x: mid, y: H))
        ctx.strokePath()
    }

    private static func drawGrid(in ctx: CGContext, x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat, step: CGFloat = 10.5) {
        ctx.saveGState()
        ctx.setStrokeColor(gridColor.cgColor)
        ctx.setLineWidth(0.45)
        var x = x0
        while x <= x1 + 0.1 {
            ctx.move(to: CGPoint(x: x, y: y0))
            ctx.addLine(to: CGPoint(x: x, y: y1))
            x += step
        }
        var y = y0
        while y <= y1 + 0.1 {
            ctx.move(to: CGPoint(x: x0, y: y))
            ctx.addLine(to: CGPoint(x: x1, y: y))
            y += step
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func drawText(_ text: String, at pt: CGPoint, font: PlatformFont, color: PlatformColor, align: NSTextAlignment = .left, maxWidth: CGFloat = 500) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let ns = text as NSString
        let sz = ns.size(withAttributes: attrs)
        var x = pt.x
        if align == .right { x -= sz.width }
        else if align == .center { x -= sz.width * 0.5 }
        ns.draw(in: CGRect(x: x, y: pt.y, width: min(maxWidth, sz.width + 4), height: sz.height + 2), withAttributes: attrs)
    }

    private static func drawMiniMonth(in ctx: CGContext, rect: CGRect, year: Int, monthZeroBased: Int, highlightMonday: String = "") {
        ctx.saveGState()
        ctx.setFillColor(creamColor.cgColor)
        ctx.fill(rect.insetBy(dx: -3, dy: -3))
        ctx.setStrokeColor(gridStrong.cgColor)
        ctx.setLineWidth(0.7)
        ctx.stroke(rect)

        let title = "\(monthsShort[monthZeroBased].uppercased()) \(year)"
        drawText(title, at: CGPoint(x: rect.minX + 6, y: rect.minY + 4), font: .systemFont(ofSize: 8.5, weight: .bold), color: inkColor)
        drawText(String(format: "%02d", monthZeroBased + 1), at: CGPoint(x: rect.maxX - 6, y: rect.minY + 4.5), font: .systemFont(ofSize: 8, weight: .semibold), color: mutedColor, align: .right)

        let colW = (rect.width - 8) / 7.0
        let rowH = (rect.height - 28) / 7.0
        let startX = rect.minX + 4
        let startY = rect.minY + 18

        let hdrFont = PlatformFont.systemFont(ofSize: 6.8, weight: .semibold)
        for c in 0..<7 {
            let col = (c == 6) ? redColor : (c == 5 ? blueColor : mutedColor)
            drawText(daysMini[c], at: CGPoint(x: startX + (CGFloat(c) + 0.5) * colW, y: startY), font: hdrFont, color: col, align: .center)
        }

        let cal = calendar
        var fc = DateComponents(); fc.year = year; fc.month = monthZeroBased + 1; fc.day = 1
        let first = cal.date(from: fc) ?? Date()
        let wd = cal.component(.weekday, from: first) // Sun=1, Mon=2
        let firstDow = (wd + 5) % 7 // Mon=0..Sun=6
        let daysInMonth = cal.range(of: .day, in: .month, for: first)?.count ?? 30

        if !highlightMonday.isEmpty {
            for d in 1...daysInMonth {
                var dc = DateComponents(); dc.year = year; dc.month = monthZeroBased + 1; dc.day = d
                if let dt = cal.date(from: dc), dateStr(mondayOf(dt)) == highlightMonday {
                    let row = (firstDow + d - 1) / 7
                    let hlRect = CGRect(x: rect.minX + 2, y: startY + 9 + CGFloat(row) * rowH, width: rect.width - 4, height: rowH + 1)
                    ctx.setFillColor(redColor.withAlphaComponent(0.11).cgColor)
                    ctx.fill(hlRect)
                    ctx.setStrokeColor(redColor.withAlphaComponent(0.45).cgColor)
                    ctx.setLineWidth(0.6)
                    ctx.stroke(hlRect)
                    break
                }
            }
        }

        let dayFont = PlatformFont.systemFont(ofSize: 7.2, weight: .medium)
        for d in 1...daysInMonth {
            let cell = firstDow + d - 1
            let r = cell / 7
            let c = cell % 7
            let col = (c == 6) ? redColor : (c == 5 ? blueColor : inkColor)
            drawText("\(d)", at: CGPoint(x: startX + (CGFloat(c) + 0.5) * colW, y: startY + 10 + CGFloat(r) * rowH), font: dayFont, color: col, align: .center)
        }
        ctx.restoreGState()
    }

    private static func drawWeekSpread(in ctx: CGContext, W: CGFloat, H: CGFloat, mid: CGFloat, mondayStr: String?) {
        let cal = calendar
        let mon = parseDate(mondayStr)
        let sun = cal.date(byAdding: .day, value: 6, to: mon) ?? mon
        let wk = isoWeekNumber(mon)
        let padL: CGFloat = 34, padR: CGFloat = 26, topY: CGFloat = 56, botY: CGFloat = H - 30
        let boxW = mid - padL - padR
        let dayH = (botY - topY) / 7.0

        let monM = cal.component(.month, from: mon) - 1
        let sunM = cal.component(.month, from: sun) - 1
        let monY = cal.component(.year, from: mon)
        let sunY = cal.component(.year, from: sun)
        let mTitle = (monM == sunM)
            ? "\(monthsFull[monM]) \(monY)"
            : "\(monthsShort[monM].uppercased()) – \(monthsShort[sunM].uppercased()) \(sunY)"

        drawText(mTitle, at: CGPoint(x: padL, y: topY - 30), font: .systemFont(ofSize: 15, weight: .heavy), color: inkColor)
        drawText("WEEK \(wk)", at: CGPoint(x: mid - padR, y: topY - 25), font: .systemFont(ofSize: 9.5, weight: .semibold), color: mutedColor, align: .right)

        drawGrid(in: ctx, x0: padL + 58, y0: topY, x1: mid - padR, y1: botY)

        ctx.setStrokeColor(inkColor.cgColor)
        ctx.setLineWidth(0.9)
        ctx.move(to: CGPoint(x: padL, y: topY)); ctx.addLine(to: CGPoint(x: mid - padR, y: topY))
        ctx.move(to: CGPoint(x: padL, y: botY)); ctx.addLine(to: CGPoint(x: mid - padR, y: botY))
        ctx.strokePath()

        let splitX = padL + 58 + ((boxW - 58) * 0.27 / 10.5).rounded() * 10.5
        ctx.saveGState()
        ctx.setStrokeColor(gridStrong.cgColor)
        ctx.setLineWidth(0.55)
        ctx.setLineDash(phase: 0, lengths: [2.0, 2.5])
        ctx.move(to: CGPoint(x: splitX, y: topY)); ctx.addLine(to: CGPoint(x: splitX, y: botY))
        ctx.strokePath()
        ctx.restoreGState()

        for i in 0..<7 {
            let dy = topY + CGFloat(i) * dayH
            let cur = cal.date(byAdding: .day, value: i, to: mon) ?? mon
            let dNum = cal.component(.day, from: cur)
            let cMonth = cal.component(.month, from: cur) - 1
            let dayCol = (i == 6) ? redColor : (i == 5 ? blueColor : inkColor)

            if i > 0 {
                ctx.setStrokeColor(gridStrong.cgColor)
                ctx.setLineWidth(0.7)
                ctx.move(to: CGPoint(x: padL, y: dy)); ctx.addLine(to: CGPoint(x: mid - padR, y: dy))
                ctx.strokePath()
            }
            ctx.setStrokeColor(gridStrong.cgColor)
            ctx.setLineWidth(0.55)
            ctx.move(to: CGPoint(x: padL + 58, y: dy)); ctx.addLine(to: CGPoint(x: padL + 58, y: dy + dayH))
            ctx.strokePath()

            drawText("\(dNum)", at: CGPoint(x: padL + 6, y: dy + 8), font: .systemFont(ofSize: 17, weight: .bold), color: dayCol)
            drawText(days[i], at: CGPoint(x: padL + 6, y: dy + 29), font: .systemFont(ofSize: 8.5, weight: .bold), color: dayCol)
            if dNum == 1 || i == 0 {
                drawText(monthsShort[cMonth].uppercased(), at: CGPoint(x: padL + 6, y: dy + 42), font: .systemFont(ofSize: 7.5, weight: .semibold), color: mutedColor)
            }

            ctx.setFillColor(mutedColor.cgColor)
            for frac: CGFloat in [0.25, 0.5, 0.75] {
                ctx.fillEllipse(in: CGRect(x: splitX - 1.1, y: dy + dayH * frac - 1.1, width: 2.2, height: 2.2))
            }
        }

        // Right Page: Full 3.55mm Graph Memo + Mini Calendar
        let rLeft = mid + 26, rRight = W - 34
        ctx.setStrokeColor(inkColor.cgColor)
        ctx.setLineWidth(0.9)
        ctx.move(to: CGPoint(x: rLeft, y: topY)); ctx.addLine(to: CGPoint(x: rRight, y: topY))
        ctx.strokePath()

        drawText("MEMO & FREE NOTES", at: CGPoint(x: rLeft, y: topY - 24), font: .systemFont(ofSize: 8.5, weight: .semibold), color: mutedColor)
        drawText("\(dateStr(mon)) — \(dateStr(sun))", at: CGPoint(x: rRight, y: topY - 24), font: .systemFont(ofSize: 8.5, weight: .semibold), color: mutedColor, align: .right)

        drawGrid(in: ctx, x0: rLeft, y0: topY, x1: rRight, y1: botY)

        let calRect = CGRect(x: rRight - 154, y: botY - 118, width: 148, height: 112)
        drawMiniMonth(in: ctx, rect: calRect, year: monY, monthZeroBased: monM, highlightMonday: dateStr(mon))
    }

    private static func drawMonthSpread(in ctx: CGContext, W: CGFloat, H: CGFloat, ymStr: String?) {
        let cal = calendar
        let d0 = parseDate(ymStr)
        let year = cal.component(.year, from: d0)
        let month = cal.component(.month, from: d0) - 1
        let padL: CGFloat = 36, padR: CGFloat = 36, topY: CGFloat = 66, botY: CGFloat = H - 84
        let sidebarW: CGFloat = 148
        let gridLeft = padL + sidebarW + 14
        let gridRight = W - padR
        let gridW = gridRight - gridLeft
        let colW = gridW / 7.0

        drawText("\(monthsFull[month]) \(year)", at: CGPoint(x: padL, y: topY - 38), font: .systemFont(ofSize: 20, weight: .heavy), color: inkColor)
        drawText(String(format: "MONTH %02d", month + 1), at: CGPoint(x: gridRight, y: topY - 30), font: .systemFont(ofSize: 11, weight: .bold), color: redColor, align: .right)

        drawGrid(in: ctx, x0: padL, y0: topY, x1: padL + sidebarW, y1: botY)
        drawGrid(in: ctx, x0: padL, y0: botY + 12, x1: gridRight, y1: H - 26)

        ctx.setStrokeColor(inkColor.cgColor)
        ctx.setLineWidth(0.9)
        ctx.move(to: CGPoint(x: padL, y: topY)); ctx.addLine(to: CGPoint(x: padL + sidebarW, y: topY))
        ctx.strokePath()
        drawText("MONTHLY FOCUS / GOALS", at: CGPoint(x: padL + 4, y: topY - 14), font: .systemFont(ofSize: 8, weight: .bold), color: mutedColor)

        var fc = DateComponents(); fc.year = year; fc.month = month + 1; fc.day = 1
        let first = cal.date(from: fc) ?? d0
        let firstDow = (cal.component(.weekday, from: first) + 5) % 7
        let daysInMonth = cal.range(of: .day, in: .month, for: first)?.count ?? 30
        let numRows = Int(ceil(Double(firstDow + daysInMonth) / 7.0))
        let rowH = (botY - (topY + 20)) / CGFloat(max(1, numRows))

        ctx.setFillColor(creamDark.cgColor)
        ctx.fill(CGRect(x: gridLeft, y: topY, width: gridW, height: 20))
        ctx.setStrokeColor(inkColor.cgColor)
        ctx.setLineWidth(0.9)
        ctx.stroke(CGRect(x: gridLeft, y: topY, width: gridW, height: botY - topY))

        for c in 0..<7 {
            let cx = gridLeft + (CGFloat(c) + 0.5) * colW
            let col = (c == 6) ? redColor : (c == 5 ? blueColor : inkColor)
            drawText(days[c], at: CGPoint(x: cx, y: topY + 4.5), font: .systemFont(ofSize: 9, weight: .bold), color: col, align: .center)
            if c > 0 {
                ctx.setStrokeColor(gridStrong.cgColor)
                ctx.setLineWidth(0.65)
                ctx.move(to: CGPoint(x: gridLeft + CGFloat(c) * colW, y: topY))
                ctx.addLine(to: CGPoint(x: gridLeft + CGFloat(c) * colW, y: botY))
                ctx.strokePath()
            }
        }
        for r in 0..<numRows {
            let ry = topY + 20 + CGFloat(r) * rowH
            ctx.setStrokeColor(gridStrong.cgColor)
            ctx.setLineWidth(0.65)
            ctx.move(to: CGPoint(x: gridLeft, y: ry)); ctx.addLine(to: CGPoint(x: gridRight, y: ry))
            ctx.strokePath()
        }

        let dayFont = PlatformFont.systemFont(ofSize: 11, weight: .bold)
        for d in 1...daysInMonth {
            let cell = firstDow + d - 1
            let r = cell / 7
            let c = cell % 7
            let col = (c == 6) ? redColor : (c == 5 ? blueColor : inkColor)
            drawText("\(d)", at: CGPoint(x: gridLeft + CGFloat(c) * colW + 6, y: topY + 25 + CGFloat(r) * rowH), font: dayFont, color: col)
        }
    }

    private static func drawIndexSpread(in ctx: CGContext, W: CGFloat, H: CGFloat, mid: CGFloat, doc: InkDocument, allSlots: [PageSlot]) {
        let padL: CGFloat = 36, padR: CGFloat = 28, topY: CGFloat = 58, botY: CGFloat = H - 30
        var years = Set<Int>()
        for b in doc.blanks.values {
            if b.kind == "hobo-week", let m = b.monday, let y = Int(m.prefix(4)) { years.insert(y) }
            else if b.kind == "hobo-month", let ym = b.ym, let y = Int(ym.prefix(4)) { years.insert(y) }
        }
        let sortedYears = years.sorted()
        let activeYear = sortedYears.first ?? calendar.component(.year, from: Date())

        drawText("HOBONICHI WEEKS · \(activeYear)", at: CGPoint(x: padL, y: topY - 34), font: .systemFont(ofSize: 18, weight: .heavy), color: inkColor)
        let sub = sortedYears.count > 1 ? "YEARS: \(sortedYears.map(String.init).joined(separator: " · "))" : "YEAR-AT-A-GLANCE & GLOSSARY"
        drawText(sub, at: CGPoint(x: mid - padR, y: topY - 26), font: .systemFont(ofSize: 8.5, weight: .semibold), color: mutedColor, align: .right)

        let gridW = mid - padL - padR
        let gridH = botY - topY
        let gapX: CGFloat = 12, gapY: CGFloat = 12
        let cardW = (gridW - gapX * 2) / 3.0
        let cardH = (gridH - gapY * 3) / 4.0

        for m in 0..<12 {
            let r = m / 3
            let c = m % 3
            let rect = CGRect(x: padL + CGFloat(c) * (cardW + gapX), y: topY + CGFloat(r) * (cardH + gapY), width: cardW, height: cardH)
            drawMiniMonth(in: ctx, rect: rect, year: activeYear, monthZeroBased: m)
        }

        // Right Page: Glossary & Master Index
        let rLeft = mid + 28, rRight = W - 36
        drawText("GLOSSARY & MASTER INDEX", at: CGPoint(x: rLeft, y: topY - 30), font: .systemFont(ofSize: 15, weight: .heavy), color: inkColor)
        drawText("BOOKMARKS & BACK NOTES", at: CGPoint(x: rRight, y: topY - 24), font: .systemFont(ofSize: 8, weight: .semibold), color: mutedColor, align: .right)

        drawGrid(in: ctx, x0: rLeft, y0: topY, x1: rRight, y1: botY)
        ctx.setStrokeColor(inkColor.cgColor)
        ctx.setLineWidth(0.9)
        ctx.move(to: CGPoint(x: rLeft, y: topY)); ctx.addLine(to: CGPoint(x: rRight, y: topY))
        ctx.move(to: CGPoint(x: rLeft, y: botY)); ctx.addLine(to: CGPoint(x: rRight, y: botY))
        ctx.strokePath()

        let rowStep: CGFloat = 21
        let colSplit = rLeft + 92
        ctx.setStrokeColor(gridStrong.cgColor)
        ctx.setLineWidth(0.6)
        ctx.move(to: CGPoint(x: colSplit, y: topY)); ctx.addLine(to: CGPoint(x: colSplit, y: botY))
        var y = topY + rowStep
        while y < botY - 4 {
            ctx.move(to: CGPoint(x: rLeft, y: y)); ctx.addLine(to: CGPoint(x: rRight, y: y))
            y += rowStep
        }
        ctx.strokePath()

        drawText("PAGE / REF", at: CGPoint(x: rLeft + 6, y: topY + 6), font: .systemFont(ofSize: 7.8, weight: .bold), color: mutedColor)
        drawText("BOOKMARKED SPREAD / BACK NOTE", at: CGPoint(x: colSplit + 10, y: topY + 6), font: .systemFont(ofSize: 7.8, weight: .bold), color: mutedColor)

        var rowIdx = 1
        for s in allSlots {
            if s.pdfN == 1 { continue }
            let isBm = doc.isBookmarked(s.key)
            let isNote = (s.pdfN == 2 || s.blank?.kind == "hobo-notes")
            let title = s.blank?.title ?? doc.bookmarks[s.key]?.title ?? ""
            if !isBm && !(isNote && !title.isEmpty) { continue }
            if topY + CGFloat(rowIdx + 1) * rowStep > botY + 2 { break }
            let ry = topY + CGFloat(rowIdx) * rowStep + 5
            let ref = isNote ? "P.\(s.index + 1) (N-\(s.pdfN == 2 ? 1 : (s.blank?.noteNum ?? 1)))" : "P. \(s.index + 1)"
            drawText(ref, at: CGPoint(x: rLeft + 6, y: ry), font: .systemFont(ofSize: 8.8, weight: .bold), color: isNote ? blueColor : redColor)
            let label = title.isEmpty ? slotLabel(for: s, doc: doc) : title
            drawText(String(label.prefix(44)), at: CGPoint(x: colSplit + 10, y: ry), font: .systemFont(ofSize: 9.2, weight: .semibold), color: inkColor, maxWidth: rRight - colSplit - 18)
            rowIdx += 1
        }
    }

    private static func drawNotesSpread(in ctx: CGContext, W: CGFloat, H: CGFloat, mid: CGFloat, slot: PageSlot, doc: InkDocument, kind: String) {
        let padL: CGFloat = 34, padR: CGFloat = 26, topY: CGFloat = 50, botY: CGFloat = H - 30
        let rLeft = mid + 26, rRight = W - 34
        drawGrid(in: ctx, x0: padL, y0: topY, x1: mid - padR, y1: botY)
        drawGrid(in: ctx, x0: rLeft, y0: topY, x1: rRight, y1: botY)

        ctx.setStrokeColor(inkColor.cgColor)
        ctx.setLineWidth(0.85)
        ctx.move(to: CGPoint(x: padL, y: topY)); ctx.addLine(to: CGPoint(x: mid - padR, y: topY))
        ctx.move(to: CGPoint(x: rLeft, y: topY)); ctx.addLine(to: CGPoint(x: rRight, y: topY))
        ctx.strokePath()

        let isBackNote = (kind == "hobo-notes")
        let noteN = slot.pdfN == 2 ? 1 : (slot.blank?.noteNum ?? 0)
        let customTitle = slot.blank?.title ?? doc.bookmarks[slot.key]?.title ?? ""
        let leftHdr = isBackNote
            ? "BACK NOTES\(noteN > 0 ? " · N-\(noteN)" : "")\(customTitle.isEmpty ? "" : "  —  \(customTitle.uppercased())")"
            : "EXTRA MEMO SPREAD\(customTitle.isEmpty ? "" : "  —  \(customTitle.uppercased())")"
        drawText(leftHdr, at: CGPoint(x: padL, y: topY - 22), font: .systemFont(ofSize: customTitle.isEmpty ? 8.5 : 9.5, weight: .bold), color: customTitle.isEmpty ? mutedColor : inkColor)
        drawText("PAGE \(slot.index + 1)", at: CGPoint(x: rRight, y: topY - 22), font: .systemFont(ofSize: 8.5, weight: .bold), color: mutedColor, align: .right)
    }
}
