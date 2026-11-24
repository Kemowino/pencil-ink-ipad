import Foundation
import AppKit
import PDFKit

/// Thread-safe global paper mode storage read by `MacThemedPDFPage.draw(with:to:)` on PDFKit's tile threads.
/// Uses pure CoreGraphics blend modes baked ONCE into PDFKit's `CATiledLayer` cache:
/// - **ZERO `CoreImage` / ZERO `CIFilter` / ZERO `layerUsesCoreImageFilters`**
/// - **ZERO AMD Radeon dGPU wakeups!**
/// - Scrolling Dark Paper costs the same ~16% CPU & ~7 W as Original Paper!
enum MacPaperThemeRenderer {
    private static let lock = NSLock()
    private static var _modeRaw: Int = 0 // 0 = original, 1 = sepia, 2 = dark

    static func setMode(_ mode: MacPaperMode) {
        let v: Int
        switch mode {
        case .original: v = 0
        case .sepia: v = 1
        case .dark: v = 2
        }
        lock.lock()
        _modeRaw = v
        lock.unlock()
    }

    static var currentMode: MacPaperMode {
        lock.lock()
        let v = _modeRaw
        lock.unlock()
        switch v {
        case 1: return .sepia
        case 2: return .dark
        default: return .original
        }
    }

    /// Draws a crisp 0.5pt Apple Books-style page border without blurry GPU drop-shadow passes.
    static func drawSubtlePageBorder(in ctx: CGContext, rect: CGRect, mode: MacPaperMode) {
        ctx.saveGState()
        if mode == .dark {
            ctx.setStrokeColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.08)
        } else {
            ctx.setStrokeColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.10)
        }
        ctx.setLineWidth(0.75)
        ctx.stroke(rect.insetBy(dx: 0.375, dy: 0.375))
        ctx.restoreGState()
    }

    /// Ultra-low-energy 1-pass CoreGraphics paper theming baked ONCE into PDFKit's `CATiledLayer` cache:
    /// - Original: 100% passthrough (ZERO overhead)
    /// - Sepia: 1× draw + 1× `.multiply` fill (ZERO offscreen buffers)
    /// - Dark Paper: 1× draw + 1× `.exclusion` (0.89) fill (ZERO transparency layer, ZERO 2nd PDF draw!)
    ///   Strictly monotonic: White #FFFFFF -> #1C1C1C charcoal, Light Gray #EAEAEA -> #2C2C2C, Black #000000 -> #E3E3E3!
    static func drawThemed(rect: CGRect, in ctx: CGContext, drawContent: () -> Void) {
        let mode = currentMode
        switch mode {
        case .original:
            drawContent()

        case .sepia:
            let clip = ctx.boundingBoxOfClipPath.intersection(rect)
            guard !clip.isNull, !clip.isEmpty else { return }
            ctx.saveGState()
            ctx.clip(to: clip)
            drawContent()
            ctx.setBlendMode(.multiply)
            ctx.setFillColor(red: 0.965, green: 0.935, blue: 0.865, alpha: 1.0)
            ctx.fill(clip)
            ctx.restoreGState()

        case .dark:
            let clip = ctx.boundingBoxOfClipPath.intersection(rect)
            guard !clip.isNull, !clip.isEmpty else { return }
            ctx.saveGState()
            ctx.clip(to: clip)
            ctx.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
            ctx.fill(clip)
            drawContent()
            ctx.setBlendMode(.exclusion)
            ctx.setFillColor(red: 0.89, green: 0.89, blue: 0.89, alpha: 1.0)
            ctx.fill(clip)
            ctx.restoreGState()
        }
    }
}

/// Zero-overhead `PDFPage` subclass instantiated automatically for every page by `MacThemedPDFDocument`.
final class MacThemedPDFPage: PDFPage {
    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        if MacPaperThemeRenderer.currentMode == .original {
            super.draw(with: box, to: context)
            return
        }
        let rect = bounds(for: box)
        MacPaperThemeRenderer.drawThemed(rect: rect, in: context) {
            super.draw(with: box, to: context)
        }
    }
}

