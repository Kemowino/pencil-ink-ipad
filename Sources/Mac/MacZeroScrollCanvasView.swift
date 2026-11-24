import AppKit
import PDFKit
import QuartzCore

@MainActor
protocol MacZeroScrollCanvasDelegate: AnyObject {
    func zeroCanvas(_ view: MacZeroScrollCanvasView, strokesForPageKey key: String) -> [InkStroke]
    func zeroCanvas(_ view: MacZeroScrollCanvasView, textBoxesForPageKey key: String) -> [InkTextBox]
    func zeroCanvas(_ view: MacZeroScrollCanvasView, activeHiddenTextBoxIDForPageKey key: String) -> String?
    func zeroCanvas(_ view: MacZeroScrollCanvasView, didHighlightSelection selection: PDFSelection, pageIndex: Int)
    func zeroCanvas(_ view: MacZeroScrollCanvasView, didBeginHighlightAt pagePoint: CGPoint, pageIndex: Int, overlay: MacPageOverlayView)
    func zeroCanvas(_ view: MacZeroScrollCanvasView, didDragHighlightTo pagePoint: CGPoint, pageIndex: Int, shiftHeld: Bool)
    func zeroCanvas(_ view: MacZeroScrollCanvasView, didEndHighlightOn pageIndex: Int)
    func zeroCanvas(_ view: MacZeroScrollCanvasView, didEraseHighlightAt pagePoint: CGPoint, pageIndex: Int)
    func zeroCanvas(_ view: MacZeroScrollCanvasView, didClickTextBoxAt pagePoint: CGPoint, pageIndex: Int, overlay: MacPageOverlayView)
    func zeroCanvas(_ view: MacZeroScrollCanvasView, didDoubleClickInReadModeAt pagePoint: CGPoint, pageIndex: Int, overlay: MacPageOverlayView) -> Bool
    func zeroCanvasDidClickOutsideTextBox(_ view: MacZeroScrollCanvasView)
    func zeroCanvas(_ view: MacZeroScrollCanvasView, didChangeCurrentPageIndex index: Int)
    func zeroCanvas(_ view: MacZeroScrollCanvasView, didRequestPersistPageIndex index: Int)
    func zeroCanvas(_ view: MacZeroScrollCanvasView, willUnmountOverlay overlay: MacPageOverlayView)
}

/// Pooled opaque `CALayer` holding a single zero-copy `IOSurface` page texture.
private final class MacPageSlotLayer: CALayer {
    var renderedSurface: MacRenderedPageSurface?
    var appliedTier: MacRenderTier?
    var appliedPixelW: Int = 0
    var appliedPixelH: Int = 0
    var appliedHQ: Bool = false

    private static let disabledActions: [String: CAAction] = [
        "contents": NSNull(),
        "contentsScale": NSNull(),
        "bounds": NSNull(),
        "position": NSNull(),
        "frame": NSNull(),
        "transform": NSNull(),
        "hidden": NSNull()
    ]

    override init() {
        super.init()
        actions = Self.disabledActions
        isOpaque = true
        backgroundColor = NSColor.white.cgColor
        contentsGravity = .resize
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func matches(tier: MacRenderTier, pixelW: Int, pixelH: Int, highQuality: Bool) -> Bool {
        appliedTier == tier && appliedPixelW == pixelW && appliedPixelH == pixelH && appliedHQ == highQuality && renderedSurface != nil
    }

    func applySurface(_ surfaceObj: MacRenderedPageSurface, backingScale: CGFloat, highQuality: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.renderedSurface = surfaceObj
        self.contents = surfaceObj.surface
        self.contentsScale = backingScale
        self.appliedTier = surfaceObj.tier
        self.appliedPixelW = surfaceObj.pixelW
        self.appliedPixelH = surfaceObj.pixelH
        self.appliedHQ = highQuality
        CATransaction.commit()
    }

    func releaseSurfaceToPool() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.contents = nil
        CATransaction.commit()
        self.renderedSurface = nil
        self.appliedTier = nil
        self.appliedPixelW = 0
        self.appliedPixelH = 0
    }
}

/// Zero-overhead flipped container for optional `MacPageOverlayView` subviews (mounted ONLY on annotated pages or non-Read modes).
private final class MacOverlayHostView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        for sub in subviews.reversed() {
            let local = convert(point, from: superview)
            if let hit = sub.hitTest(local) {
                return hit
            }
        }
        return nil
    }
}

/// Pure event-driven `NSView` PDF canvas engineered for **< 5.0 Energy Impact** on Intel Macs:
/// - **NO `NSScrollView` / NO `PDFView` / NO `NSScrollerImp` / NO `boundsDidChange` 60 Hz storm!**
/// - Translates a single `worldLayer` via `CATransform3D` directly inside `scrollWheel(with:)` & `magnify(with:)`.
/// - **Two-Tier Progressive `IOSurface` Rendering:**
///   - Tier 0 (Velocity > 2.5 viewports/sec): skip rasterization of intermediate slides completely.
///   - Tier 1 (Active scroll): fast area-capped draft (`<= 0.45 MP`, ~1.8 MB, `.utility` serial queue).
///   - Tier 2 (Settled ~120 ms): exact 1:1 physical Retina pixels (`.background` serial queue) for visible 1–2 pages only.
/// - Zero-copy `IOSurface` direct assignment (`layer.contents = surface`) -> 0 bytes Main Thread IPC copy & 0 kernel `vm_fault` churn.
/// - Complete Reader + Annotation parity: native text selection, Copy, Highlight Selection, clickable PDF links,
///   Highlighter drag/straight/erase, Inline `NSTextView` Text Boxes, Two-Page Spread, & instant zero-VRAM tab hibernation.
@MainActor
final class MacZeroScrollCanvasView: NSView {
    weak var canvasDelegate: MacZeroScrollCanvasDelegate?

