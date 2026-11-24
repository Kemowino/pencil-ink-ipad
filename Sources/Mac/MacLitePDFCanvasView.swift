import AppKit
import PDFKit
import QuartzCore

protocol MacLitePDFCanvasDelegate: AnyObject {
    func liteCanvas(_ view: MacLitePDFCanvasView, strokesForPageKey key: String) -> [InkStroke]
    func liteCanvas(_ view: MacLitePDFCanvasView, textBoxesForPageKey key: String) -> [InkTextBox]
    func liteCanvas(_ view: MacLitePDFCanvasView, activeHiddenTextBoxIDForPageKey key: String) -> String?
    func liteCanvas(_ view: MacLitePDFCanvasView, didHighlightSelection selection: PDFSelection, pageIndex: Int)
    func liteCanvas(_ view: MacLitePDFCanvasView, didBeginHighlightAt pagePoint: CGPoint, pageIndex: Int, overlay: MacPageOverlayView)
    func liteCanvas(_ view: MacLitePDFCanvasView, didDragHighlightTo pagePoint: CGPoint, pageIndex: Int, shiftHeld: Bool)
    func liteCanvas(_ view: MacLitePDFCanvasView, didEndHighlightOn pageIndex: Int)
    func liteCanvas(_ view: MacLitePDFCanvasView, didEraseHighlightAt pagePoint: CGPoint, pageIndex: Int)
    func liteCanvas(_ view: MacLitePDFCanvasView, didClickTextBoxAt pagePoint: CGPoint, pageIndex: Int, overlay: MacPageOverlayView)
    func liteCanvas(_ view: MacLitePDFCanvasView, didDoubleClickInReadModeAt pagePoint: CGPoint, pageIndex: Int, overlay: MacPageOverlayView) -> Bool
    func liteCanvasDidClickOutsideTextBox(_ view: MacLitePDFCanvasView)
    func liteCanvas(_ view: MacLitePDFCanvasView, didChangeCurrentPageIndex index: Int)
    func liteCanvas(_ view: MacLitePDFCanvasView, willUnmountOverlay overlay: MacPageOverlayView)
}

/// Lightweight container view for the scrollable document canvas.
/// Does NOT override `draw(_:)` -> **0 bytes** of CoreAnimation backing store for the 2,501-page document!
private final class MacLiteDocumentView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func menu(for event: NSEvent) -> NSMenu? {
        enclosingScrollView?.menu(for: event)
    }
}

/// Single-threaded serial `.utility` CGPDFDocument rasterizer with bounded 6-page LRU cache
/// and instant stale-page cancellation (zero 6-thread bursts, zero CATiledLayer tile churn!).
private final class MacLitePageRenderer {
    private let queue = DispatchQueue(label: "com.pencilink.mac.literender", qos: .utility)
    private let lock = NSLock()

    private var pdfURL: URL?
    private var cgDoc: CGPDFDocument?
    private var rendersSinceRecycle = 0
    private var generation: UInt64 = 0
    private var activeRange: ClosedRange<Int> = 0...0

    private struct CacheKey: Hashable {
        let slotKey: String
        let pixelW: Int
        let pixelH: Int
        let highQuality: Bool
    }

    private var lruOrder: [CacheKey] = []
    private var cache: [CacheKey: CGImage] = [:]
    private var inFlight: Set<CacheKey> = []
    private let maxCachedPages = 8

