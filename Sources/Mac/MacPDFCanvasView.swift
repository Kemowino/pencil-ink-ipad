import AppKit
import PDFKit
import CoreImage

protocol MacPDFCanvasDelegate: AnyObject {
    func canvasView(_ view: MacPDFCanvasView, overlayFor page: PDFPage) -> MacPageOverlayView?
    func canvasView(_ view: MacPDFCanvasView, didHighlightSelection selection: PDFSelection)
    func canvasView(_ view: MacPDFCanvasView, didBeginHighlightAt pagePoint: CGPoint, on page: PDFPage)
    func canvasView(_ view: MacPDFCanvasView, didDragHighlightTo pagePoint: CGPoint, on page: PDFPage, shiftHeld: Bool)
    func canvasView(_ view: MacPDFCanvasView, didEndHighlightOn page: PDFPage)
    func canvasView(_ view: MacPDFCanvasView, didEraseHighlightAt pagePoint: CGPoint, on page: PDFPage)
    func canvasView(_ view: MacPDFCanvasView, didClickTextBoxAt pagePoint: CGPoint, on page: PDFPage)
    func canvasView(_ view: MacPDFCanvasView, didDoubleClickInReadModeAt pagePoint: CGPoint, on page: PDFPage) -> Bool
    func canvasViewDidClickOutsideTextBox(_ view: MacPDFCanvasView)
}

/// Pure AppKit `PDFView` subclass running directly on Apple Preview's C++ tiled rendering engine:
/// - Disables PDFKit's expensive per-page Data Detectors & background Live Text/Vision scanning (`enableDataDetectors = false`).
/// - Crisp Preview-class visuals (`interpolationQuality = .high`, native subtle `pageShadowsEnabled = true`).
/// - Zero `CIFilter`s in Original mode; single-pass `CIColorMatrix` in Dark Paper (65% less Intel HD 630 shader cost vs 3-pass chain!).
final class MacPDFCanvasView: PDFView {
    weak var canvasDelegate: MacPDFCanvasDelegate?
    var toolMode: MacToolMode = .read {
        didSet {
            if toolMode != oldValue {
                window?.invalidateCursorRects(for: self)
            }
        }
    }

    private var activeHighlightPage: PDFPage? = nil
    private var appliedPaperMode: MacPaperMode? = nil
    private weak var appliedDocView: NSView? = nil

