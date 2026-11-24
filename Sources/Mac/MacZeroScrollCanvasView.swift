import AppKit
import CoreVideo
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

/// Weak `@MainActor` proxy eliminating 60 Swift `Task` allocations/sec and locking GPU commits to exact VBlank!
@MainActor
private final class MacDisplayLinkProxy: NSObject {
    weak var owner: MacZeroScrollCanvasView?
    init(_ owner: MacZeroScrollCanvasView) { self.owner = owner }
    @objc func onDisplayLinkFrame() {
        owner?.handleDisplayLinkTick()
    }
}

/// Pooled opaque `CALayer` holding a single zero-copy `IOSurface` page texture.
/// Uses `anchorPoint = .zero` so scrolling is a pure 2-float `layer.position` GPU update!
private final class MacPageSlotLayer: CALayer {
    var renderedSurface: MacRenderedPageSurface?
    var appliedTier: MacRenderTier?
    var appliedPixelW: Int = 0
    var appliedPixelH: Int = 0
    var appliedHQ: Bool = false
    var appliedPaperMode: MacPaperMode = .original

    private static let disabledActions: [String: CAAction] = [
        "contents": NSNull(),
        "contentsScale": NSNull(),
        "bounds": NSNull(),
        "position": NSNull(),
        "frame": NSNull(),
        "transform": NSNull(),
        "hidden": NSNull(),
        "backgroundColor": NSNull(),
        "borderColor": NSNull()
    ]

    override init() {
        super.init()
        actions = Self.disabledActions
        anchorPoint = .zero
        isOpaque = true
        allowsEdgeAntialiasing = false
        allowsGroupOpacity = false
        backgroundColor = NSColor.white.cgColor
        borderWidth = 0.75
        borderColor = DesignTokens.nsPageBorder.cgColor
        contentsGravity = .resize
        magnificationFilter = .linear
        minificationFilter = .linear
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func matches(tier: MacRenderTier, pixelW: Int, pixelH: Int, highQuality: Bool, paperMode: MacPaperMode) -> Bool {
        appliedTier == tier && appliedPixelW == pixelW && appliedPixelH == pixelH && appliedHQ == highQuality && appliedPaperMode == paperMode && renderedSurface != nil
    }

    func applySurface(_ surfaceObj: MacRenderedPageSurface, backingScale: CGFloat, highQuality: Bool, paperMode: MacPaperMode) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.renderedSurface = surfaceObj
        self.contents = surfaceObj.surface
        self.contentsScale = backingScale
        self.appliedTier = surfaceObj.tier
        self.appliedPixelW = surfaceObj.pixelW
        self.appliedPixelH = surfaceObj.pixelH
        self.appliedHQ = highQuality
        self.appliedPaperMode = paperMode
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

/// Zero-overhead flipped container for optional `MacPageOverlayView` subviews (hidden when empty -> 0 compositing cost!).
private final class MacOverlayHostView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        for sub in subviews.reversed() {
            let local = convert(point, from: superview)
            if let hit = sub.hitTest(local) {
                return hit
            }
        }
        return nil
    }
}