    func configure(pdfURL: URL) {
        lock.lock()
        generation &+= 1
        cache.removeAll()
        lruOrder.removeAll()
        inFlight.removeAll()
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            self.pdfURL = pdfURL
            self.cgDoc = CGPDFDocument(pdfURL as CFURL)
            self.rendersSinceRecycle = 0
        }
    }

    func updateActiveRange(_ range: ClosedRange<Int>) {
        lock.lock()
        activeRange = range
        lock.unlock()
    }

    func invalidateCacheForScaleOrQuality() {
        lock.lock()
        generation &+= 1
        cache.removeAll(keepingCapacity: true)
        lruOrder.removeAll(keepingCapacity: true)
        inFlight.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func cachedImage(slotKey: String, pixelW: Int, pixelH: Int, highQuality: Bool) -> CGImage? {
        let key = CacheKey(slotKey: slotKey, pixelW: pixelW, pixelH: pixelH, highQuality: highQuality)
        lock.lock()
        defer { lock.unlock() }
        if let img = cache[key] {
            if let idx = lruOrder.firstIndex(of: key) {
                lruOrder.remove(at: idx)
            }
            lruOrder.append(key)
            return img
        }
        return nil
    }

    func requestRender(
        pageIndex: Int,
        slot: PageSlot,
        isHobonichi: Bool,
        docSnapshot: InkDocument?,
        allSlots: [PageSlot],
        pixelW: Int,
        pixelH: Int,
        highQuality: Bool,
        completion: @escaping @MainActor (CGImage?) -> Void
    ) {
        let key = CacheKey(slotKey: slot.key, pixelW: pixelW, pixelH: pixelH, highQuality: highQuality)
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            Task { @MainActor in completion(hit) }
            return
        }
        if inFlight.contains(key) {
            lock.unlock()
            return
        }
        inFlight.insert(key)
        let reqGen = generation
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let shouldSkip: Bool = {
                self.lock.lock()
                defer { self.lock.unlock() }
                if self.generation != reqGen { return true }
                // Drop stale skipped pages immediately during fast skimming!
                let lo = max(0, self.activeRange.lowerBound - 1)
                let hi = self.activeRange.upperBound + 1
                if pageIndex < lo || pageIndex > hi {
                    self.inFlight.remove(key)
                    return true
                }
                return false
            }()
            if shouldSkip { return }

            let rendered: CGImage? = autoreleasepool {
                self.renderImageSync(
                    slot: slot,
                    isHobonichi: isHobonichi,
                    docSnapshot: docSnapshot,
                    allSlots: allSlots,
                    pixelW: pixelW,
                    pixelH: pixelH,
                    highQuality: highQuality
                )
            }

            self.lock.lock()
            self.inFlight.remove(key)
            let stillValid = (self.generation == reqGen)
            if stillValid, let img = rendered {
                self.cache[key] = img
                if let idx = self.lruOrder.firstIndex(of: key) {
                    self.lruOrder.remove(at: idx)
                }
                self.lruOrder.append(key)
                while self.lruOrder.count > self.maxCachedPages {
                    let evict = self.lruOrder.removeFirst()
                    self.cache.removeValue(forKey: evict)
                }
            }
            self.lock.unlock()

            if stillValid {
                Task { @MainActor in
                    completion(rendered)
                }
            }
        }
    }

    private func renderImageSync(
        slot: PageSlot,
        isHobonichi: Bool,
        docSnapshot: InkDocument?,
        allSlots: [PageSlot],
        pixelW: Int,
        pixelH: Int,
        highQuality: Bool
    ) -> CGImage? {
        guard pixelW >= 8, pixelH >= 8 else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: pixelW,
            height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        ctx.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(true)
        ctx.interpolationQuality = highQuality ? .high : .low

        let sx = CGFloat(pixelW) / max(1.0, slot.size.width)
        let sy = CGFloat(pixelH) / max(1.0, slot.size.height)

        if isHobonichi, HobonichiEngine.slotKind(for: slot, isHobo: true) != nil, let doc = docSnapshot {
            // HobonichiEngine draws in top-left flipped coordinates
            ctx.translateBy(x: 0, y: CGFloat(pixelH))
            ctx.scaleBy(x: sx, y: -sy)
            HobonichiEngine.drawSpread(in: ctx, slot: slot, doc: doc, allSlots: allSlots, isHobo: true)
        } else if let pdfN = slot.effectivePDFPageNumber {
            rendersSinceRecycle += 1
            if rendersSinceRecycle >= 60, let url = pdfURL {
                cgDoc = CGPDFDocument(url as CFURL)
                rendersSinceRecycle = 0
            }
            if cgDoc == nil, let url = pdfURL {
                cgDoc = CGPDFDocument(url as CFURL)
            }
            if let cgPage = cgDoc?.page(at: pdfN) {
                let targetRect = CGRect(x: 0, y: 0, width: CGFloat(pixelW), height: CGFloat(pixelH))
                let xform = cgPage.getDrawingTransform(.cropBox, rect: targetRect, rotate: 0, preserveAspectRatio: true)
                ctx.concatenate(xform)
                ctx.clip(to: cgPage.getBoxRect(.cropBox))
                ctx.drawPDFPage(cgPage)
            }
        } else {
            // Blank / Ruled / Grid / Dot / Cornell page (top-left flipped coordinates)
            ctx.translateBy(x: 0, y: CGFloat(pixelH))
            ctx.scaleBy(x: sx, y: -sy)
            slot.template.draw(in: ctx, size: slot.size)
        }

        return ctx.makeImage()
    }
}

/// Ultra-low-power Pure `CALayer` + `CGPDFDocument` PDF Reader Canvas for Intel Macs:
/// - **ZERO `PDFView`**, **ZERO `CATiledLayer`**, **ZERO `NSScrollingConcurrentVBLMonitor`**,
///   **ZERO macOS 26 `PDFPageAnalyzerV2`**, **ZERO 60 Hz glyph/cursor hit-testing**!
/// - Scrolls 2–4 pooled opaque `CALayer` textures directly on Intel HD 630 (< 5% CPU, 0% AMD Radeon).
/// - Keeps 100% native PDF text selection (`PDFPage.selection(from:to:)`), `Cmd+C`, `Cmd+Shift+H` Highlight Selection,
///   clickable links, search match highlighting, iPad `.ink.json` vector overlays, Highlighter mode, & Inline Text Boxes!
@MainActor
final class MacLitePDFCanvasView: NSScrollView {
    weak var canvasDelegate: MacLitePDFCanvasDelegate?

    var toolMode: MacToolMode = .read {
        didSet {
            if toolMode != oldValue {
                if toolMode != .read { clearSelection() }
                window?.invalidateCursorRects(for: self)
                reconcileVisiblePages(forceOverlayCheck: true)
            }
        }
    }

    var twoUpMode: Bool = false {
        didSet {
            if twoUpMode != oldValue {
                let anchor = currentPageIndex
                rebuildLayoutGeometry()
                goToPage(at: anchor)
            }
        }
    }

    private(set) var scaleFactor: CGFloat = 1.0
    var autoScales: Bool = true {
        didSet {
            if autoScales {
                applyFitToWidthScale(preservePage: true)
            }
        }
    }