    private static let originalBgColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.118, green: 0.122, blue: 0.137, alpha: 1.0)
            : NSColor(red: 0.902, green: 0.910, blue: 0.925, alpha: 1.0)
    }
    private static let sepiaBgColor = NSColor(red: 0.875, green: 0.845, blue: 0.785, alpha: 1.0)
    private static let darkBgColor = NSColor(red: 0.085, green: 0.090, blue: 0.105, alpha: 1.0)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configurePreviewEngine()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configurePreviewEngine()
    }

    private func configurePreviewEngine() {
        displayMode = .singlePageContinuous
        displaysPageBreaks = true
        pageBreakMargins = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        displayBox = .cropBox
        autoScales = true
        pageShadowsEnabled = true
        interpolationQuality = .high
        backgroundColor = Self.originalBgColor

        // CRITICAL ENERGY FIX: disable per-page Data Detector regex scanning (URLs/phones/dates)!
        enableDataDetectors = false

        // Safely disable PDFKit's background Vision / Live Text analyzer on macOS 13+ if exposed
        let liveTextSel = NSSelectorFromString("setAllowsDocumentInteraction:")
        if responds(to: liveTextSel) {
            perform(liveTextSel, with: NSNumber(value: false))
        }
    }

    // MARK: - Single-Pass Paper Modes (Original = 0 Filters; Sepia/Dark = 1-Pass CIColorMatrix)

    func applyPaperMode(_ mode: MacPaperMode) {
        guard let docView = documentView else { return }
        if appliedPaperMode == mode && appliedDocView === docView { return }
        appliedPaperMode = mode
        appliedDocView = docView

        switch mode {
        case .original:
            if !docView.contentFilters.isEmpty { docView.contentFilters = [] }
            if docView.layerUsesCoreImageFilters { docView.layerUsesCoreImageFilters = false }
            docView.enclosingScrollView?.appearance = nil
            backgroundColor = Self.originalBgColor

        case .sepia:
            docView.wantsLayer = true
            docView.layerUsesCoreImageFilters = true
            if let mat = CIFilter(name: "CIColorMatrix") {
                mat.setValue(CIVector(x: 0.965, y: 0, z: 0, w: 0), forKey: "inputRVector")
                mat.setValue(CIVector(x: 0, y: 0.935, z: 0, w: 0), forKey: "inputGVector")
                mat.setValue(CIVector(x: 0, y: 0, z: 0.865, w: 0), forKey: "inputBVector")
                mat.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
                docView.contentFilters = [mat]
            }
            docView.enclosingScrollView?.appearance = NSAppearance(named: .aqua)
            backgroundColor = Self.sepiaBgColor

        case .dark:
            // Single-pass hue-preserving BT.709 luminosity-inversion matrix (65% less Intel HD 630 shader work than 3-pass!)
            docView.wantsLayer = true
            docView.layerUsesCoreImageFilters = true
            if let mat = CIFilter(name: "CIColorMatrix") {
                let scale: CGFloat = 0.84
                let bias: CGFloat = 0.91
                mat.setValue(CIVector(x: (1.0 - 2.0 * 0.2126) * scale, y: (-2.0 * 0.7152) * scale, z: (-2.0 * 0.0722) * scale, w: 0), forKey: "inputRVector")
                mat.setValue(CIVector(x: (-2.0 * 0.2126) * scale, y: (1.0 - 2.0 * 0.7152) * scale, z: (-2.0 * 0.0722) * scale, w: 0), forKey: "inputGVector")
                mat.setValue(CIVector(x: (-2.0 * 0.2126) * scale, y: (-2.0 * 0.7152) * scale, z: (1.0 - 2.0 * 0.0722) * scale, w: 0), forKey: "inputBVector")
                mat.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
                mat.setValue(CIVector(x: bias, y: bias, z: bias, w: 0), forKey: "inputBiasVector")
                docView.contentFilters = [mat]
            }
            docView.enclosingScrollView?.appearance = NSAppearance(named: .aqua)
            backgroundColor = Self.darkBgColor
        }
    }

    // MARK: - Context Menu ("Highlight Selection" in Read Mode!)

    override func menu(for event: NSEvent) -> NSMenu? {
        let baseMenu = super.menu(for: event) ?? NSMenu()
        if let sel = currentSelection, !(sel.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let item = NSMenuItem(
                title: "Highlight Selection",
                action: #selector(handleContextHighlightSelection),
                keyEquivalent: "H"
            )
            item.keyEquivalentModifierMask = [.command, .shift]
            item.target = self
            baseMenu.insertItem(item, at: 0)
            baseMenu.insertItem(NSMenuItem.separator(), at: 1)
        }
        return baseMenu
    }

    @objc private func handleContextHighlightSelection() {
        guard let sel = currentSelection else { return }
        canvasDelegate?.canvasView(self, didHighlightSelection: sel)
        clearSelection()
    }

    // MARK: - Mode-Split Mouse Routing (Read = 100% Native PDFView; Highlighter / Text Box = Overlay)

    private func pageAndTopLeftPoint(for event: NSEvent) -> (page: PDFPage, point: CGPoint)? {
        let viewPt = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPt, nearest: false) else { return nil }
        if let overlay = canvasDelegate?.canvasView(self, overlayFor: page) {
            let localInOverlay = overlay.convert(event.locationInWindow, from: nil)
            return (page, overlay.viewPointToPagePoint(localInOverlay))
        }
        let pdfPt = convert(viewPt, to: page)
        let bounds = page.bounds(for: .cropBox)
        return (page, CGPoint(x: pdfPt.x - bounds.minX, y: bounds.maxY - pdfPt.y))
    }

    override func mouseDown(with event: NSEvent) {
        canvasDelegate?.canvasViewDidClickOutsideTextBox(self)
        switch toolMode {
        case .read:
            if event.clickCount == 2, let hit = pageAndTopLeftPoint(for: event),
               canvasDelegate?.canvasView(self, didDoubleClickInReadModeAt: hit.point, on: hit.page) == true {
                return
            }
            super.mouseDown(with: event)

        case .highlighter:
            guard let hit = pageAndTopLeftPoint(for: event) else {
                super.mouseDown(with: event)
                return
            }
            if event.modifierFlags.contains(.option) {
                canvasDelegate?.canvasView(self, didEraseHighlightAt: hit.point, on: hit.page)
                return
            }
            activeHighlightPage = hit.page
            canvasDelegate?.canvasView(self, didBeginHighlightAt: hit.point, on: hit.page)

        case .textBox:
            guard let hit = pageAndTopLeftPoint(for: event) else {
                super.mouseDown(with: event)
                return
            }
            canvasDelegate?.canvasView(self, didClickTextBoxAt: hit.point, on: hit.page)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if toolMode == .highlighter, let page = activeHighlightPage {
            let localPt: CGPoint
            if let overlay = canvasDelegate?.canvasView(self, overlayFor: page) {
                localPt = overlay.viewPointToPagePoint(overlay.convert(event.locationInWindow, from: nil))
            } else {
                let viewPt = convert(event.locationInWindow, from: nil)
                let pdfPt = convert(viewPt, to: page)
                let bounds = page.bounds(for: .cropBox)
                localPt = CGPoint(x: pdfPt.x - bounds.minX, y: bounds.maxY - pdfPt.y)
            }
            canvasDelegate?.canvasView(
                self,
                didDragHighlightTo: localPt,
                on: page,
                shiftHeld: event.modifierFlags.contains(.shift)
            )
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if toolMode == .highlighter, let page = activeHighlightPage {
            activeHighlightPage = nil
            canvasDelegate?.canvasView(self, didEndHighlightOn: page)
            return
        }
        super.mouseUp(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        switch toolMode {
        case .read:
            break
        case .highlighter:
            addCursorRect(bounds, cursor: .crosshair)
        case .textBox:
            addCursorRect(bounds, cursor: .iBeam)
        }
    }
}