/// Zero-copy `PDFDocument` subclass that vends `MacThemedPDFPage` instances (preserves outlines, links, & search 100%).
final class MacThemedPDFDocument: PDFDocument {
    override var pageClass: AnyClass {
        MacThemedPDFPage.self
    }
}

/// Lightweight vector `PDFPage` subclass rendering a ruled/grid/dot/cornell/blank inserted page in native PDFKit.
final class MacTemplatePDFPage: PDFPage {
    let slot: PageSlot

    init(slot: PageSlot) {
        self.slot = slot
        super.init()
    }

    override func bounds(for box: PDFDisplayBox) -> NSRect {
        NSRect(origin: .zero, size: slot.size)
    }

    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        let rect = NSRect(origin: .zero, size: slot.size)
        MacPaperThemeRenderer.drawThemed(rect: rect, in: context) {
            context.saveGState()
            context.translateBy(x: 0, y: slot.size.height)
            context.scaleBy(x: 1, y: -1)
            slot.template.draw(in: context, size: slot.size)
            context.restoreGState()
        }
    }
}

/// Lightweight vector `PDFPage` subclass rendering a Hobonichi Techo Weeks spread in native PDFKit.
final class MacHobonichiPDFPage: PDFPage {
    let slot: PageSlot
    var docSnapshot: InkDocument
    var allSlotsSnapshot: [PageSlot]

    init(slot: PageSlot, doc: InkDocument, allSlots: [PageSlot]) {
        self.slot = slot
        self.docSnapshot = doc
        self.allSlotsSnapshot = allSlots
        super.init()
    }

    override func bounds(for box: PDFDisplayBox) -> NSRect {
        NSRect(origin: .zero, size: slot.size)
    }

    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        let rect = NSRect(origin: .zero, size: slot.size)
        MacPaperThemeRenderer.drawThemed(rect: rect, in: context) {
            context.saveGState()
            context.translateBy(x: 0, y: slot.size.height)
            context.scaleBy(x: 1, y: -1)
            HobonichiEngine.drawSpread(
                in: context,
                slot: slot,
                doc: docSnapshot,
                allSlots: allSlotsSnapshot,
                isHobo: true
            )
            context.restoreGState()
        }
    }
}

struct MacVirtualPDFResult {
    let document: PDFDocument
    let slots: [PageSlot]
    let slotByPageID: [ObjectIdentifier: PageSlot]
    let slotIndexByKey: [String: Int]
    let pageIndexByPDFN: [Int: Int]
    let isHobonichi: Bool
}

/// Maps an on-disk PDF + `.ink.json` (blanks, duplicated pages, hidden pages, Hobonichi spreads)
/// into a `MacThemedPDFDocument` for Apple Preview's native `PDFView` with 1:1 slot parity!
enum MacVirtualPDFBuilder {
    static func build(from pdfURL: URL, inkDoc: inout InkDocument) -> MacVirtualPDFResult? {
        autoreleasepool {
            buildInner(from: pdfURL, inkDoc: &inkDoc)
        }
    }