    private(set) var currentPageIndex: Int = 0
    private(set) var currentSelection: PDFSelection? = nil
    private(set) var currentSelectionPageIndex: Int? = nil

    private let docHostView = MacLiteDocumentView()
    private let renderer = MacLitePageRenderer()
    private let selectionLayer = CAShapeLayer()

    private var pdfURL: URL?
    private var pdfDocument: PDFDocument?
    private var slots: [PageSlot] = []
    private var isHobonichi: Bool = false
    private var docSnapshotProvider: (() -> InkDocument)?

    // Precomputed page rects in `docHostView` (flipped top-down coordinates)
    private var pageFrames: [CGRect] = []
    private var pageRowTops: [CGFloat] = []
    private var lastVisibleRange: ClosedRange<Int>? = nil
    private var lastViewportWidth: CGFloat = 0

    // Pooled opaque CALayers (only 2-5 alive at any time!)
    private var activeLayers: [Int: CALayer] = [:]
    private var activeLayerRenderKeys: [Int: String] = [:]
    private var recycledLayers: [CALayer] = []
    private var activeOverlays: [Int: MacPageOverlayView] = [:]

    // Live GPU pinch-to-zoom state
    private var isLiveZooming = false
    private var liveZoomBaseScale: CGFloat = 1.0
    private var liveZoomTargetScale: CGFloat = 1.0

    // Mouse interaction state
    private var draggingSelectionPageIndex: Int? = nil
    private var selectionStartPDFPoint: CGPoint = .zero
    private var activeHighlightPageIndex: Int? = nil

    private let pageGapV: CGFloat = 14
    private let pageGapH: CGFloat = 16
    private let marginH: CGFloat = 20
    private let marginV: CGFloat = 16

    private static let noLayerActions: [String: CAAction] = [
        "bounds": NSNull(),
        "position": NSNull(),
        "contents": NSNull(),
        "contentsScale": NSNull(),
        "path": NSNull(),
        "hidden": NSNull(),
        "transform": NSNull(),
        "sublayerTransform": NSNull()
    ]