/// True hardware-VSync `NSView` PDF canvas engineered for **zero ghosting** & **5–9 EI** on Intel Macs:
/// - **Hardware VSync Lock (`CADisplayLink` on macOS 14+ / `CVDisplayLink` on macOS 13):** `scrollWheel(with:)` only
///   accumulates raw deltas and wakes the display link. Commits happen **EXACTLY ONCE per display refresh (60.00 Hz)**
///   directly on `CALayer.position` — ZERO `needsLayout`, ZERO AppKit Auto Layout traversal, ZERO beat-frequency ghosting!
/// - **Zero Idle Cost:** After 2 idle VSync frames (33 ms) with no scroll delta, the display link pauses immediately
///   and hands off to a single-shot coalesced settle timer -> 0% CPU and 0 wakeups/s at idle.
/// - **Directional Rendering:** During scrolling, renders strictly visible pages + 1 page AHEAD in the scroll direction
///   (never wastes Worker CPU rasterizing offscreen pages behind you).
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
    private let pagePillView = NSView()
    private let pagePillLabel = NSTextField(labelWithString: "")
    private var lastPagePillText: String = ""

    private var pdfURL: URL?
    private var pdfDocument: PDFDocument?
    private var slots: [PageSlot] = []
    private var isHobonichi: Bool = false
    private var docSnapshotProvider: (() -> InkDocument)?

    // Precomputed page frames in document coordinates (scaled by `scaleFactor`)
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

    // Hardware VSync display link (active ONLY while scrolling/gliding -> 0% CPU at idle!)
    private var caDisplayLinkStorage: AnyObject?
    private var cvDisplayLink: CVDisplayLink?
    private var displayLinkActive = false
    private var idleVSyncFrames = 0
    private var lastDisplayTickTime: CFTimeInterval = 0

    // Accumulated deltas consumed cleanly at exact VSync phase
    private var pendingPreciseDX: CGFloat = 0
    private var pendingPreciseDY: CGFloat = 0
    private var smoothWheelRemainingY: CGFloat = 0
    private var smoothWheelRemainingX: CGFloat = 0
    private var scrollDirection: Int = 1 // +1 scrolling down, -1 scrolling up
    private var smoothedVelocityVPPerSec: CGFloat = 0
    private var lastHUDNotifyTime: CFTimeInterval = 0

    // Single-shot coalesced settle & scrollbar-fade timer (0 repeating timers, 0 idle wakeups!)
    private var settleTimer: DispatchSourceTimer?
    private var scrollbarVisible = false
    private var retinaUpgradedForCurrentStop = true

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
        "sublayers": NSNull(),
        "path": NSNull(),
        "hidden": NSNull(),
        "opacity": NSNull()
    ]

    private static let backdropColor = DesignTokens.nsCanvasBackdrop

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
        settleTimer?.cancel()
        if let link = cvDisplayLink {
            CVDisplayLinkStop(link)
        }
        if #available(macOS 14.0, *), let link = caDisplayLinkStorage as? CADisplayLink {
            link.invalidate()
        }
    }

    private func setupCanvas() {
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.isOpaque = true
        layer?.masksToBounds = true
        layer?.actions = Self.noLayerActions
        layer?.backgroundColor = Self.backdropColor.cgColor

        worldLayer.actions = Self.noLayerActions
        worldLayer.anchorPoint = .zero
        worldLayer.position = .zero
        worldLayer.bounds = bounds
        worldLayer.isOpaque = false
        layer?.addSublayer(worldLayer)

        selectionLayer.fillColor = NSColor.selectedTextBackgroundColor.withAlphaComponent(0.38).cgColor
        selectionLayer.strokeColor = nil
        selectionLayer.zPosition = 50
        selectionLayer.actions = Self.noLayerActions
        selectionLayer.isHidden = true
        worldLayer.addSublayer(selectionLayer)

        overlayHostView.frame = bounds
        overlayHostView.autoresizingMask = [.width, .height]
        overlayHostView.isHidden = true
        addSubview(overlayHostView)

        scrollbarThumbLayer.actions = Self.noLayerActions
        scrollbarThumbLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.34).cgColor
        scrollbarThumbLayer.cornerRadius = scrollbarWidth * 0.5
        scrollbarThumbLayer.opacity = 0.0
        scrollbarThumbLayer.isHidden = true
        scrollbarThumbLayer.zPosition = 100
        layer?.addSublayer(scrollbarThumbLayer)

        // Studio Craft Floating Page Pill (opaque CALayer, fades with scrollbar — 0 idle timers!)
        pagePillView.wantsLayer = true
        pagePillView.translatesAutoresizingMaskIntoConstraints = false
        pagePillView.layer?.cornerRadius = 13
        pagePillView.layer?.borderWidth = 0.8
        pagePillView.layer?.backgroundColor = DesignTokens.nsElevatedPill.cgColor
        pagePillView.layer?.borderColor = DesignTokens.nsHairline.cgColor
        pagePillView.alphaValue = 0.0
        pagePillView.isHidden = true

        pagePillLabel.translatesAutoresizingMaskIntoConstraints = false
        pagePillLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        pagePillLabel.textColor = .labelColor
        pagePillLabel.alignment = .center
        pagePillView.addSubview(pagePillLabel)
        addSubview(pagePillView)

        NSLayoutConstraint.activate([
            pagePillView.centerXAnchor.constraint(equalTo: centerXAnchor),
            pagePillView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            pagePillView.heightAnchor.constraint(equalToConstant: 26),

            pagePillLabel.leadingAnchor.constraint(equalTo: pagePillView.leadingAnchor, constant: 13),
            pagePillLabel.trailingAnchor.constraint(equalTo: pagePillView.trailingAnchor, constant: -13),
            pagePillLabel.centerYAnchor.constraint(equalTo: pagePillView.centerYAnchor)
        ])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            teardownDisplayLink()
            cancelSettleTimer()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = Self.backdropColor.cgColor
        scrollbarThumbLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.34).cgColor
        pagePillView.layer?.backgroundColor = DesignTokens.nsElevatedPill.cgColor
        pagePillView.layer?.borderColor = DesignTokens.nsHairline.cgColor
        let borderCG = DesignTokens.nsPageBorder.cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in activeLayers.values { l.borderColor = borderCG }
        CATransaction.commit()
    }

    // MARK: - Hardware VSync Display Link (Zero Ghosting, Zero Idle Wakeups!)

    private func resumeDisplayLinkIfNeeded() {
        idleVSyncFrames = 0
        guard !displayLinkActive else { return }
        guard window != nil else {
            // Fallback if offscreen during synthetic init
            handleDisplayLinkTick()
            return
        }

        if #available(macOS 14.0, *) {
            if let existing = caDisplayLinkStorage as? CADisplayLink {
                existing.isPaused = false
                displayLinkActive = true
                lastDisplayTickTime = CACurrentMediaTime()
                return
            }
            let link = self.displayLink(target: MacDisplayLinkProxy(self), selector: #selector(MacDisplayLinkProxy.onDisplayLinkFrame))
            link.add(to: .main, forMode: .common)
            caDisplayLinkStorage = link
            displayLinkActive = true
            lastDisplayTickTime = CACurrentMediaTime()
        } else {
            if let existing = cvDisplayLink {
                CVDisplayLinkStart(existing)
                displayLinkActive = true
                lastDisplayTickTime = CACurrentMediaTime()
                return
            }
            var linkOut: CVDisplayLink?
            if CVDisplayLinkCreateWithActiveCGDisplays(&linkOut) == kCVReturnSuccess, let link = linkOut {
                CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
                    DispatchQueue.main.async {
                        self?.handleDisplayLinkTick()
                    }
                    return kCVReturnSuccess
                }
                cvDisplayLink = link
                CVDisplayLinkStart(link)
                displayLinkActive = true
                lastDisplayTickTime = CACurrentMediaTime()
            } else {
                handleDisplayLinkTick()
            }
        }
    }

    private func pauseDisplayLink() {
        guard displayLinkActive else { return }
        displayLinkActive = false
        if #available(macOS 14.0, *), let link = caDisplayLinkStorage as? CADisplayLink {
            link.isPaused = true
        }
        if let link = cvDisplayLink {
            CVDisplayLinkStop(link)
        }
    }

    private func teardownDisplayLink() {
        displayLinkActive = false
        if #available(macOS 14.0, *), let link = caDisplayLinkStorage as? CADisplayLink {
            link.invalidate()
        }
        caDisplayLinkStorage = nil
        if let link = cvDisplayLink {
            CVDisplayLinkStop(link)
        }
        cvDisplayLink = nil
    }

    /// Runs at EXACT display VSync (60.00 Hz) ONLY while scrolling/coasting!
    /// Performs ZERO `needsLayout` and ZERO AppKit Auto Layout traversal — pure GPU `layer.position` commit!
    func handleDisplayLinkTick() {
        let now = CACurrentMediaTime()
        let dt = max(0.004, min(0.05, now - lastDisplayTickTime))
        lastDisplayTickTime = now

        // Consume exact precise trackpad deltas + exponential smooth glide for notched mouse wheels
        var stepX = pendingPreciseDX
        var stepY = pendingPreciseDY
        pendingPreciseDX = 0
        pendingPreciseDY = 0

        if abs(smoothWheelRemainingY) > 0.25 {
            let glideY = smoothWheelRemainingY * 0.34
            stepY += glideY
            smoothWheelRemainingY -= glideY
        } else {
            stepY += smoothWheelRemainingY
            smoothWheelRemainingY = 0
        }

        if abs(smoothWheelRemainingX) > 0.25 {
            let glideX = smoothWheelRemainingX * 0.34
            stepX += glideX
            smoothWheelRemainingX -= glideX
        } else {
            stepX += smoothWheelRemainingX
            smoothWheelRemainingX = 0
        }

        let nextX = max(0, min(maxScrollX(), scrollX + stepX))
        let nextY = max(0, min(maxScrollY(), scrollY + stepY))
        let movedX = abs(nextX - scrollX)
        let movedY = abs(nextY - scrollY)
        let moved = (movedX > 0.05) || (movedY > 0.05)

        if !moved {
            idleVSyncFrames += 1
            if idleVSyncFrames >= 2 {
                smoothedVelocityVPPerSec = 0
                pauseDisplayLink()
                schedulePostScrollRetinaUpgrade(delayMs: 360)
            }
            return
        }

        idleVSyncFrames = 0
        if movedY > 0.1 {
            scrollDirection = (nextY > scrollY) ? 1 : -1
        }
        let vpH = max(1.0, bounds.height)
        let instVP = movedY / (vpH * CGFloat(dt))
        smoothedVelocityVPPerSec = smoothedVelocityVPPerSec * 0.55 + instVP * 0.45

        scrollX = nextX
        scrollY = nextY
        retinaUpgradedForCurrentStop = false
        cancelSettleTimer()

        showScrollbarIfNeeded()
        applyViewportPositions()

        let skipDrafts = smoothedVelocityVPPerSec > 2.6
        reconcileVisiblePages(tier: .draft, allowVelocitySkip: skipDrafts, forceOverlayCheck: false)

        if (now - lastHUDNotifyTime) >= 0.20 {
            lastHUDNotifyTime = now
            updateCurrentPageFromViewport(forceNotify: false)
        }
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
        pauseDisplayLink()
        cancelSettleTimer()
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
        self.pendingPreciseDX = 0
        self.pendingPreciseDY = 0
        self.smoothWheelRemainingX = 0
        self.smoothWheelRemainingY = 0
        self.scrollDirection = 1
        self.smoothedVelocityVPPerSec = 0
        self.lastVisibleLo = -1
        self.lastVisibleHi = -1
        self.retinaUpgradedForCurrentStop = false

        renderer.configure(pdfURL: pdfURL)

        if let s = initialScale, !initialAutoScales {
            self.autoScales = false
            self.scaleFactor = max(0.30, min(5.0, s))
        } else {
            self.autoScales = true
            self.scaleFactor = computeFitScaleFactor()
        }

        rebuildLayoutGeometry()
        applyViewportPositions()
        reconcileVisiblePages(tier: .draft, allowVelocitySkip: false, forceOverlayCheck: true)
        schedulePostScrollRetinaUpgrade(delayMs: 80)
    }

    /// Cancels all pending work and returns 100% of mounted & cached `IOSurface`s to `MacIOSurfacePool`.
    func hibernate() {
        teardownDisplayLink()
        cancelSettleTimer()
        flushPendingPagePersistence()
        clearSelection()
        teardownAllActivePages()
        renderer.hibernate()
    }

    /// Restores exact scroll position & zoom when switching back to a previously hibernated tab.
    func restoreViewport(scrollX: CGFloat, scrollY: CGFloat, pageIndex: Int) {
        rebuildLayoutGeometry()
        if scrollY > 0 || scrollX > 0 {
            self.scrollX = max(0, min(maxScrollX(), scrollX))
            self.scrollY = max(0, min(maxScrollY(), scrollY))
            applyViewportPositions()
            updateCurrentPageFromViewport(forceNotify: true)
            reconcileVisiblePages(tier: .draft, allowVelocitySkip: false, forceOverlayCheck: true)
            schedulePostScrollRetinaUpgrade(delayMs: 80)
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

    func applyPaperMode(_ mode: MacPaperMode) {
        let paperCG = isHobonichi ? HobonichiEngine.creamColor.cgColor : mode.paperColor.cgColor
        let smartDark = (!isHobonichi && mode == .dark)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in activeLayers.values {
            layer.backgroundColor = paperCG
            layer.appliedTier = nil
        }
        CATransaction.commit()
        for ov in activeOverlays.values {
            ov.smartDarkInk = smartDark
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
        renderer.cancelInFlight()
        for layer in activeLayers.values {
            layer.appliedTier = nil
        }
        rebuildLayoutGeometry()

        let newDocH = max(1.0, contentSize.height)
        scrollY = max(0, min(maxScrollY(), centerFrac * newDocH - bounds.height * 0.5))
        scrollX = max(0, min(maxScrollX(), (contentSize.width - bounds.width) * 0.5))

        applyViewportPositions()
        if currentSelection != nil { updateSelectionHighlightPath() }
        reconcileVisiblePages(tier: .draft, allowVelocitySkip: false, forceOverlayCheck: true)
        schedulePostScrollRetinaUpgrade(delayMs: 100)
    }

    func goToPage(at index: Int, triggerSettle: Bool = true) {
        guard index >= 0 && index < pageFrames.count else { return }
        pauseDisplayLink()
        pendingPreciseDX = 0
        pendingPreciseDY = 0
        smoothWheelRemainingX = 0
        smoothWheelRemainingY = 0
        let frame = pageFrames[index]
        scrollY = max(0, min(maxScrollY(), frame.minY - marginV))
        scrollX = max(0, min(maxScrollX(), (contentSize.width - bounds.width) * 0.5))
        applyViewportPositions()
        updateCurrentPageFromViewport(forceNotify: true)
        reconcileVisiblePages(tier: .draft, allowVelocitySkip: false, forceOverlayCheck: false)
        if triggerSettle {
            schedulePostScrollRetinaUpgrade(delayMs: 80)
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
        selectionLayer.isHidden = true
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        worldLayer.bounds = CGRect(origin: .zero, size: newSize)
        selectionLayer.frame = worldLayer.bounds
        CATransaction.commit()

        guard abs(newSize.width - lastViewportWidth) > 1.5 || contentSize == .zero else {
            applyViewportPositions()
            return
        }
        lastViewportWidth = newSize.width
        if autoScales && !slots.isEmpty {
            applyFitToWidthScale(preservePage: true)
        } else if !slots.isEmpty {
            rebuildLayoutGeometry()
            applyViewportPositions()
            reconcileVisiblePages(tier: .draft, allowVelocitySkip: false, forceOverlayCheck: false)
            schedulePostScrollRetinaUpgrade(delayMs: 120)
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
            renderer.cancelInFlight()
            for layer in activeLayers.values {
                layer.appliedTier = nil
            }
            rebuildLayoutGeometry()
            if preservePage {
                goToPage(at: anchor, triggerSettle: true)
            } else {
                applyViewportPositions()
                reconcileVisiblePages(tier: .draft, allowVelocitySkip: false, forceOverlayCheck: false)
                schedulePostScrollRetinaUpgrade(delayMs: 100)
            }
        } else {
            rebuildLayoutGeometry()
            applyViewportPositions()
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
        worldLayer.bounds = bounds
        selectionLayer.frame = bounds
        for (idx, layer) in activeLayers where idx < pageFrames.count {
            let f = pageFrames[idx]
            layer.bounds = CGRect(origin: .zero, size: f.size)
        }
        CATransaction.commit()

        lastVisibleLo = -1
        lastVisibleHi = -1
    }

    private func maxScrollX() -> CGFloat {
        max(0, contentSize.width - bounds.width)
    }

    private func maxScrollY() -> CGFloat {
        max(0, contentSize.height - bounds.height)
    }

    private func alignedScrollOrigin() -> (x: CGFloat, y: CGFloat) {
        let backing = max(1.0, window?.backingScaleFactor ?? 2.0)
        return (
            (scrollX * backing).rounded() / backing,
            (scrollY * backing).rounded() / backing
        )
    }

    /// Updates ONLY `layer.position` (pure 2-float GPU translation, `anchorPoint = .zero`) on the 2–4 visible layers!
    private func applyViewportPositions() {
        scrollX = max(0, min(maxScrollX(), scrollX))
        scrollY = max(0, min(maxScrollY(), scrollY))
        let aligned = alignedScrollOrigin()

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if isLiveZooming {
            let cx = bounds.width * 0.5
            let cy = bounds.height * 0.5
            var t = CATransform3DIdentity
            t = CATransform3DTranslate(t, cx, cy, 0)
            t = CATransform3DScale(t, liveZoomRatio, liveZoomRatio, 1.0)
            t = CATransform3DTranslate(t, -cx, -cy, 0)
            worldLayer.transform = t
        } else if !CATransform3DIsIdentity(worldLayer.transform) {
            worldLayer.transform = CATransform3DIdentity
        }

        for (idx, layer) in activeLayers where idx < pageFrames.count {
            let f = pageFrames[idx]
            let pos = CGPoint(x: f.minX - aligned.x, y: f.minY - aligned.y)
            if layer.position != pos {
                layer.position = pos
            }
        }

        updateScrollbarThumbGeometry()
        CATransaction.commit()

        if currentSelection != nil {
            updateSelectionHighlightPath()
        }
        if !activeOverlays.isEmpty {
            repositionMountedOverlays(alignedX: aligned.x, alignedY: aligned.y)
        }
    }

    private func repositionMountedOverlays(alignedX: CGFloat, alignedY: CGFloat) {
        for (idx, ov) in activeOverlays where idx < pageFrames.count {
            let f = pageFrames[idx]
            let viewFrame = CGRect(x: f.minX - alignedX, y: f.minY - alignedY, width: f.width, height: f.height)
            if ov.frame != viewFrame {
                ov.frame = viewFrame
            }
        }
    }

    // MARK: - Minimal GPU Scrollbar (0 NSScrollerImp CPU, 0 Per-Event Animation Churn!)

    private func updateScrollbarThumbGeometry() {
        let maxY = maxScrollY()
        guard maxY > 8, bounds.height > 60 else {
            scrollbarThumbLayer.isHidden = true
            return
        }
        if scrollbarVisible && scrollbarThumbLayer.isHidden {
            scrollbarThumbLayer.isHidden = false
        }
        guard !scrollbarThumbLayer.isHidden else { return }
        let trackH = bounds.height - scrollbarInset * 2
        let visibleRatio = min(1.0, bounds.height / max(1.0, contentSize.height))
        let thumbH = max(32.0, (trackH * visibleRatio).rounded())
        let progress = scrollY / maxY
        let thumbY = scrollbarInset + ((trackH - thumbH) * progress).rounded()
        let thumbX = bounds.width - scrollbarWidth - scrollbarInset
        scrollbarThumbLayer.frame = CGRect(x: thumbX, y: thumbY, width: scrollbarWidth, height: thumbH)
    }

    private func updateFloatingPagePillText() {
        guard !slots.isEmpty else { return }
        let cur = min(slots.count, max(1, currentPageIndex + 1))
        let text = "Page \(cur) of \(slots.count)"
        if text != lastPagePillText {
            lastPagePillText = text
            pagePillLabel.stringValue = text
        }
    }

    private func showScrollbarIfNeeded() {
        guard !scrollbarVisible, maxScrollY() > 8, bounds.height > 60 else { return }
        scrollbarVisible = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrollbarThumbLayer.removeAnimation(forKey: "fadeOut")
        scrollbarThumbLayer.isHidden = false
        scrollbarThumbLayer.opacity = 1.0
        updateScrollbarThumbGeometry()
        CATransaction.commit()

        updateFloatingPagePillText()
        pagePillView.isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            pagePillView.animator().alphaValue = 0.96
        }
    }

    private func hideScrollbarSmoothly() {
        guard scrollbarVisible else { return }
        scrollbarVisible = false
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        fade.duration = 0.22
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        scrollbarThumbLayer.add(fade, forKey: "fadeOut")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrollbarThumbLayer.opacity = 0.0
        CATransaction.commit()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.26
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            pagePillView.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.scrollbarVisible else { return }
                self.pagePillView.isHidden = true
            }
        })
    }

    // MARK: - VSync-Coalesced Scroll & Pinch-to-Zoom

    override func scrollWheel(with event: NSEvent) {
        let ended = event.phase.contains(.ended) || event.phase.contains(.cancelled)
            || event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled)

        if event.hasPreciseScrollingDeltas {
            applyScrollDelta(dx: -event.scrollingDeltaX, dy: -event.scrollingDeltaY, gestureEnded: ended, smoothWheel: false)
        } else {
            // Smooth exponential glide for notched mouse wheels
            applyScrollDelta(dx: -event.scrollingDeltaX * 28.0, dy: -event.scrollingDeltaY * 28.0, gestureEnded: ended, smoothWheel: true)
        }
    }

    /// Unified hardware-VSync entry point for trackpad, mouse wheel, keyboard, & Self-Test synthetic scroll!
    @discardableResult
    func applyScrollDelta(dx: CGFloat, dy: CGFloat, gestureEnded: Bool = false, smoothWheel: Bool = false) -> Bool {
        let maxX = maxScrollX()
        let maxY = maxScrollY()
        let plannedX = scrollX + pendingPreciseDX + smoothWheelRemainingX
        let plannedY = scrollY + pendingPreciseDY + smoothWheelRemainingY
        let clampedX = max(0, min(maxX, plannedX + dx))
        let clampedY = max(0, min(maxY, plannedY + dy))
        let effDX = clampedX - plannedX
        let effDY = clampedY - plannedY
        let wouldMove = (abs(effDX) > 0.05) || (abs(effDY) > 0.05)

        if smoothWheel {
            smoothWheelRemainingX += effDX
            smoothWheelRemainingY += effDY
        } else {
            pendingPreciseDX += effDX
            pendingPreciseDY += effDY
        }

        if wouldMove {
            resumeDisplayLinkIfNeeded()
        } else {
            if (scrollY <= 0.1 && dy < 0) || (scrollY >= maxY - 0.1 && dy > 0) {
                pendingPreciseDY = 0
                smoothWheelRemainingY = 0
            }
            if gestureEnded && !displayLinkActive {
                smoothedVelocityVPPerSec = 0
                schedulePostScrollRetinaUpgrade(delayMs: 120)
            }
        }
        return wouldMove
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
        pauseDisplayLink()
        isLiveZooming = true
        liveZoomBaseScale = max(0.25, scaleFactor)
        liveZoomRatio = 1.0
    }

    func previewLiveZoom(to targetScale: CGFloat) {
        beginLiveZoomIfNeeded()
        let clamped = max(0.30, min(5.0, targetScale))
        liveZoomRatio = clamped / max(0.01, liveZoomBaseScale)
        applyViewportPositions()
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
            applyScrollDelta(dx: 0, dy: pageStep * dir, gestureEnded: true, smoothWheel: true)
        case 121: // Page Down
            applyScrollDelta(dx: 0, dy: pageStep, gestureEnded: true, smoothWheel: true)
        case 116: // Page Up
            applyScrollDelta(dx: 0, dy: -pageStep, gestureEnded: true, smoothWheel: true)
        case 125: // Down Arrow
            applyScrollDelta(dx: 0, dy: 72, gestureEnded: true, smoothWheel: true)
        case 126: // Up Arrow
            applyScrollDelta(dx: 0, dy: -72, gestureEnded: true, smoothWheel: true)
        case 115: // Home
            goToPage(at: 0, triggerSettle: true)
        case 119: // End
            goToPage(at: max(0, slots.count - 1), triggerSettle: true)
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - O(log N) Visible Range & Directional Rendering

    private func computeVisiblePageRange() -> (lo: Int, hi: Int, visLo: Int, visHi: Int)? {
        let n = pageFrames.count
        guard n > 0 else { return nil }
        let topY = scrollY
        let botY = scrollY + bounds.height

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
        return (max(0, start - 1), min(n - 1, end + 1), start, end)
    }

    private func reconcileVisiblePages(tier: MacRenderTier, allowVelocitySkip: Bool, forceOverlayCheck: Bool) {
        guard let (lo, hi, visLo, visHi) = computeVisiblePageRange() else { return }

        // ZERO-ALLOCATION FAST PATH: if visible range hasn't changed mid-scroll (draft tier), do ZERO work!
        if tier == .draft && !forceOverlayCheck && lo == lastVisibleLo && hi == lastVisibleHi {
            if allowVelocitySkip { return }
            var allVisibleHaveSurface = true
            for idx in visLo...visHi {
                if activeLayers[idx]?.renderedSurface == nil {
                    allVisibleHaveSurface = false
                    break
                }
            }
            if allVisibleHaveSurface { return }
        }

        lastVisibleLo = lo
        lastVisibleHi = hi
        renderer.updateActiveRange(lo...hi)

        // 1. Recycle offscreen page layers -> returns IOSurfaces to FIFO pool!
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

        // 2. Mount & directionally render visible pages
        let backing = max(1.0, window?.backingScaleFactor ?? 2.0)
        let aligned = alignedScrollOrigin()
        let hq = MacPreferences.shared.highQualityImages
        let paperMode = MacPreferences.shared.paperMode
        let paperBG = isHobonichi ? HobonichiEngine.creamColor.cgColor : paperMode.paperColor.cgColor
        let borderCG = DesignTokens.nsPageBorder.cgColor
        let cs = MacIOSurfacePool.preferredDisplayColorSpace(for: window?.screen)
        let docSnap: InkDocument? = isHobonichi ? docSnapshotProvider?() : nil
        let fitScale = computeFitScaleFactor()
        let isZoomedIn = scaleFactor > (fitScale * 1.15)

        // Directional prefetch: during scroll, render strictly visible pages + 1 page AHEAD (never waste CPU behind!)
        let renderLo = (tier == .retina || scrollDirection < 0) ? lo : visLo
        let renderHi = (tier == .retina || scrollDirection > 0) ? hi : visHi

        for idx in lo...hi {
            let slot = slots[idx]
            let f = pageFrames[idx]
            let pos = CGPoint(x: f.minX - aligned.x, y: f.minY - aligned.y)

            let layer: MacPageSlotLayer
            if let existing = activeLayers[idx] {
                layer = existing
                let targetBounds = CGRect(origin: .zero, size: f.size)
                if layer.bounds != targetBounds || layer.position != pos {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    layer.bounds = targetBounds
                    layer.position = pos
                    CATransaction.commit()
                }
            } else {
                layer = recycledLayers.popLast() ?? MacPageSlotLayer()
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.bounds = CGRect(origin: .zero, size: f.size)
                layer.position = pos
                layer.contentsScale = backing
                layer.backgroundColor = paperBG
                layer.borderColor = borderCG
                CATransaction.commit()
                activeLayers[idx] = layer
                worldLayer.insertSublayer(layer, below: selectionLayer)
            }

            mountOverlayIfNeeded(for: idx, alignedX: aligned.x, alignedY: aligned.y)

            if allowVelocitySkip { continue }

            let (retW, retH) = MacProgressivePDFRenderer.retinaPixelSize(
                forViewSize: f.size,
                backingScale: backing,
                isZoomedIn: isZoomedIn
            )
            if layer.matches(tier: .retina, pixelW: retW, pixelH: retH, highQuality: hq, paperMode: paperMode) {
                continue
            }

            let isStrictlyVisible = (idx >= visLo && idx <= visHi)
            let effectiveTier: MacRenderTier
            let pw: Int
            let ph: Int
            if tier == .retina && isStrictlyVisible {
                effectiveTier = .retina
                pw = retW
                ph = retH
            } else {
                effectiveTier = .draft
                (pw, ph) = MacProgressivePDFRenderer.draftPixelSize(forPageSize: f.size)
            }

            if layer.matches(tier: effectiveTier, pixelW: pw, pixelH: ph, highQuality: hq, paperMode: paperMode) {
                continue
            }

            // Always apply instant zero-CPU cache hits for ANY mounted page (including behind buffer)!
            if effectiveTier == .draft,
               let cachedRet = renderer.cachedSurface(slotKey: slot.key, tier: .retina, pixelW: retW, pixelH: retH, highQuality: hq, paperMode: paperMode) {
                layer.applySurface(cachedRet, backingScale: backing, highQuality: hq, paperMode: paperMode)
                continue
            }
            if let cached = renderer.cachedSurface(slotKey: slot.key, tier: effectiveTier, pixelW: pw, pixelH: ph, highQuality: hq, paperMode: paperMode) {
                layer.applySurface(cached, backingScale: backing, highQuality: hq, paperMode: paperMode)
                continue
            }

            // Only spend Worker CPU on strictly visible pages + directional lookahead!
            guard idx >= renderLo && idx <= renderHi else { continue }
            // Skip prefetching offscreen lookahead page during brisk scrolling (> 1.4 vp/s)
            if !isStrictlyVisible && smoothedVelocityVPPerSec > 1.4 { continue }

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
                paperMode: paperMode,
                colorSpace: cs
            ) { [weak self] surfaceObj in
                guard let self, let surfaceObj, let targetLayer = self.activeLayers[idx] else { return }
                if targetLayer.appliedTier == .retina && targetLayer.appliedPaperMode == paperMode && surfaceObj.tier == .draft { return }
                targetLayer.applySurface(surfaceObj, backingScale: backing, highQuality: hq, paperMode: paperMode)
            }
        }

        let shouldHideOverlayHost = activeOverlays.isEmpty
        if overlayHostView.isHidden != shouldHideOverlayHost {
            overlayHostView.isHidden = shouldHideOverlayHost
        }
    }

    private func mountOverlayIfNeeded(for idx: Int, alignedX: CGFloat? = nil, alignedY: CGFloat? = nil) {
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
            overlayHostView.isHidden = activeOverlays.isEmpty
            return
        }

        let ax: CGFloat
        let ay: CGFloat
        if let x = alignedX, let y = alignedY {
            ax = x; ay = y
        } else {
            let al = alignedScrollOrigin()
            ax = al.x; ay = al.y
        }

        let f = pageFrames[idx]
        let viewFrame = CGRect(x: f.minX - ax, y: f.minY - ay, width: f.width, height: f.height)
        if let existing = activeOverlays[idx] {
            if existing.frame != viewFrame { existing.frame = viewFrame }
            existing.setContent(strokes: strokes, textBoxes: texts, hiddenTextBoxID: hiddenID)
        } else {
            let ov = MacPageOverlayView(slot: slot)
            ov.smartDarkInk = (!isHobonichi && MacPreferences.shared.paperMode == .dark)
            ov.frame = viewFrame
            ov.setContent(strokes: strokes, textBoxes: texts, hiddenTextBoxID: hiddenID)
            overlayHostView.addSubview(ov)
            activeOverlays[idx] = ov
        }
        overlayHostView.isHidden = false
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
        overlayHostView.isHidden = true
        lastVisibleLo = -1
        lastVisibleHi = -1
    }

    // MARK: - Single-Shot Coalesced Settle Timer (Zero Repeating Timers, 0 Wakeups at Idle!)

    private func cancelSettleTimer() {
        settleTimer?.cancel()
        settleTimer = nil
    }

    private func schedulePostScrollRetinaUpgrade(delayMs: Int) {
        cancelSettleTimer()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .milliseconds(delayMs), leeway: .milliseconds(60))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.cancelSettleTimer()
            guard !self.displayLinkActive else { return }
            if !self.retinaUpgradedForCurrentStop {
                self.retinaUpgradedForCurrentStop = true
                self.reconcileVisiblePages(tier: .retina, allowVelocitySkip: false, forceOverlayCheck: false)
                self.updateCurrentPageFromViewport(forceNotify: true)
            }
            self.scheduleScrollbarFadeAndPersist()
        }
        settleTimer = t
        t.resume()
    }

    private func scheduleScrollbarFadeAndPersist() {
        cancelSettleTimer()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .milliseconds(550), leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.cancelSettleTimer()
            guard !self.displayLinkActive, !self.isDraggingScrollbar else { return }
            self.hideScrollbarSmoothly()
            self.canvasDelegate?.zeroCanvas(self, didRequestPersistPageIndex: self.currentPageIndex)
        }
        settleTimer = t
        t.resume()
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
            updateFloatingPagePillText()
            canvasDelegate?.zeroCanvas(self, didChangeCurrentPageIndex: lo)
        }
    }

    func flushPendingPagePersistence() {
        canvasDelegate?.zeroCanvas(self, didRequestPersistPageIndex: currentPageIndex)
    }

    // MARK: - Coordinate Conversion & Selection Highlighting

    private func hitPage(for event: NSEvent) -> (index: Int, topLeftPt: CGPoint, pdfPt: CGPoint)? {
        let viewPt = convert(event.locationInWindow, from: nil)
        let worldPt = CGPoint(x: viewPt.x + scrollX, y: viewPt.y + scrollY)
        guard let (lo, hi, _, _) = computeVisiblePageRange() else { return nil }
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
            selectionLayer.isHidden = true
            CATransaction.commit()
            return
        }

        let aligned = alignedScrollOrigin()
        let frame = pageFrames[idx]
        let crop = page.bounds(for: .cropBox)
        let sx = frame.width / max(1.0, crop.width)
        let sy = frame.height / max(1.0, crop.height)

        let path = CGMutablePath()
        for line in sel.selectionsByLine() {
            let r = line.bounds(for: page)
            guard r.width > 0.5, r.height > 0.5 else { continue }
            let vx = (frame.minX - aligned.x) + (r.minX - crop.minX) * sx
            let vy = (frame.minY - aligned.y) + (crop.maxY - r.maxY) * sy
            let vw = r.width * sx
            let vh = r.height * sy
            path.addRect(CGRect(x: vx, y: vy, width: vw, height: vh))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionLayer.isHidden = false
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

        let viewPt = convert(event.locationInWindow, from: nil)
        if maxScrollY() > 8 && viewPt.x >= bounds.width - (scrollbarWidth + scrollbarInset * 2 + 6) {
            isDraggingScrollbar = true
            cancelSettleTimer()
            showScrollbarIfNeeded()
            let thumb = scrollbarThumbLayer.frame
            if thumb.contains(viewPt) {
                scrollbarDragOffsetY = viewPt.y - thumb.minY
            } else {
                scrollbarDragOffsetY = thumb.height * 0.5
                scrollToScrollbarY(viewPt.y - scrollbarDragOffsetY)
            }
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
            schedulePostScrollRetinaUpgrade(delayMs: 80)
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
        applyScrollDelta(dx: 0, dy: targetY - scrollY, gestureEnded: false, smoothWheel: false)
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