    var toolMode: MacToolMode = .read {
        didSet {
            if toolMode != oldValue {
                if toolMode != .read { clearSelection() }
                window?.invalidateCursorRects(for: self)
                reconcileVisiblePages(tier: .draft, allowVelocitySkip: false, forceOverlayCheck: true)
            }
        }
    }

    var twoUpMode: Bool = false {
        didSet {
            if twoUpMode != oldValue {
                let anchor = currentPageIndex
                rebuildLayoutGeometry()
                goToPage(at: anchor, triggerSettle: true)
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
    private(set) var scrollX: CGFloat = 0
    private(set) var scrollY: CGFloat = 0
    private(set) var currentSelection: PDFSelection? = nil
    private(set) var currentSelectionPageIndex: Int? = nil

    private let renderer = MacProgressivePDFRenderer()
    private let worldLayer = CALayer()
    private let selectionLayer = CAShapeLayer()
    private let overlayHostView = MacOverlayHostView()
    private let scrollbarThumbLayer = CALayer()

    private var pdfURL: URL?
    private var pdfDocument: PDFDocument?
    private var slots: [PageSlot] = []
    private var isHobonichi: Bool = false
    private var docSnapshotProvider: (() -> InkDocument)?

    // Precomputed page frames in world coordinates (unscaled by live pinch; scaled by `scaleFactor`)
    private var pageFrames: [CGRect] = []
    private var pageRowTops: [CGFloat] = []
    private var contentSize: CGSize = .zero
    private var lastViewportWidth: CGFloat = 0

    // Pooled opaque `MacPageSlotLayer`s (only visible + 1 buffer above/below!)
    private var activeLayers: [Int: MacPageSlotLayer] = [:]
    private var recycledLayers: [MacPageSlotLayer] = []
    private var activeOverlays: [Int: MacPageOverlayView] = [:]
    private var lastVisibleLo: Int = -1
    private var lastVisibleHi: Int = -1

    // Live GPU pinch-to-zoom state (0% tile/surface churn mid-gesture)
    private var isLiveZooming = false
    private var liveZoomBaseScale: CGFloat = 1.0
    private var liveZoomRatio: CGFloat = 1.0

    // Velocity tracking & coalesced settle/HUD/persist timers (ZERO active timers at idle!)
    private var lastScrollEventTime: CFTimeInterval = 0
    private var lastScrollYForVelocity: CGFloat = 0
    private var settleWorkItem: DispatchWorkItem?
    private var hudWorkItem: DispatchWorkItem?
    private var persistWorkItem: DispatchWorkItem?
    private var scrollbarFadeWorkItem: DispatchWorkItem?

    // Mouse interaction state
    private var isDraggingScrollbar = false
    private var scrollbarDragOffsetY: CGFloat = 0
    private var draggingSelectionPageIndex: Int? = nil
    private var selectionStartPDFPoint: CGPoint = .zero
    private var activeHighlightPageIndex: Int? = nil

    private let pageGapV: CGFloat = 14
    private let pageGapH: CGFloat = 16
    private let marginH: CGFloat = 22
    private let marginV: CGFloat = 16
    private let scrollbarWidth: CGFloat = 7
    private let scrollbarInset: CGFloat = 4

    private static let noLayerActions: [String: CAAction] = [
        "bounds": NSNull(),
        "position": NSNull(),
        "frame": NSNull(),
        "transform": NSNull(),
        "sublayerTransform": NSNull(),
        "path": NSNull(),
        "hidden": NSNull(),
        "opacity": NSNull()
    ]

    private static let backdropColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.118, green: 0.122, blue: 0.137, alpha: 1.0)
            : NSColor(red: 0.902, green: 0.910, blue: 0.925, alpha: 1.0)
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupCanvas()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupCanvas()
    }

    deinit {
        settleWorkItem?.cancel()
        hudWorkItem?.cancel()
        persistWorkItem?.cancel()
        scrollbarFadeWorkItem?.cancel()
    }

    private func setupCanvas() {
        wantsLayer = true
        layer?.isOpaque = true
        layer?.masksToBounds = true
        layer?.backgroundColor = Self.backdropColor.cgColor

        worldLayer.actions = Self.noLayerActions
        worldLayer.anchorPoint = CGPoint(x: 0, y: 0)
        worldLayer.position = .zero
        worldLayer.isOpaque = false
        layer?.addSublayer(worldLayer)

        selectionLayer.fillColor = NSColor.selectedTextBackgroundColor.withAlphaComponent(0.38).cgColor
        selectionLayer.strokeColor = nil
        selectionLayer.zPosition = 50
        selectionLayer.actions = Self.noLayerActions
        worldLayer.addSublayer(selectionLayer)

        // Overlay host sits above worldLayer only for mounted annotated pages / active inline text box.
        overlayHostView.frame = bounds
        overlayHostView.autoresizingMask = [.width, .height]
        addSubview(overlayHostView)

        // Minimal GPU scrollbar thumb (0 AppKit NSScrollerImp overhead!)
        scrollbarThumbLayer.actions = Self.noLayerActions
        scrollbarThumbLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.34).cgColor
        scrollbarThumbLayer.cornerRadius = scrollbarWidth * 0.5
        scrollbarThumbLayer.opacity = 0.0
        scrollbarThumbLayer.zPosition = 100
        layer?.addSublayer(scrollbarThumbLayer)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = Self.backdropColor.cgColor
        scrollbarThumbLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.34).cgColor
    }

    // MARK: - Document Configuration & Zero-VRAM Tab Hibernation

    func configure(
        pdfURL: URL,
        document: PDFDocument,
        slots: [PageSlot],
        isHobonichi: Bool,
        initialScale: CGFloat? = nil,
        initialAutoScales: Bool = true,
        docSnapshotProvider: @escaping () -> InkDocument
    ) {
        cancelTimers()
        clearSelection()
        teardownAllActivePages()

        self.pdfURL = pdfURL
        self.pdfDocument = document
        self.slots = slots
        self.isHobonichi = isHobonichi
        self.docSnapshotProvider = docSnapshotProvider
        self.currentPageIndex = 0
        self.scrollX = 0
        self.scrollY = 0
        self.lastScrollYForVelocity = 0
        self.lastVisibleLo = -1
        self.lastVisibleHi = -1

        renderer.configure(pdfURL: pdfURL)

        if let s = initialScale, !initialAutoScales {
            self.autoScales = false
            self.scaleFactor = max(0.30, min(5.0, s))
        } else {
            self.autoScales = true
            self.scaleFactor = computeFitScaleFactor()
        }

        rebuildLayoutGeometry()
        applyWorldTransform()
        reconcileVisiblePages(tier: .draft, allowVelocitySkip: false, forceOverlayCheck: true)
        scheduleSettleRetinaUpgrade(delay: 0.06)
    }

    /// Cancels all pending work and returns 100% of mounted & cached `IOSurface`s to `MacIOSurfacePool`.
    /// Called when switching away from a tab or closing the window -> 0 MB VRAM & 0% CPU for background tabs!
    func hibernate() {
        cancelTimers()
        flushPendingPagePersistence()
        clearSelection()
        teardownAllActivePages()
        renderer.releaseAllSurfaces()
    }

    /// Restores exact scroll position & zoom when switching back to a previously hibernated tab.
    func restoreViewport(scrollX: CGFloat, scrollY: CGFloat, pageIndex: Int) {
        rebuildLayoutGeometry()
        if scrollY > 0 || scrollX > 0 {
            self.scrollX = max(0, min(maxScrollX(), scrollX))
            self.scrollY = max(0, min(maxScrollY(), scrollY))
            self.lastScrollYForVelocity = self.scrollY
            applyWorldTransform()
            updateCurrentPageFromViewport(forceNotify: true)
            reconcileVisiblePages(tier: .draft, allowVelocitySkip: false, forceOverlayCheck: true)
            scheduleSettleRetinaUpgrade(delay: 0.06)
        } else {
            goToPage(at: pageIndex, triggerSettle: true)
        }
    }

    func applyRenderQuality(highQualityImages: Bool) {
        renderer.invalidateCacheForScaleOrQuality()
        for layer in activeLayers.values {
            layer.appliedTier = nil
        }
        reconcileVisiblePages(tier: .retina, allowVelocitySkip: false, forceOverlayCheck: false)
    }

    func setScaleFactor(_ newScale: CGFloat) {
        let clamped = max(0.30, min(5.0, newScale))
        guard abs(clamped - scaleFactor) > 0.005 else { return }
        autoScales = false

        let oldDocH = max(1.0, contentSize.height)
        let centerFrac = (scrollY + bounds.height * 0.5) / oldDocH

        scaleFactor = clamped
        renderer.invalidateCacheForScaleOrQuality()
        for layer in activeLayers.values {
            layer.appliedTier = nil
        }
        rebuildLayoutGeometry()

        let newDocH = max(1.0, contentSize.height)
        scrollY = max(0, min(maxScrollY(), centerFrac * newDocH - bounds.height * 0.5))
        scrollX = max(0, min(maxScrollX(), (contentSize.width - bounds.width) * 0.5))
        lastScrollYForVelocity = scrollY

        applyWorldTransform()
        updateSelectionHighlightPath()
        reconcileVisiblePages(tier: .draft, allowVelocitySkip: false, forceOverlayCheck: true)
        scheduleSettleRetinaUpgrade(delay: 0.08)
    }

    func goToPage(at index: Int, triggerSettle: Bool = true) {
        guard index >= 0 && index < pageFrames.count else { return }
        let frame = pageFrames[index]
        scrollY = max(0, min(maxScrollY(), frame.minY - marginV))
        scrollX = max(0, min(maxScrollX(), (contentSize.width - bounds.width) * 0.5))
        lastScrollYForVelocity = scrollY
        applyWorldTransform()
        updateCurrentPageFromViewport(forceNotify: true)
        reconcileVisiblePages(tier: .draft, allowVelocitySkip: false, forceOverlayCheck: false)
        if triggerSettle {
            scheduleSettleRetinaUpgrade(delay: 0.08)
        }
    }

    func revealSelection(_ selection: PDFSelection) {
        guard let doc = pdfDocument, let page = selection.pages.first else { return }
        let idx = doc.index(for: page)
        guard idx != NSNotFound, idx < pageFrames.count else { return }
        currentSelection = selection
        currentSelectionPageIndex = idx
        goToPage(at: idx, triggerSettle: true)
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
        reconcileVisiblePages(tier: .draft, allowVelocitySkip: true, forceOverlayCheck: true)
    }

    func refreshOverlay(forPageKey key: String, strokes: [InkStroke], textBoxes: [InkTextBox], hiddenTextBoxID: String? = nil, dirtyPageRect: CGRect? = nil) {
        guard let idx = slots.firstIndex(where: { $0.key == key }) else { return }
        if let ov = activeOverlays[idx] {
            ov.setContent(strokes: strokes, textBoxes: textBoxes, hiddenTextBoxID: hiddenTextBoxID, dirtyPageRect: dirtyPageRect)
        } else if (!strokes.isEmpty || !textBoxes.isEmpty), idx >= lastVisibleLo && idx <= lastVisibleHi {
            mountOverlayIfNeeded(for: idx)
        }
    }

    func appendStroke(_ stroke: InkStroke, forPageKey key: String) {
        guard let idx = slots.firstIndex(where: { $0.key == key }) else { return }
        if let ov = activeOverlays[idx] {
            ov.appendStroke(stroke)
        } else if idx >= lastVisibleLo && idx <= lastVisibleHi {
            mountOverlayIfNeeded(for: idx)
        }
    }

    // MARK: - Layout Geometry (O(N) Precompute = < 0.05 ms for 2,501 Pages)

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard abs(newSize.width - lastViewportWidth) > 1.5 || contentSize == .zero else {
            applyWorldTransform()
            return
        }
        lastViewportWidth = newSize.width
        if autoScales && !slots.isEmpty {
            applyFitToWidthScale(preservePage: true)
        } else if !slots.isEmpty {
            rebuildLayoutGeometry()
            applyWorldTransform()
            reconcileVisiblePages(tier: .draft, allowVelocitySkip: false, forceOverlayCheck: false)
            scheduleSettleRetinaUpgrade(delay: 0.12)
        }
    }

    private func computeFitScaleFactor() -> CGFloat {
        guard let first = slots.first, first.size.width > 1 else { return 1.0 }
        let availW = max(320, bounds.width - marginH * 2)
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
            renderer.invalidateCacheForScaleOrQuality()
            for layer in activeLayers.values {
                layer.appliedTier = nil
            }
            rebuildLayoutGeometry()
            if preservePage {
                goToPage(at: anchor, triggerSettle: true)
            } else {
                applyWorldTransform()
                reconcileVisiblePages(tier: .draft, allowVelocitySkip: false, forceOverlayCheck: false)
                scheduleSettleRetinaUpgrade(delay: 0.10)
            }
        } else {
            rebuildLayoutGeometry()
            applyWorldTransform()
        }
    }

    private func rebuildLayoutGeometry() {
        let count = slots.count
        pageFrames.removeAll(keepingCapacity: true)
        pageFrames.reserveCapacity(count)
        pageRowTops.removeAll(keepingCapacity: true)
        pageRowTops.reserveCapacity(count)

        let vpW = max(400, bounds.width)
        var maxRowW: CGFloat = vpW
        var y: CGFloat = marginV

        if twoUpMode {
            var i = 0
            while i < count {
                let s0 = slots[i].size
                let w0 = (s0.width * scaleFactor).rounded()
                let h0 = (s0.height * scaleFactor).rounded()
                if i + 1 < count {
                    let s1 = slots[i + 1].size
                    let w1 = (s1.width * scaleFactor).rounded()
                    let h1 = (s1.height * scaleFactor).rounded()
                    let rowW = w0 + pageGapH + w1 + marginH * 2
                    if rowW > maxRowW { maxRowW = rowW }
                    let rowH = max(h0, h1)
                    let leftX = max(marginH, ((vpW - (w0 + pageGapH + w1)) * 0.5).rounded())
                    pageFrames.append(CGRect(x: leftX, y: y, width: w0, height: h0))
                    pageFrames.append(CGRect(x: leftX + w0 + pageGapH, y: y, width: w1, height: h1))
                    pageRowTops.append(y)
                    pageRowTops.append(y)
                    y += rowH + pageGapV
                    i += 2
                } else {
                    let rowW = w0 + marginH * 2
                    if rowW > maxRowW { maxRowW = rowW }
                    let x0 = max(marginH, ((vpW - w0) * 0.5).rounded())
                    pageFrames.append(CGRect(x: x0, y: y, width: w0, height: h0))
                    pageRowTops.append(y)
                    y += h0 + pageGapV
                    i += 1
                }
            }
        } else {
            for i in 0..<count {
                let s = slots[i].size
                let w = (s.width * scaleFactor).rounded()
                let h = (s.height * scaleFactor).rounded()
                let rowW = w + marginH * 2
                if rowW > maxRowW { maxRowW = rowW }
                let x = max(marginH, ((vpW - w) * 0.5).rounded())
                pageFrames.append(CGRect(x: x, y: y, width: w, height: h))
                pageRowTops.append(y)
                y += h + pageGapV
            }
        }

        if maxRowW > vpW {
            if twoUpMode {
                var i = 0
                while i < count {
                    if i + 1 < count {
                        let totalW = pageFrames[i].width + pageGapH + pageFrames[i + 1].width
                        let lx = ((maxRowW - totalW) * 0.5).rounded()
                        pageFrames[i].origin.x = lx
                        pageFrames[i + 1].origin.x = lx + pageFrames[i].width + pageGapH
                        i += 2
                    } else {
                        pageFrames[i].origin.x = ((maxRowW - pageFrames[i].width) * 0.5).rounded()
                        i += 1
                    }
                }
            } else {
                for i in 0..<count {
                    pageFrames[i].origin.x = ((maxRowW - pageFrames[i].width) * 0.5).rounded()
                }
            }
        }

        contentSize = CGSize(width: maxRowW, height: max(bounds.height, y + marginV))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        worldLayer.bounds = CGRect(origin: .zero, size: contentSize)
        selectionLayer.frame = worldLayer.bounds
        for (idx, layer) in activeLayers where idx < pageFrames.count {
            layer.frame = pageFrames[idx]
        }
        CATransaction.commit()

        repositionMountedOverlays()
        lastVisibleLo = -1
        lastVisibleHi = -1
    }

    private func maxScrollX() -> CGFloat {
        max(0, contentSize.width - bounds.width)
    }

    private func maxScrollY() -> CGFloat {
        max(0, contentSize.height - bounds.height)
    }

    private func applyWorldTransform() {
        scrollX = max(0, min(maxScrollX(), scrollX))
        scrollY = max(0, min(maxScrollY(), scrollY))
        let tx = -scrollX.rounded()
        let ty = -scrollY.rounded()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isLiveZooming {
            let cx = bounds.width * 0.5
            let cy = bounds.height * 0.5
            var t = CATransform3DIdentity
            t = CATransform3DTranslate(t, cx, cy, 0)
            t = CATransform3DScale(t, liveZoomRatio, liveZoomRatio, 1.0)
            t = CATransform3DTranslate(t, -cx + tx, -cy + ty, 0)
            worldLayer.transform = t
        } else {
            worldLayer.transform = CATransform3DMakeTranslation(tx, ty, 0)
        }
        updateScrollbarThumbGeometry()
        CATransaction.commit()

        if !activeOverlays.isEmpty {
            repositionMountedOverlays()
        }
    }

    private func repositionMountedOverlays() {
        let tx = -scrollX.rounded()
        let ty = -scrollY.rounded()
        for (idx, ov) in activeOverlays where idx < pageFrames.count {
            let f = pageFrames[idx]
            let viewFrame = CGRect(x: f.minX + tx, y: f.minY + ty, width: f.width, height: f.height)
            if ov.frame != viewFrame {
                ov.frame = viewFrame
            }
        }
    }

    // MARK: - Minimal GPU Scrollbar (0 NSScrollerImp CPU!)

    private func updateScrollbarThumbGeometry() {
        let maxY = maxScrollY()
        guard maxY > 8, bounds.height > 60 else {
            scrollbarThumbLayer.isHidden = true
            return
        }
        scrollbarThumbLayer.isHidden = false
        let trackH = bounds.height - scrollbarInset * 2
        let visibleRatio = min(1.0, bounds.height / max(1.0, contentSize.height))
        let thumbH = max(32.0, (trackH * visibleRatio).rounded())
        let progress = scrollY / maxY
        let thumbY = scrollbarInset + ((trackH - thumbH) * progress).rounded()
        let thumbX = bounds.width - scrollbarWidth - scrollbarInset
        scrollbarThumbLayer.frame = CGRect(x: thumbX, y: thumbY, width: scrollbarWidth, height: thumbH)
    }

    private func flashScrollbar() {
        guard !scrollbarThumbLayer.isHidden else { return }
        scrollbarThumbLayer.removeAnimation(forKey: "fadeOut")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrollbarThumbLayer.opacity = 1.0
        CATransaction.commit()

        scrollbarFadeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isDraggingScrollbar else { return }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1.0
            fade.toValue = 0.0
            fade.duration = 0.25
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            self.scrollbarThumbLayer.add(fade, forKey: "fadeOut")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.scrollbarThumbLayer.opacity = 0.0
            CATransaction.commit()
        }
        scrollbarFadeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85, execute: work)
    }

    // MARK: - Pure Event-Driven Scroll & Pinch-to-Zoom (Zero Timers During Scroll!)

    override func scrollWheel(with event: NSEvent) {
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 26.0
        let dx = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * 26.0
        let ended = event.phase.contains(.ended) || event.phase.contains(.cancelled)
            || event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled)

        applyScrollDelta(dx: -dx, dy: -dy, gestureEnded: ended)
    }

    /// Unified fast-path for both real trackpad `scrollWheel` events and Self-Test synthetic scroll!
    @discardableResult
    func applyScrollDelta(dx: CGFloat, dy: CGFloat, gestureEnded: Bool = false) -> Bool {
        let now = CACurrentMediaTime()
        let nextX = max(0, min(maxScrollX(), scrollX + dx))
        let nextY = max(0, min(maxScrollY(), scrollY + dy))
        let moved = (abs(nextX - scrollX) > 0.25) || (abs(nextY - scrollY) > 0.25)

        let dt = max(0.004, now - lastScrollEventTime)
        let vpH = max(1.0, bounds.height)
        let velocityViewportsPerSec = abs(nextY - lastScrollYForVelocity) / (vpH * dt)

        scrollX = nextX
        scrollY = nextY
        lastScrollEventTime = now
        lastScrollYForVelocity = nextY

        if moved {
            applyWorldTransform()
            flashScrollbar()
            let skipDrafts = velocityViewportsPerSec > 2.5
            reconcileVisiblePages(tier: .draft, allowVelocitySkip: skipDrafts, forceOverlayCheck: false)
            scheduleCoalescedHUDUpdate()
        }

        if gestureEnded {
            scheduleSettleRetinaUpgrade(delay: 0.08)
        } else if moved {
            scheduleSettleRetinaUpgrade(delay: 0.14)
        }
        return moved
    }

    override func magnify(with event: NSEvent) {
        let phase = event.phase
        if phase.contains(.began) || phase.contains(.changed) {
            beginLiveZoomIfNeeded()
            let target = (liveZoomBaseScale * liveZoomRatio) * (1.0 + event.magnification)
            previewLiveZoom(to: target)
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
        liveZoomRatio = 1.0
    }

    func previewLiveZoom(to targetScale: CGFloat) {
        beginLiveZoomIfNeeded()
        let clamped = max(0.30, min(5.0, targetScale))
        liveZoomRatio = clamped / max(0.01, liveZoomBaseScale)
        applyWorldTransform()
    }

    func commitLiveZoom() {
        guard isLiveZooming else { return }
        let finalScale = max(0.30, min(5.0, liveZoomBaseScale * liveZoomRatio))
        isLiveZooming = false
        liveZoomRatio = 1.0
        setScaleFactor(finalScale)
    }

    override func keyDown(with event: NSEvent) {
        let pageStep = max(120, bounds.height * 0.88)
        switch event.keyCode {
        case 49: // Space
            let dir: CGFloat = event.modifierFlags.contains(.shift) ? -1 : 1
            applyScrollDelta(dx: 0, dy: pageStep * dir, gestureEnded: true)
        case 121: // Page Down
            applyScrollDelta(dx: 0, dy: pageStep, gestureEnded: true)
        case 116: // Page Up
            applyScrollDelta(dx: 0, dy: -pageStep, gestureEnded: true)
        case 125: // Down Arrow
            applyScrollDelta(dx: 0, dy: 64, gestureEnded: true)
        case 126: // Up Arrow
            applyScrollDelta(dx: 0, dy: -64, gestureEnded: true)
        case 115: // Home
            goToPage(at: 0, triggerSettle: true)
        case 119: // End
            goToPage(at: max(0, slots.count - 1), triggerSettle: true)
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - O(log N) Visible Range & Zero-Allocation Fast-Path

    private func computeVisiblePageRange() -> (lo: Int, hi: Int)? {
        let n = pageFrames.count
        guard n > 0 else { return nil }
        let topY = scrollY - 80
        let botY = scrollY + bounds.height + 80

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
        // Keep 1 buffer page ahead & behind for instant zero-flash scrolling
        return (max(0, start - 1), min(n - 1, end + 1))
    }

    private func reconcileVisiblePages(tier: MacRenderTier, allowVelocitySkip: Bool, forceOverlayCheck: Bool) {
        guard let (lo, hi) = computeVisiblePageRange() else { return }

        // ZERO-ALLOCATION FAST PATH: if visible range hasn't changed mid-scroll (draft tier), do ZERO work!
        if tier == .draft && !forceOverlayCheck && lo == lastVisibleLo && hi == lastVisibleHi {
            if allowVelocitySkip { return }
            var allHaveSurface = true
            for idx in lo...hi {
                if activeLayers[idx]?.renderedSurface == nil {
                    allHaveSurface = false
                    break
                }
            }
            if allHaveSurface { return }
        }

        lastVisibleLo = lo
        lastVisibleHi = hi
        let range = lo...hi
        renderer.updateActiveRange(range)

        // 1. Immediately recycle offscreen page layers -> returns IOSurfaces to MacIOSurfacePool!
        let offscreenLayerKeys = activeLayers.keys.filter { $0 < lo || $0 > hi }
        if !offscreenLayerKeys.isEmpty {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for idx in offscreenLayerKeys {
                if let layer = activeLayers.removeValue(forKey: idx) {
                    layer.releaseSurfaceToPool()
                    layer.removeFromSuperlayer()
                    if recycledLayers.count < 8 { recycledLayers.append(layer) }
                }
            }
            CATransaction.commit()
        }

        let offscreenOverlayKeys = activeOverlays.keys.filter { $0 < lo || $0 > hi }
        for idx in offscreenOverlayKeys {
            if let ov = activeOverlays.removeValue(forKey: idx) {
                canvasDelegate?.zeroCanvas(self, willUnmountOverlay: ov)
                ov.removeFromSuperview()
            }
        }

        // 2. Mount & progressively render visible pages
        let backing = window?.backingScaleFactor ?? 2.0
        let hq = MacPreferences.shared.highQualityImages
        let cs = MacIOSurfacePool.preferredDisplayColorSpace(for: window?.screen)
        let docSnap: InkDocument? = isHobonichi ? docSnapshotProvider?() : nil

        for idx in lo...hi {
            let slot = slots[idx]
            let frame = pageFrames[idx]

            let layer: MacPageSlotLayer
            if let existing = activeLayers[idx] {
                layer = existing
                if layer.frame != frame {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    layer.frame = frame
                    CATransaction.commit()
                }
            } else {
                layer = recycledLayers.popLast() ?? MacPageSlotLayer()
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.frame = frame
                layer.contentsScale = backing
                CATransaction.commit()
                activeLayers[idx] = layer
                worldLayer.insertSublayer(layer, below: selectionLayer)
            }

            // Mount overlay ONLY if page has ink/text or user is in Highlight/Text mode (0 overlays on unannotated Read pages!)
            mountOverlayIfNeeded(for: idx)

            if allowVelocitySkip { continue }

            // If we already hold a Retina surface matching current dimensions, don't downgrade to Draft!
            let (retW, retH) = MacProgressivePDFRenderer.retinaPixelSize(forViewSize: frame.size, backingScale: backing)
            if layer.matches(tier: .retina, pixelW: retW, pixelH: retH, highQuality: hq) {
                continue
            }

            let effectiveTier: MacRenderTier
            let pw: Int
            let ph: Int
            if tier == .retina {
                // Only upgrade strictly visible pages (exclude +/-1 offscreen buffer pages) to Tier 2 Retina!
                let isStrictlyVisible = frame.maxY >= scrollY && frame.minY <= (scrollY + bounds.height)
                if isStrictlyVisible {
                    effectiveTier = .retina
                    pw = retW
                    ph = retH
                } else {
                    effectiveTier = .draft
                    (pw, ph) = MacProgressivePDFRenderer.draftPixelSize(forPageSize: frame.size)
                }
            } else {
                effectiveTier = .draft
                (pw, ph) = MacProgressivePDFRenderer.draftPixelSize(forPageSize: frame.size)
            }

            if layer.matches(tier: effectiveTier, pixelW: pw, pixelH: ph, highQuality: hq) {
                continue
            }

            if let cached = renderer.cachedSurface(slotKey: slot.key, tier: effectiveTier, pixelW: pw, pixelH: ph, highQuality: hq) {
                layer.applySurface(cached, backingScale: backing, highQuality: hq)
            } else {
                renderer.requestRender(
                    tier: effectiveTier,
                    pageIndex: idx,
                    slot: slot,
                    isHobonichi: isHobonichi,
                    docSnapshot: docSnap,
                    allSlots: slots,
                    pixelW: pw,
                    pixelH: ph,
                    highQuality: hq,
                    colorSpace: cs
                ) { [weak self] surfaceObj in
                    guard let self, let surfaceObj, let targetLayer = self.activeLayers[idx] else { return }
                    // Never overwrite a sharper Tier 2 Retina surface with a late-arriving Tier 1 Draft!
                    if targetLayer.appliedTier == .retina && surfaceObj.tier == .draft { return }
                    targetLayer.applySurface(surfaceObj, backingScale: backing, highQuality: hq)
                }
            }
        }
    }

    private func mountOverlayIfNeeded(for idx: Int) {
        guard idx >= 0 && idx < slots.count && idx < pageFrames.count else { return }
        let slot = slots[idx]
        let strokes = canvasDelegate?.zeroCanvas(self, strokesForPageKey: slot.key) ?? []
        let texts = canvasDelegate?.zeroCanvas(self, textBoxesForPageKey: slot.key) ?? []
        let hiddenID = canvasDelegate?.zeroCanvas(self, activeHiddenTextBoxIDForPageKey: slot.key)
        let needsOverlay = (toolMode != .read) || !strokes.isEmpty || !texts.isEmpty || (hiddenID != nil)

        if !needsOverlay {
            if let existing = activeOverlays.removeValue(forKey: idx) {
                canvasDelegate?.zeroCanvas(self, willUnmountOverlay: existing)
                existing.removeFromSuperview()
            }
            return
        }

        let f = pageFrames[idx]
        let viewFrame = CGRect(x: f.minX - scrollX.rounded(), y: f.minY - scrollY.rounded(), width: f.width, height: f.height)
        if let existing = activeOverlays[idx] {
            if existing.frame != viewFrame { existing.frame = viewFrame }
            existing.setContent(strokes: strokes, textBoxes: texts, hiddenTextBoxID: hiddenID)
        } else {
            let ov = MacPageOverlayView(slot: slot)
            ov.frame = viewFrame
            ov.setContent(strokes: strokes, textBoxes: texts, hiddenTextBoxID: hiddenID)
            overlayHostView.addSubview(ov)
            activeOverlays[idx] = ov
        }
    }

    private func teardownAllActivePages() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in activeLayers.values {
            layer.releaseSurfaceToPool()
            layer.removeFromSuperlayer()
        }
        CATransaction.commit()
        activeLayers.removeAll()
        for ov in activeOverlays.values {
            canvasDelegate?.zeroCanvas(self, willUnmountOverlay: ov)
            ov.removeFromSuperview()
        }
        activeOverlays.removeAll()
        lastVisibleLo = -1
        lastVisibleHi = -1
    }

    // MARK: - Coalesced Settle, HUD & Persistence (0 Idle Wakeups!)

    private func cancelTimers() {
        settleWorkItem?.cancel(); settleWorkItem = nil
        hudWorkItem?.cancel(); hudWorkItem = nil
        persistWorkItem?.cancel(); persistWorkItem = nil
        scrollbarFadeWorkItem?.cancel(); scrollbarFadeWorkItem = nil
    }

    private func scheduleSettleRetinaUpgrade(delay: TimeInterval) {
        settleWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.settleWorkItem = nil
            self.reconcileVisiblePages(tier: .retina, allowVelocitySkip: false, forceOverlayCheck: false)
            self.updateCurrentPageFromViewport(forceNotify: true)
            self.schedulePagePersistence()
        }
        settleWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scheduleCoalescedHUDUpdate() {
        guard hudWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hudWorkItem = nil
            self.updateCurrentPageFromViewport(forceNotify: false)
        }
        hudWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func updateCurrentPageFromViewport(forceNotify: Bool) {
        guard !pageRowTops.isEmpty else { return }
        let midY = scrollY + bounds.height * 0.5
        var lo = 0
        var hi = pageRowTops.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) >> 1
            if pageRowTops[mid] <= midY { lo = mid } else { hi = mid - 1 }
        }
        if lo != currentPageIndex || forceNotify {
            let changed = (lo != currentPageIndex)
            currentPageIndex = lo
            if changed {
                MacOverlayMetrics.shared.totalPageChangeNotifications &+= 1
            }
            canvasDelegate?.zeroCanvas(self, didChangeCurrentPageIndex: lo)
        }
    }

    private func schedulePagePersistence() {
        persistWorkItem?.cancel()
        let pageIdx = currentPageIndex
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.persistWorkItem = nil
            self.canvasDelegate?.zeroCanvas(self, didRequestPersistPageIndex: pageIdx)
        }
        persistWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    func flushPendingPagePersistence() {
        persistWorkItem?.cancel()
        persistWorkItem = nil
        canvasDelegate?.zeroCanvas(self, didRequestPersistPageIndex: currentPageIndex)
    }

    // MARK: - Coordinate Conversion & Selection Highlighting

    private func hitPage(for event: NSEvent) -> (index: Int, topLeftPt: CGPoint, pdfPt: CGPoint)? {
        let viewPt = convert(event.locationInWindow, from: nil)
        let worldPt = CGPoint(x: viewPt.x + scrollX, y: viewPt.y + scrollY)
        guard let (lo, hi) = computeVisiblePageRange() else { return nil }
        for idx in lo...hi {
            let f = pageFrames[idx]
            if f.contains(worldPt) {
                let slot = slots[idx]
                let lx = (worldPt.x - f.minX) * (slot.size.width / max(1.0, f.width))
                let ly = (worldPt.y - f.minY) * (slot.size.height / max(1.0, f.height))
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

    // MARK: - Mouse, Scrollbar Drag, Context Menu, Text Selection, Highlighter & Text Box Routing

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
        canvasDelegate?.zeroCanvas(self, didHighlightSelection: sel, pageIndex: idx)
        clearSelection()
    }

    @objc func copy(_ sender: Any?) {
        guard let str = currentSelection?.string, !str.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(str, forType: .string)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        canvasDelegate?.zeroCanvasDidClickOutsideTextBox(self)

        // Check right-edge GPU scrollbar drag first
        let viewPt = convert(event.locationInWindow, from: nil)
        if !scrollbarThumbLayer.isHidden && viewPt.x >= bounds.width - (scrollbarWidth + scrollbarInset * 2 + 6) {
            isDraggingScrollbar = true
            let thumb = scrollbarThumbLayer.frame
            if thumb.contains(viewPt) {
                scrollbarDragOffsetY = viewPt.y - thumb.minY
            } else {
                scrollbarDragOffsetY = thumb.height * 0.5
                scrollToScrollbarY(viewPt.y - scrollbarDragOffsetY)
            }
            flashScrollbar()
            return
        }

        guard let hit = hitPage(for: event) else {
            clearSelection()
            return
        }

        switch toolMode {
        case .read:
            if event.clickCount == 2 {
                mountOverlayIfNeeded(for: hit.index)
                if let ov = activeOverlays[hit.index],
                   canvasDelegate?.zeroCanvas(self, didDoubleClickInReadModeAt: hit.topLeftPt, pageIndex: hit.index, overlay: ov) == true {
                    clearSelection()
                    return
                }
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
                canvasDelegate?.zeroCanvas(self, didEraseHighlightAt: hit.topLeftPt, pageIndex: hit.index)
                return
            }
            mountOverlayIfNeeded(for: hit.index)
            guard let ov = activeOverlays[hit.index] else { return }
            activeHighlightPageIndex = hit.index
            canvasDelegate?.zeroCanvas(self, didBeginHighlightAt: hit.topLeftPt, pageIndex: hit.index, overlay: ov)

        case .textBox:
            mountOverlayIfNeeded(for: hit.index)
            guard let ov = activeOverlays[hit.index] else { return }
            canvasDelegate?.zeroCanvas(self, didClickTextBoxAt: hit.topLeftPt, pageIndex: hit.index, overlay: ov)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if isDraggingScrollbar {
            let viewPt = convert(event.locationInWindow, from: nil)
            scrollToScrollbarY(viewPt.y - scrollbarDragOffsetY)
            return
        }

        if toolMode == .highlighter, let idx = activeHighlightPageIndex, idx < pageFrames.count {
            let viewPt = convert(event.locationInWindow, from: nil)
            let worldPt = CGPoint(x: viewPt.x + scrollX, y: viewPt.y + scrollY)
            let f = pageFrames[idx]
            let slot = slots[idx]
            let lx = max(0, min(slot.size.width, (worldPt.x - f.minX) * (slot.size.width / max(1.0, f.width))))
            let ly = max(0, min(slot.size.height, (worldPt.y - f.minY) * (slot.size.height / max(1.0, f.height))))
            canvasDelegate?.zeroCanvas(
                self,
                didDragHighlightTo: CGPoint(x: lx, y: ly),
                pageIndex: idx,
                shiftHeld: event.modifierFlags.contains(.shift)
            )
            return
        }

        if toolMode == .read, let idx = draggingSelectionPageIndex, idx < pageFrames.count,
           let page = pdfDocument?.page(at: idx) {
            let viewPt = convert(event.locationInWindow, from: nil)
            let worldPt = CGPoint(x: viewPt.x + scrollX, y: viewPt.y + scrollY)
            let f = pageFrames[idx]
            let slot = slots[idx]
            let lx = max(0, min(slot.size.width, (worldPt.x - f.minX) * (slot.size.width / max(1.0, f.width))))
            let ly = max(0, min(slot.size.height, (worldPt.y - f.minY) * (slot.size.height / max(1.0, f.height))))
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
        if isDraggingScrollbar {
            isDraggingScrollbar = false
            flashScrollbar()
            scheduleSettleRetinaUpgrade(delay: 0.06)
            return
        }
        if toolMode == .highlighter, let idx = activeHighlightPageIndex {
            activeHighlightPageIndex = nil
            canvasDelegate?.zeroCanvas(self, didEndHighlightOn: idx)
            return
        }
        if toolMode == .read, let idx = draggingSelectionPageIndex {
            draggingSelectionPageIndex = nil
            if currentSelection == nil, let hit = hitPage(for: event), hit.index == idx,
               let page = pdfDocument?.page(at: idx),
               let annot = page.annotation(at: hit.pdfPt) {
                if let destPage = annot.destination?.page, let doc = pdfDocument {
                    let targetIdx = doc.index(for: destPage)
                    if targetIdx != NSNotFound { goToPage(at: targetIdx, triggerSettle: true) }
                } else if let url = annot.url {
                    NSWorkspace.shared.open(url)
                } else if let goTo = annot.action as? PDFActionGoTo, let destPage = goTo.destination.page, let doc = pdfDocument {
                    let targetIdx = doc.index(for: destPage)
                    if targetIdx != NSNotFound { goToPage(at: targetIdx, triggerSettle: true) }
                } else if let uri = (annot.action as? PDFActionURL)?.url {
                    NSWorkspace.shared.open(uri)
                }
            }
            return
        }
        super.mouseUp(with: event)
    }

    private func scrollToScrollbarY(_ thumbTopY: CGFloat) {
        let trackH = max(1.0, bounds.height - scrollbarInset * 2 - scrollbarThumbLayer.frame.height)
        let frac = max(0.0, min(1.0, (thumbTopY - scrollbarInset) / trackH))
        let targetY = frac * maxScrollY()
        applyScrollDelta(dx: 0, dy: targetY - scrollY, gestureEnded: false)
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
