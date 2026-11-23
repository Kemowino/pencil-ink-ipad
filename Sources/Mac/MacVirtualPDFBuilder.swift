import Foundation
import AppKit
import PDFKit

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
        context.saveGState()
        context.translateBy(x: 0, y: slot.size.height)
        context.scaleBy(x: 1, y: -1)
        slot.template.draw(in: context, size: slot.size)
        context.restoreGState()
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

struct MacVirtualPDFResult {
    let document: PDFDocument
    let slots: [PageSlot]
    let slotByPageID: [ObjectIdentifier: PageSlot]
    let slotIndexByKey: [String: Int]
    let pageIndexByPDFN: [Int: Int]
    let isHobonichi: Bool
}

/// Maps an on-disk PDF + `.ink.json` (blanks, duplicated pages, hidden pages, Hobonichi spreads)
/// into an in-memory `PDFDocument` for Apple Preview's native `PDFView` with 1:1 slot parity!
enum MacVirtualPDFBuilder {
    static func build(from pdfURL: URL, inkDoc: inout InkDocument) -> MacVirtualPDFResult? {
        autoreleasepool {
            buildInner(from: pdfURL, inkDoc: &inkDoc)
        }
    }

    private static func buildInner(from pdfURL: URL, inkDoc: inout InkDocument) -> MacVirtualPDFResult? {
        guard let sourceDoc = PDFDocument(url: pdfURL) else { return nil }
        let rawCount = sourceDoc.pageCount
        guard rawCount > 0 else { return nil }

        let firstSize = sourceDoc.page(at: 0).map { PlatformGraphics.normalizedPageSize(for: $0) }
            ?? CGSize(width: 595, height: 842)
        let isHobo = HobonichiEngine.isHobonichi(doc: inkDoc, pdfPageCount: rawCount, firstPageSize: firstSize)

        // Fast size collection: for uniform 2,000-page textbooks, sample 7 pages first to keep open instant (<5ms)!
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
            // Zero-copy fast-path: use the original `PDFDocument` directly (keeps PDF outlines/links/search intact!)
            finalDoc = sourceDoc
            for (idx, slot) in slots.enumerated() {
                slotIndexByKey[slot.key] = idx
                if let pdfN = slot.pdfN { pageIndexByPDFN[pdfN] = idx }
                if let p = finalDoc.page(at: idx) {
                    slotByPageID[ObjectIdentifier(p)] = slot
                }
            }
        } else {
            // Mutate `sourceDoc` in-memory (preserves embedded PDF Outline/TOC destinations!)
            finalDoc = sourceDoc
            // First replace/insert virtual pages cleanly into a fresh order while keeping original PDFPage instances
            var originalPages: [Int: PDFPage] = [:]
            originalPages.reserveCapacity(rawCount)
            for i in 0..<rawCount {
                if let p = sourceDoc.page(at: i) {
                    originalPages[i + 1] = p
                }
            }

            // Remove all existing pages from `finalDoc` and re-insert in exact `slots` order
            // (retaining the exact original `PDFPage` objects so PDFOutline links still resolve!)
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