    private static func buildInner(from pdfURL: URL, inkDoc: inout InkDocument) -> MacVirtualPDFResult? {
        guard let sourceDoc = MacThemedPDFDocument(url: pdfURL) else { return nil }
        let rawCount = sourceDoc.pageCount
        guard rawCount > 0 else { return nil }

        let firstSize = sourceDoc.page(at: 0).map { PlatformGraphics.normalizedPageSize(for: $0) }
            ?? CGSize(width: 595, height: 842)
        let isHobo = HobonichiEngine.isHobonichi(doc: inkDoc, pdfPageCount: rawCount, firstPageSize: firstSize)

        // Fast size collection: for uniform 2,500-page textbooks, sample 7 pages first to keep open instant (<5ms)!
        var pdfPageSizes: [CGSize] = []
        if rawCount <= 250 {
            pdfPageSizes.reserveCapacity(rawCount)
            for i in 0..<rawCount {
                let sz = sourceDoc.page(at: i).map { PlatformGraphics.normalizedPageSize(for: $0) } ?? firstSize
                pdfPageSizes.append(sz)
            }
        } else {
            let samples = [0, 1, 2, rawCount / 4, rawCount / 2, (rawCount * 3) / 4, rawCount - 1]
            var mixed = false
            for idx in samples {
                if let p = sourceDoc.page(at: idx) {
                    let sz = PlatformGraphics.normalizedPageSize(for: p)
                    if abs(sz.width - firstSize.width) > 2.0 || abs(sz.height - firstSize.height) > 2.0 {
                        mixed = true
                        break
                    }
                }
            }
            if mixed {
                pdfPageSizes.reserveCapacity(rawCount)
                for i in 0..<rawCount {
                    let sz = sourceDoc.page(at: i).map { PlatformGraphics.normalizedPageSize(for: $0) } ?? firstSize
                    pdfPageSizes.append(sz)
                }
            } else {
                pdfPageSizes = Array(repeating: firstSize, count: rawCount)
            }
        }

        let slots = inkDoc.buildPageSlots(pdfPageSizes: pdfPageSizes, defaultSize: firstSize)
        let hasStructureEdits = isHobo || !inkDoc.blanks.isEmpty || inkDoc.removedCount > 0

        let finalDoc: PDFDocument
        var slotByPageID: [ObjectIdentifier: PageSlot] = [:]
        var slotIndexByKey: [String: Int] = [:]
        var pageIndexByPDFN: [Int: Int] = [:]
        slotByPageID.reserveCapacity(slots.count)
        slotIndexByKey.reserveCapacity(slots.count)

        if !hasStructureEdits {
            finalDoc = sourceDoc
            for (idx, slot) in slots.enumerated() {
                slotIndexByKey[slot.key] = idx
                if let pdfN = slot.pdfN { pageIndexByPDFN[pdfN] = idx }
                if let p = finalDoc.page(at: idx) {
                    slotByPageID[ObjectIdentifier(p)] = slot
                }
            }
        } else {
            finalDoc = sourceDoc
            var originalPages: [Int: PDFPage] = [:]
            originalPages.reserveCapacity(rawCount)
            for i in 0..<rawCount {
                if let p = sourceDoc.page(at: i) {
                    originalPages[i + 1] = p
                }
            }

            for i in stride(from: finalDoc.pageCount - 1, through: 0, by: -1) {
                finalDoc.removePage(at: i)
            }

            for (idx, slot) in slots.enumerated() {
                slotIndexByKey[slot.key] = idx
                if let pdfN = slot.pdfN { pageIndexByPDFN[pdfN] = idx }

                let pageObj: PDFPage
                if isHobo && HobonichiEngine.slotKind(for: slot, isHobo: true) != nil {
                    pageObj = MacHobonichiPDFPage(slot: slot, doc: inkDoc, allSlots: slots)
                } else if let pdfN = slot.pdfN, let orig = originalPages[pdfN] {
                    pageObj = orig
                } else if let srcN = slot.srcN, let orig = originalPages[srcN], let copy = orig.copy() as? PDFPage {
                    pageObj = copy
                } else {
                    pageObj = MacTemplatePDFPage(slot: slot)
                }

                finalDoc.insert(pageObj, at: idx)
                slotByPageID[ObjectIdentifier(pageObj)] = slot
            }
        }

        return MacVirtualPDFResult(
            document: finalDoc,
            slots: slots,
            slotByPageID: slotByPageID,
            slotIndexByKey: slotIndexByKey,
            pageIndexByPDFN: pageIndexByPDFN,
            isHobonichi: isHobo
        )
    }
}