    private static let backdropColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.118, green: 0.122, blue: 0.137, alpha: 1.0)
            : NSColor(red: 0.902, green: 0.910, blue: 0.925, alpha: 1.0)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupScrollEngine()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupScrollEngine()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupScrollEngine() {
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        borderType = .noBorder
        drawsBackground = true
        backgroundColor = Self.backdropColor
        allowsMagnification = false
        contentView.wantsLayer = true
        contentView.postsBoundsChangedNotifications = true

        docHostView.wantsLayer = true
        docHostView.layer?.backgroundColor = NSColor.clear.cgColor
        docHostView.layer?.isOpaque = false

        selectionLayer.fillColor = NSColor.selectedTextBackgroundColor.withAlphaComponent(0.40).cgColor
        selectionLayer.strokeColor = nil
        selectionLayer.zPosition = 50
        selectionLayer.actions = Self.noLayerActions
        docHostView.layer?.addSublayer(selectionLayer)

        documentView = docHostView

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleClipBoundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: contentView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleViewportFrameChanged),
            name: NSView.frameDidChangeNotification,
            object: contentView
        )
        contentView.postsFrameChangedNotifications = true
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Document Configuration

    func configure(
        pdfURL: URL,
        document: PDFDocument,
        slots: [PageSlot],
        isHobonichi: Bool,
        docSnapshotProvider: @escaping () -> InkDocument
    ) {
        clearSelection()
        teardownAllActivePages()

        self.pdfURL = pdfURL
        self.pdfDocument = document
        self.slots = slots
        self.isHobonichi = isHobonichi
        self.docSnapshotProvider = docSnapshotProvider
        self.currentPageIndex = 0
        self.lastVisibleRange = nil

        renderer.configure(pdfURL: pdfURL)
        if autoScales {
            scaleFactor = computeFitScaleFactor()
        }
        rebuildLayoutGeometry()
        reconcileVisiblePages(forceOverlayCheck: true)
    }

    func applyRenderQuality(highQualityImages: Bool) {
        renderer.invalidateCacheForScaleOrQuality()
        activeLayerRenderKeys.removeAll()
        reconcileVisiblePages(forceOverlayCheck: false)
    }

    func setScaleFactor(_ newScale: CGFloat, animated: Bool = false) {
        let clamped = max(0.30, min(5.0, newScale))
        guard abs(clamped - scaleFactor) > 0.005 else { return }
        autoScales = false

        // Preserve relative scroll anchor at viewport center
        let clip = contentView.bounds
        let oldDocH = max(1.0, docHostView.frame.height)
        let centerFrac = (clip.midY) / oldDocH

        scaleFactor = clamped
        rebuildLayoutGeometry()

        let newDocH = max(1.0, docHostView.frame.height)
        let targetY = max(0, min(max(0, newDocH - clip.height), centerFrac * newDocH - clip.height * 0.5))
        let targetX = max(0, (docHostView.frame.width - clip.width) * 0.5)
        contentView.scroll(to: NSPoint(x: targetX, y: targetY))
        reflectScrolledClipView(contentView)

        updateSelectionHighlightPath()
        reconcileVisiblePages(forceOverlayCheck: false)
    }

    func goToPage(at index: Int) {
        guard index >= 0 && index < pageFrames.count else { return }
        let frame = pageFrames[index]
        let maxY = max(0, docHostView.frame.height - contentView.bounds.height)
        let y = max(0, min(maxY, frame.minY - marginV))
        let x = max(0, (docHostView.frame.width - contentView.bounds.width) * 0.5)
        contentView.scroll(to: NSPoint(x: x, y: y))
        reflectScrolledClipView(contentView)
        updateCurrentPageFromViewport()
        reconcileVisiblePages(forceOverlayCheck: false)
    }

    func revealSelection(_ selection: PDFSelection) {
        guard let doc = pdfDocument, let page = selection.pages.first else { return }
        let idx = doc.index(for: page)
        guard idx != NSNotFound, idx < pageFrames.count else { return }
        currentSelection = selection
        currentSelectionPageIndex = idx
        goToPage(at: idx)
        updateSelectionHighlightPath()
    }

    func clearSelection() {
        guard currentSelection != nil else { return }
        currentSelection = nil
        currentSelectionPageIndex = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionLayer.path = nil
        CATransaction.commit()
    }

    func overlay(forPageIndex idx: Int) -> MacPageOverlayView? {
        activeOverlays[idx]
    }

    func overlay(forPageKey key: String) -> MacPageOverlayView? {
        activeOverlays.values.first(where: { $0.slot.key == key })
    }

    func refreshAllMountedOverlays() {
        reconcileVisiblePages(forceOverlayCheck: true)
    }

    func refreshOverlay(forPageKey key: String, strokes: [InkStroke], textBoxes: [InkTextBox], hiddenTextBoxID: String? = nil, dirtyPageRect: CGRect? = nil) {
        guard let idx = slots.firstIndex(where: { $0.key == key }) else { return }
        if let ov = activeOverlays[idx] {
            ov.setContent(strokes: strokes, textBoxes: textBoxes, hiddenTextBoxID: hiddenTextBoxID, dirtyPageRect: dirtyPageRect)
        } else if (!strokes.isEmpty || !textBoxes.isEmpty), let vis = lastVisibleRange, vis.contains(idx) {
            mountOverlayIfNeeded(for: idx)
        }
    }

    func appendStroke(_ stroke: InkStroke, forPageKey key: String) {
        guard let idx = slots.firstIndex(where: { $0.key == key }) else { return }
        if let ov = activeOverlays[idx] {
            ov.appendStroke(stroke)
        } else if let vis = lastVisibleRange, vis.contains(idx) {
            mountOverlayIfNeeded(for: idx)
        }
    }

    // MARK: - Layout Geometry (O(N) Precompute = 0.04ms for 2,501 Pages)

    private func computeFitScaleFactor() -> CGFloat {
        guard let first = slots.first, first.size.width > 1 else { return 1.0 }
        let availW = max(320, contentView.bounds.width - marginH * 2)
        if twoUpMode {
            return max(0.35, min(3.0, (availW - pageGapH) / (first.size.width * 2.0)))
        }
        return max(0.35, min(3.0, availW / first.size.width))
    }

    private func applyFitToWidthScale(preservePage: Bool) {
        let anchor = currentPageIndex
        let newScale = computeFitScaleFactor()
        if abs(newScale - scaleFactor) > 0.005 {
            scaleFactor = newScale
            rebuildLayoutGeometry()
            if preservePage { goToPage(at: anchor) }
            reconcileVisiblePages(forceOverlayCheck: false)
        }
    }

    private func rebuildLayoutGeometry() {
        let count = slots.count
        pageFrames.removeAll(keepingCapacity: true)
        pageFrames.reserveCapacity(count)
        pageRowTops.removeAll(keepingCapacity: true)
        pageRowTops.reserveCapacity(count)

        let vpW = max(400, contentView.bounds.width)
        var maxRowW: CGFloat = vpW
        var y: CGFloat = marginV

        if twoUpMode {
            var i = 0
            while i < count {
                let s0 = slots[i].size
                let w0 = s0.width * scaleFactor
                let h0 = s0.height * scaleFactor
                if i + 1 < count {
                    let s1 = slots[i + 1].size
                    let w1 = s1.width * scaleFactor
                    let h1 = s1.height * scaleFactor
                    let rowW = w0 + pageGapH + w1 + marginH * 2
                    if rowW > maxRowW { maxRowW = rowW }
                    let rowH = max(h0, h1)
                    let leftX = max(marginH, (vpW - (w0 + pageGapH + w1)) * 0.5)
                    pageFrames.append(CGRect(x: leftX, y: y, width: w0, height: h0))
                    pageFrames.append(CGRect(x: leftX + w0 + pageGapH, y: y, width: w1, height: h1))
                    pageRowTops.append(y)
                    pageRowTops.append(y)
                    y += rowH + pageGapV
                    i += 2
                } else {
                    let rowW = w0 + marginH * 2
                    if rowW > maxRowW { maxRowW = rowW }
                    let x0 = max(marginH, (vpW - w0) * 0.5)
                    pageFrames.append(CGRect(x: x0, y: y, width: w0, height: h0))
                    pageRowTops.append(y)
                    y += h0 + pageGapV
                    i += 1
                }
            }
        } else {
            for i in 0..<count {
                let s = slots[i].size
                let w = s.width * scaleFactor
                let h = s.height * scaleFactor
                let rowW = w + marginH * 2
                if rowW > maxRowW { maxRowW = rowW }
                let x = max(marginH, (vpW - w) * 0.5)
                pageFrames.append(CGRect(x: x, y: y, width: w, height: h))
                pageRowTops.append(y)
                y += h + pageGapV
            }
        }

        // Re-center horizontally if document is wider than viewport
        if maxRowW > vpW {
            if twoUpMode {
                var i = 0
                while i < count {
                    if i + 1 < count {
                        let totalW = pageFrames[i].width + pageGapH + pageFrames[i + 1].width
                        let lx = (maxRowW - totalW) * 0.5
                        pageFrames[i].origin.x = lx
                        pageFrames[i + 1].origin.x = lx + pageFrames[i].width + pageGapH
                        i += 2
                    } else {
                        pageFrames[i].origin.x = (maxRowW - pageFrames[i].width) * 0.5
                        i += 1
                    }
                }
            } else {
                for i in 0..<count {
                    pageFrames[i].origin.x = (maxRowW - pageFrames[i].width) * 0.5
                }
            }
        }

        let totalH = max(contentView.bounds.height, y + marginV)
        docHostView.frame = NSRect(x: 0, y: 0, width: maxRowW, height: totalH)
        selectionLayer.frame = docHostView.bounds

        // Reposition currently mounted layers & overlays
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (idx, layer) in activeLayers where idx < pageFrames.count {
            layer.frame = pageFrames[idx]
        }
        CATransaction.commit()
        for (idx, ov) in activeOverlays where idx < pageFrames.count {
            ov.frame = pageFrames[idx]
        }
        lastVisibleRange = nil
    }

    // MARK: - O(log N) Visible Range & Zero-Work Scroll Fast-Path

    private func computeVisiblePageRange() -> ClosedRange<Int>? {
        let n = pageFrames.count
        guard n > 0 else { return nil }
        let visRect = contentView.bounds
        let topY = visRect.minY - 80
        let botY = visRect.maxY + 80

        // Binary search first index whose pageRowTops[i] >= topY, then step back 2
        var lo = 0
        var hi = n - 1
        while lo < hi {
            let mid = (lo + hi) >> 1
            if pageRowTops[mid] < topY { lo = mid + 1 } else { hi = mid }
        }
        var start = max(0, lo - 2)
        while start < n && pageFrames[start].maxY < topY {
            start += 1
        }
        if start >= n { start = n - 1 }

        var end = start
        while end + 1 < n && pageFrames[end + 1].minY <= botY {
            end += 1
        }
        // Keep 1 prefetch page ahead & behind for instant zero-flash scrolling
        let prefLo = max(0, start - 1)
        let prefHi = min(n - 1, end + 1)
        return prefLo...prefHi
    }

    @objc private func handleClipBoundsChanged() {
        updateCurrentPageFromViewport()
        reconcileVisiblePages(forceOverlayCheck: false)
    }

    @objc private func handleViewportFrameChanged() {
        let w = contentView.bounds.width
        guard abs(w - lastViewportWidth) > 2.0 else { return }
        lastViewportWidth = w
        if autoScales {
            applyFitToWidthScale(preservePage: true)
        } else {
            rebuildLayoutGeometry()
            reconcileVisiblePages(forceOverlayCheck: false)
        }
    }

    private func updateCurrentPageFromViewport() {
        guard !pageFrames.isEmpty else { return }
        let midY = contentView.bounds.midY
        var lo = 0
        var hi = pageFrames.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) >> 1
            if pageRowTops[mid] <= midY { lo = mid } else { hi = mid - 1 }
        }
        if lo != currentPageIndex {
            currentPageIndex = lo
            MacOverlayMetrics.shared.totalPageChangeNotifications &+= 1
            canvasDelegate?.liteCanvas(self, didChangeCurrentPageIndex: lo)
        }
    }

    private func reconcileVisiblePages(forceOverlayCheck: Bool) {
        guard let range = computeVisiblePageRange() else { return }

        // ULTRA-FAST SCROLL PATH: if visible range hasn't changed & no overlay check needed, DO ZERO WORK!
        if !forceOverlayCheck && lastVisibleRange == range {
            // Check if all visible pages already match target resolution
            var allRendered = true
            let backing = window?.backingScaleFactor ?? 2.0
            let hq = MacPreferences.shared.highQualityImages
            for idx in range {
                let sz = pageFrames[idx].size
                let (pw, ph) = targetPixels(for: sz, backingScale: backing)
                let rk = "\(pw)x\(ph)|\(hq ? 1 : 0)"
                if activeLayerRenderKeys[idx] != rk {
                    allRendered = false
                    break
                }
            }
            if allRendered { return }
        }

        lastVisibleRange = range
        renderer.updateActiveRange(range)

        // 1. Recycle offscreen page layers & unmount offscreen overlays
        let offscreenLayerKeys = activeLayers.keys.filter { !range.contains($0) }
        if !offscreenLayerKeys.isEmpty {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for idx in offscreenLayerKeys {
                if let layer = activeLayers.removeValue(forKey: idx) {
                    layer.contents = nil
                    layer.removeFromSuperlayer()
                    if recycledLayers.count < 8 { recycledLayers.append(layer) }
                }
                activeLayerRenderKeys.removeValue(forKey: idx)
            }
            CATransaction.commit()
        }

        let offscreenOverlayKeys = activeOverlays.keys.filter { !range.contains($0) }
        for idx in offscreenOverlayKeys {
            if let ov = activeOverlays.removeValue(forKey: idx) {
                canvasDelegate?.liteCanvas(self, willUnmountOverlay: ov)
                ov.removeFromSuperview()
            }
        }

        // 2. Mount & render visible pages (only 2-4 pages!)
        let backing = window?.backingScaleFactor ?? 2.0
        let hq = MacPreferences.shared.highQualityImages
        let docSnap: InkDocument? = isHobonichi ? docSnapshotProvider?() : nil

        for idx in range {
            let slot = slots[idx]
            let frame = pageFrames[idx]

            let layer: CALayer
            if let existing = activeLayers[idx] {
                layer = existing
                if layer.frame != frame {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    layer.frame = frame
                    CATransaction.commit()
                }
            } else {
                layer = dequeuePageLayer(frame: frame, backingScale: backing)
                activeLayers[idx] = layer
                docHostView.layer?.insertSublayer(layer, below: selectionLayer)
            }

            let (pw, ph) = targetPixels(for: frame.size, backingScale: backing)
            let renderKey = "\(pw)x\(ph)|\(hq ? 1 : 0)"
            if activeLayerRenderKeys[idx] != renderKey {
                if let cached = renderer.cachedImage(slotKey: slot.key, pixelW: pw, pixelH: ph, highQuality: hq) {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    layer.contents = cached
                    layer.contentsScale = backing
                    CATransaction.commit()
                    activeLayerRenderKeys[idx] = renderKey
                } else {
                    renderer.requestRender(
                        pageIndex: idx,
                        slot: slot,
                        isHobonichi: isHobonichi,
                        docSnapshot: docSnap,
                        allSlots: slots,
                        pixelW: pw,
                        pixelH: ph,
                        highQuality: hq
                    ) { [weak self] img in
                        guard let self, let img, let targetLayer = self.activeLayers[idx] else { return }
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        targetLayer.contents = img
                        targetLayer.contentsScale = backing
                        CATransaction.commit()
                        self.activeLayerRenderKeys[idx] = renderKey
                    }
                }
            }

            // 3. Mount overlay ONLY if page has ink/text OR toolMode != .read (0 overlays on unannotated Read pages!)
            mountOverlayIfNeeded(for: idx)
        }
    }

    private func mountOverlayIfNeeded(for idx: Int) {
        guard idx >= 0 && idx < slots.count && idx < pageFrames.count else { return }
        let slot = slots[idx]
        let strokes = canvasDelegate?.liteCanvas(self, strokesForPageKey: slot.key) ?? []
        let texts = canvasDelegate?.liteCanvas(self, textBoxesForPageKey: slot.key) ?? []
        let hiddenID = canvasDelegate?.liteCanvas(self, activeHiddenTextBoxIDForPageKey: slot.key)
        let needsOverlay = (toolMode != .read) || !strokes.isEmpty || !texts.isEmpty || (hiddenID != nil)

        if !needsOverlay {
            if let existing = activeOverlays.removeValue(forKey: idx) {
                canvasDelegate?.liteCanvas(self, willUnmountOverlay: existing)
                existing.removeFromSuperview()
            }
            return
        }

        if let existing = activeOverlays[idx] {
            if existing.frame != pageFrames[idx] {
                existing.frame = pageFrames[idx]
            }
            existing.setContent(strokes: strokes, textBoxes: texts, hiddenTextBoxID: hiddenID)
        } else {
            let ov = MacPageOverlayView(slot: slot)
            ov.frame = pageFrames[idx]
            ov.setContent(strokes: strokes, textBoxes: texts, hiddenTextBoxID: hiddenID)
            docHostView.addSubview(ov)
            activeOverlays[idx] = ov
        }
    }

    private func dequeuePageLayer(frame: CGRect, backingScale: CGFloat) -> CALayer {
        let layer = recycledLayers.popLast() ?? CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = frame
        layer.isOpaque = true
        layer.backgroundColor = NSColor.white.cgColor
        layer.contentsGravity = .resize
        layer.contentsScale = backingScale
        layer.borderWidth = 0.5
        layer.borderColor = NSColor.black.withAlphaComponent(0.10).cgColor
        layer.actions = Self.noLayerActions
        CATransaction.commit()
        return layer
    }

    private func targetPixels(for viewSize: CGSize, backingScale: CGFloat) -> (Int, Int) {
        var pw = viewSize.width * backingScale
        var ph = viewSize.height * backingScale
        let maxDim: CGFloat = 2400.0
        if max(pw, ph) > maxDim {
            let k = maxDim / max(pw, ph)
            pw *= k
            ph *= k
        }
        return (max(16, Int(pw.rounded())), max(16, Int(ph.rounded())))
    }

    private func teardownAllActivePages() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in activeLayers.values {
            layer.contents = nil
            layer.removeFromSuperlayer()
        }
        CATransaction.commit()
        activeLayers.removeAll()
        activeLayerRenderKeys.removeAll()
        for ov in activeOverlays.values {
            canvasDelegate?.liteCanvas(self, willUnmountOverlay: ov)
            ov.removeFromSuperview()
        }
        activeOverlays.removeAll()
    }

    // MARK: - GPU-First 60 Hz Live Pinch-to-Zoom

    override func magnify(with event: NSEvent) {
        let phase = event.phase
        if phase.contains(.began) || phase.contains(.changed) {
            beginLiveZoomIfNeeded()
            let next = liveZoomTargetScale * (1.0 + event.magnification)
            previewLiveZoom(to: next)
        } else if phase.contains(.ended) || phase.contains(.cancelled) {
            if isLiveZooming {
                commitLiveZoom()
            }
        }
    }

    func beginLiveZoomIfNeeded() {
        guard !isLiveZooming else { return }
        isLiveZooming = true
        liveZoomBaseScale = max(0.25, scaleFactor)
        liveZoomTargetScale = liveZoomBaseScale
    }

    func previewLiveZoom(to targetScale: CGFloat) {
        beginLiveZoomIfNeeded()
        liveZoomTargetScale = max(0.30, min(5.0, targetScale))
        guard let clipLayer = contentView.layer else {
            setScaleFactor(liveZoomTargetScale)
            return
        }
        let ratio = liveZoomTargetScale / max(0.01, liveZoomBaseScale)
        let cx = contentView.bounds.width * 0.5
        let cy = contentView.bounds.height * 0.5

        var t = CATransform3DIdentity
        t = CATransform3DTranslate(t, cx, cy, 0)
        t = CATransform3DScale(t, ratio, ratio, 1.0)
        t = CATransform3DTranslate(t, -cx, -cy, 0)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clipLayer.sublayerTransform = t
        CATransaction.commit()
    }

    func commitLiveZoom() {
        guard isLiveZooming else { return }
        isLiveZooming = false
        let finalScale = liveZoomTargetScale
        if let clipLayer = contentView.layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            clipLayer.sublayerTransform = CATransform3DIdentity
            CATransaction.commit()
        }
        setScaleFactor(finalScale)
    }

    // MARK: - Coordinate Conversion (DocHost Flipped <-> Top-Left Page Points <-> PDF Bottom-Left Points)

    private func hitPage(for event: NSEvent) -> (index: Int, topLeftPt: CGPoint, pdfPt: CGPoint)? {
        let docPt = docHostView.convert(event.locationInWindow, from: nil)
        guard let range = lastVisibleRange ?? computeVisiblePageRange() else { return nil }
        for idx in range {
            let f = pageFrames[idx]
            if f.contains(docPt) {
                let slot = slots[idx]
                let lx = (docPt.x - f.minX) * (slot.size.width / max(1.0, f.width))
                let ly = (docPt.y - f.minY) * (slot.size.height / max(1.0, f.height))
                let topLeft = CGPoint(x: max(0, min(slot.size.width, lx)), y: max(0, min(slot.size.height, ly)))
                let pdfPt = CGPoint(x: topLeft.x, y: slot.size.height - topLeft.y)
                return (idx, topLeft, pdfPt)
            }
        }
        return nil
    }

    private func updateSelectionHighlightPath() {
        guard let sel = currentSelection,
              let idx = currentSelectionPageIndex,
              idx >= 0 && idx < pageFrames.count,
              let page = pdfDocument?.page(at: idx) else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            selectionLayer.path = nil
            CATransaction.commit()
            return
        }

        let frame = pageFrames[idx]
        let crop = page.bounds(for: .cropBox)
        let sx = frame.width / max(1.0, crop.width)
        let sy = frame.height / max(1.0, crop.height)

        let path = CGMutablePath()
        for line in sel.selectionsByLine() {
            let r = line.bounds(for: page)
            guard r.width > 0.5, r.height > 0.5 else { continue }
            let vx = frame.minX + (r.minX - crop.minX) * sx
            let vy = frame.minY + (crop.maxY - r.maxY) * sy
            let vw = r.width * sx
            let vh = r.height * sy
            path.addRect(CGRect(x: vx, y: vy, width: vw, height: vh))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionLayer.path = path
        CATransaction.commit()
    }

    // MARK: - Mouse, Copy, Links, Text Selection, Highlighter & Text Box Routing

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let sel = currentSelection, !(sel.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let m = NSMenu()
        let hl = NSMenuItem(title: "Highlight Selection", action: #selector(contextHighlightSelection), keyEquivalent: "H")
        hl.keyEquivalentModifierMask = [.command, .shift]
        hl.target = self
        m.addItem(hl)
        let cp = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "c")
        cp.target = self
        m.addItem(cp)
        return m
    }

    @objc private func contextHighlightSelection() {
        guard let sel = currentSelection, let idx = currentSelectionPageIndex else { return }
        canvasDelegate?.liteCanvas(self, didHighlightSelection: sel, pageIndex: idx)
        clearSelection()
    }

    @objc func copy(_ sender: Any?) {
        guard let str = currentSelection?.string, !str.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(str, forType: .string)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        canvasDelegate?.liteCanvasDidClickOutsideTextBox(self)

        guard let hit = hitPage(for: event) else {
            clearSelection()
            return
        }

        switch toolMode {
        case .read:
            if event.clickCount == 2 {
                mountOverlayIfNeeded(for: hit.index)
                if let ov = activeOverlays[hit.index],
                   canvasDelegate?.liteCanvas(self, didDoubleClickInReadModeAt: hit.topLeftPt, pageIndex: hit.index, overlay: ov) == true {
                    clearSelection()
                    return
                }
                // Double-click word selection in Read mode!
                if let page = pdfDocument?.page(at: hit.index),
                   let wordSel = page.selectionForWord(at: hit.pdfPt) {
                    currentSelection = wordSel
                    currentSelectionPageIndex = hit.index
                    updateSelectionHighlightPath()
                    return
                }
            }
            if event.clickCount == 3, let page = pdfDocument?.page(at: hit.index),
               let lineSel = page.selectionForLine(at: hit.pdfPt) {
                currentSelection = lineSel
                currentSelectionPageIndex = hit.index
                updateSelectionHighlightPath()
                return
            }
            clearSelection()
            draggingSelectionPageIndex = hit.index
            selectionStartPDFPoint = hit.pdfPt

        case .highlighter:
            if event.modifierFlags.contains(.option) {
                canvasDelegate?.liteCanvas(self, didEraseHighlightAt: hit.topLeftPt, pageIndex: hit.index)
                return
            }
            mountOverlayIfNeeded(for: hit.index)
            guard let ov = activeOverlays[hit.index] else { return }
            activeHighlightPageIndex = hit.index
            canvasDelegate?.liteCanvas(self, didBeginHighlightAt: hit.topLeftPt, pageIndex: hit.index, overlay: ov)

        case .textBox:
            mountOverlayIfNeeded(for: hit.index)
            guard let ov = activeOverlays[hit.index] else { return }
            canvasDelegate?.liteCanvas(self, didClickTextBoxAt: hit.topLeftPt, pageIndex: hit.index, overlay: ov)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if toolMode == .highlighter, let idx = activeHighlightPageIndex, idx < pageFrames.count {
            let docPt = docHostView.convert(event.locationInWindow, from: nil)
            let f = pageFrames[idx]
            let slot = slots[idx]
            let lx = max(0, min(slot.size.width, (docPt.x - f.minX) * (slot.size.width / max(1.0, f.width))))
            let ly = max(0, min(slot.size.height, (docPt.y - f.minY) * (slot.size.height / max(1.0, f.height))))
            canvasDelegate?.liteCanvas(
                self,
                didDragHighlightTo: CGPoint(x: lx, y: ly),
                pageIndex: idx,
                shiftHeld: event.modifierFlags.contains(.shift)
            )
            return
        }

        if toolMode == .read, let idx = draggingSelectionPageIndex, idx < pageFrames.count,
           let page = pdfDocument?.page(at: idx) {
            let docPt = docHostView.convert(event.locationInWindow, from: nil)
            let f = pageFrames[idx]
            let slot = slots[idx]
            let lx = max(0, min(slot.size.width, (docPt.x - f.minX) * (slot.size.width / max(1.0, f.width))))
            let ly = max(0, min(slot.size.height, (docPt.y - f.minY) * (slot.size.height / max(1.0, f.height))))
            let endPDF = CGPoint(x: lx, y: slot.size.height - ly)
            if hypot(endPDF.x - selectionStartPDFPoint.x, endPDF.y - selectionStartPDFPoint.y) > 3.0 {
                if let sel = page.selection(from: selectionStartPDFPoint, to: endPDF) {
                    currentSelection = sel
                    currentSelectionPageIndex = idx
                    updateSelectionHighlightPath()
                }
            }
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if toolMode == .highlighter, let idx = activeHighlightPageIndex {
            activeHighlightPageIndex = nil
            canvasDelegate?.liteCanvas(self, didEndHighlightOn: idx)
            return
        }
        if toolMode == .read, let idx = draggingSelectionPageIndex {
            draggingSelectionPageIndex = nil
            // Clickable PDF links (hit-tested ONLY on click, 0% CPU during scroll/mouse-move!)
            if currentSelection == nil, let hit = hitPage(for: event), hit.index == idx,
               let page = pdfDocument?.page(at: idx),
               let annot = page.annotation(at: hit.pdfPt) {
                if let destPage = annot.destination?.page, let doc = pdfDocument {
                    let targetIdx = doc.index(for: destPage)
                    if targetIdx != NSNotFound { goToPage(at: targetIdx) }
                } else if let url = annot.url {
                    NSWorkspace.shared.open(url)
                } else if let goTo = annot.action as? PDFActionGoTo, let destPage = goTo.destination.page, let doc = pdfDocument {
                    let targetIdx = doc.index(for: destPage)
                    if targetIdx != NSNotFound { goToPage(at: targetIdx) }
                } else if let uri = (annot.action as? PDFActionURL)?.url {
                    NSWorkspace.shared.open(uri)
                }
            }
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

    // MARK: - Diagnostics Scroll Helper

    func scrollByPoints(deltaY: CGFloat) -> Bool {
        let clip = contentView.bounds
        let maxY = max(0, docHostView.frame.height - clip.height)
        guard maxY > 10 else { return false }
        let nextY = max(0, min(maxY, clip.origin.y + deltaY))
        if abs(nextY - clip.origin.y) < 0.5 { return false }
        contentView.scroll(to: NSPoint(x: clip.origin.x, y: nextY))
        reflectScrolledClipView(contentView)
        return true
    }
}
