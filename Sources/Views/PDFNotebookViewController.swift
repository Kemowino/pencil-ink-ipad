import UIKit
import SwiftUI
import PDFKit
import QuartzCore

enum DrawingTool: String {
    case pen
    case highlighter
    case eraser
    case laser
}

enum PenStyleOption: String, CaseIterable, Identifiable {
    case ball = "ball"
    case fountain = "fountain"
    case brush = "brush"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ball: return "Ballpoint"
        case .fountain: return "Fountain"
        case .brush: return "Brush"
        }
    }
}

enum EraserModeOption: String, CaseIterable, Identifiable {
    case stroke = "stroke"
    case pixel = "pixel"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .stroke: return "Stroke"
        case .pixel: return "Pixel"
        }
    }
}

final class NotebookToolState: ObservableObject {
    @Published var tool: DrawingTool = .pen
    @Published var penStyle: PenStyleOption = .fountain { didSet { persist() } }
    @Published var penSmooth: Int = 3 { didSet { persist() } }
    @Published var penColors: [String] = ["#1c1c1e", "#007aff", "#ff3b30", "#30d158"] { didSet { persist() } }
    @Published var penColorIndex: Int = 0 { didSet { persist() } }
    @Published var penSizes: [Double] = [1.6, 2.8, 5.2] { didSet { persist() } }
    @Published var penSizeIndex: Int = 1 { didSet { persist() } }
    @Published var holdToShape: Bool = true { didSet { persist() } }

    @Published var hlColors: [String] = ["#ffde59", "#69e6a6", "#ff94af"] { didSet { persist() } }
    @Published var hlColorIndex: Int = 0 { didSet { persist() } }
    @Published var hlSizes: [Double] = [12.0, 18.0, 28.0] { didSet { persist() } }
    @Published var hlSizeIndex: Int = 1 { didSet { persist() } }
    @Published var hlStraight: Bool = false { didSet { persist() } }

    @Published var eraserMode: EraserModeOption = .stroke { didSet { persist() } }
    @Published var eraserSizes: [Double] = [10.0, 20.0, 38.0] { didSet { persist() } }
    @Published var eraserSizeIndex: Int = 1 { didSet { persist() } }
    @Published var eraseHlOnly: Bool = false { didSet { persist() } }

    @Published var laserColorHex: String = "#ff3b30" { didSet { persist() } }
    @Published var laserTrail: Bool = true { didSet { persist() } }
    let laserColors: [String] = ["#ff3b30", "#0a84ff", "#30d158", "#ff9f0a"]

    @Published var canUndo: Bool = false
    @Published var canRedo: Bool = false
    @Published var currentPage: Int = 1
    @Published var totalPages: Int = 1
    @Published var saveStatus: String = "Saved"
    @Published var toastMessage: String = ""

    private var toastWorkItem: DispatchWorkItem?
    private var loadingPrefs = false
    private let prefsKey = "pencilink.native.prefs.v2"

    var activePenColorHex: String {
        penColors[max(0, min(penColors.count - 1, penColorIndex))]
    }
    var activePenSize: Double {
        penSizes[max(0, min(penSizes.count - 1, penSizeIndex))]
    }
    var activeHlColorHex: String {
        hlColors[max(0, min(hlColors.count - 1, hlColorIndex))]
    }
    var activeHlSize: Double {
        hlSizes[max(0, min(hlSizes.count - 1, hlSizeIndex))]
    }
    var activeEraserRadius: Double {
        eraserSizes[max(0, min(eraserSizes.count - 1, eraserSizeIndex))] * 0.5
    }

    init() {
        loadPrefs()
    }

    func showToast(_ message: String) {
        DispatchQueue.main.async {
            self.toastWorkItem?.cancel()
            self.toastMessage = message
            let item = DispatchWorkItem { [weak self] in
                self?.toastMessage = ""
            }
            self.toastWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: item)
        }
    }

    private struct SavedPrefs: Codable {
        var penStyle: String
        var penSmooth: Int
        var penColors: [String]
        var penColorIndex: Int
        var penSizes: [Double]
        var penSizeIndex: Int
        var holdToShape: Bool
        var hlColors: [String]
        var hlColorIndex: Int
        var hlSizes: [Double]
        var hlSizeIndex: Int
        var hlStraight: Bool
        var eraserMode: String
        var eraserSizes: [Double]
        var eraserSizeIndex: Int
        var eraseHlOnly: Bool
        var laserColorHex: String
        var laserTrail: Bool
        var twoFingerScrollLock: Bool?
    }

    private func loadPrefs() {
        guard let data = UserDefaults.standard.data(forKey: prefsKey),
              let p = try? JSONDecoder().decode(SavedPrefs.self, from: data) else { return }
        loadingPrefs = true
        defer { loadingPrefs = false }
        penStyle = PenStyleOption(rawValue: p.penStyle) ?? .fountain
        penSmooth = max(0, min(5, p.penSmooth))
        if p.penColors.count == 4 { penColors = p.penColors }
        penColorIndex = max(0, min(penColors.count - 1, p.penColorIndex))
        if p.penSizes.count == 3 { penSizes = p.penSizes }
        penSizeIndex = max(0, min(penSizes.count - 1, p.penSizeIndex))
        holdToShape = p.holdToShape
        if p.hlColors.count == 3 { hlColors = p.hlColors }
        hlColorIndex = max(0, min(hlColors.count - 1, p.hlColorIndex))
        if p.hlSizes.count == 3 { hlSizes = p.hlSizes }
        hlSizeIndex = max(0, min(hlSizes.count - 1, p.hlSizeIndex))
        hlStraight = p.hlStraight
        eraserMode = EraserModeOption(rawValue: p.eraserMode) ?? .stroke
        if p.eraserSizes.count == 3 { eraserSizes = p.eraserSizes }
        eraserSizeIndex = max(0, min(eraserSizes.count - 1, p.eraserSizeIndex))
        eraseHlOnly = p.eraseHlOnly
        laserColorHex = p.laserColorHex
        laserTrail = p.laserTrail
    }

    private func persist() {
        guard !loadingPrefs else { return }
        let p = SavedPrefs(
            penStyle: penStyle.rawValue,
            penSmooth: penSmooth,
            penColors: penColors,
            penColorIndex: penColorIndex,
            penSizes: penSizes,
            penSizeIndex: penSizeIndex,
            holdToShape: holdToShape,
            hlColors: hlColors,
            hlColorIndex: hlColorIndex,
            hlSizes: hlSizes,
            hlSizeIndex: hlSizeIndex,
            hlStraight: hlStraight,
            eraserMode: eraserMode.rawValue,
            eraserSizes: eraserSizes,
            eraserSizeIndex: eraserSizeIndex,
            eraseHlOnly: eraseHlOnly,
            laserColorHex: laserColorHex,
            laserTrail: laserTrail,
            twoFingerScrollLock: false
        )
        if let data = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(data, forKey: prefsKey)
        }
    }
}

private struct UndoAction {
    let pageKey: String
    let added: [InkStroke]
    let removed: [InkStroke]
}

private final class DisplayLinkProxy: NSObject {
    weak var owner: PDFNotebookViewController?
    init(_ owner: PDFNotebookViewController) { self.owner = owner }
    @objc func tick() { owner?.onLaserTick() }
}

/// Custom UIScrollView that keeps `isScrollEnabled = true` permanently and cleanly
/// ignores finger pan/pinch ONLY while the stylus tip is actively writing.
private final class InkScrollView: UIScrollView {
    var isPencilWriting: (() -> Bool)?

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer || gestureRecognizer === pinchGestureRecognizer {
            if isPencilWriting?() == true {
                return false
            }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

final class PDFNotebookViewController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let pdfURL: URL
    let toolState: NotebookToolState

    private var pdfDoc: PDFDocument?
    private var inkDoc: InkDocument
    private var pageViews: [PageCanvasView] = []
    private var pageFrames: [CGRect] = []

    private let scrollView = InkScrollView()
    private let documentContainer = UIView()
    private let pencilRecognizer = PencilDrawingGestureRecognizer()

    private let renderQueue = DispatchQueue(label: "com.pencilink.pdfrender", qos: .userInitiated)
    private var renderingPages = Set<Int>()
    private var baseFitScale: CGFloat = 1.0
    private var didInitialLayout = false
    private var lastLayoutWidth: CGFloat = 0

    // Active stroke state
    private var activePageView: PageCanvasView?
    private var activePoints: [InkPoint] = []
    private var activeSmoother: OneEuroSmoother?
    private var activeStartPoint: CGPoint?
    private var activeVelPressure: CGFloat = 0.55
    private var lastPencilUpTime: CFTimeInterval = 0

    // Hold-to-Shape state
    private var holdAnchor: CGPoint?
    private var holdTimer: DispatchWorkItem?
    private var snappedShape: DetectedShape?
    private var rawPointsBeforeSnap: [InkPoint]?
    private var shapeSnapTipPoint: CGPoint?

    // Active Eraser state
    private var activeErasePageKey: String?
    private var activeEraseOriginals: [InkStroke] = []
    private var activeErasePieces: [String: InkStroke] = [:]
    private var activeEraseLastPoint: CGPoint?

    // Laser Pointer state
    private var laserPageView: PageCanvasView?
    private var laserPoints: [LaserPoint] = []
    private var laserDown = false
    private var laserDisplayLink: CADisplayLink?

    // Undo / Redo + debounced save
    private var undoStack: [UndoAction] = []
    private var redoStack: [UndoAction] = []
    private var saveWorkItem: DispatchWorkItem?
    private var isDirty = false

    private var lastPageStorageKey: String {
        "pencilink.lastpage." + pdfURL.lastPathComponent
    }

    init(pdfURL: URL, toolState: NotebookToolState) {
        self.pdfURL = pdfURL
        self.toolState = toolState
        self.inkDoc = InkDocument.load(for: pdfURL)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopLaserLoop()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.118, green: 0.122, blue: 0.141, alpha: 1.0)
        setupScrollView()
        setupTapUndoGestures()
        loadPDF()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !didInitialLayout && view.bounds.width > 0 && !pageViews.isEmpty {
            didInitialLayout = true
            lastLayoutWidth = view.bounds.width
            fitToWidth()
            let savedPage = UserDefaults.standard.integer(forKey: lastPageStorageKey)
            if savedPage > 1 && savedPage <= pageViews.count {
                jumpToPage(savedPage, animated: false)
            }
            updateVisiblePages(forceSharp: true)
        } else if didInitialLayout {
            if abs(view.bounds.width - lastLayoutWidth) > 20 {
                let keepPage = toolState.currentPage
                lastLayoutWidth = view.bounds.width
                fitToWidth()
                jumpToPage(keepPage, animated: false)
                updateVisiblePages(forceSharp: true)
            } else {
                centerContentIfNeeded()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        cancelHoldTimer()
        stopLaserLoop()
        saveNow()
    }

    private func setupScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.backgroundColor = .clear
        scrollView.delegate = self
        scrollView.isScrollEnabled = true
        scrollView.alwaysBounceVertical = true
        scrollView.minimumZoomScale = 0.5
        scrollView.maximumZoomScale = 6.0
        scrollView.bouncesZoom = true
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.isPencilWriting = { [weak self] in
            guard let self else { return false }
            return self.activePageView != nil || self.laserDown
        }

        // NATIVE UIKIT 1-FINGER SCROLL + 2-FINGER PINCH-ZOOM (Fingers ONLY; Pencil NEVER scrolls!)
        scrollView.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        scrollView.panGestureRecognizer.minimumNumberOfTouches = 1
        scrollView.panGestureRecognizer.maximumNumberOfTouches = 1
        scrollView.pinchGestureRecognizer?.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        documentContainer.backgroundColor = .clear
        documentContainer.isMultipleTouchEnabled = true
        scrollView.addSubview(documentContainer)

        // Attach hardware Pencil recognizer to scrollView (Apple Drawing App pattern)
        pencilRecognizer.pencilOnly = true
        pencilRecognizer.delegate = self
        pencilRecognizer.onPencilBegan = { [weak self] touch, event in
            self?.handlePencilBegan(touch, event: event)
        }
        pencilRecognizer.onPencilMoved = { [weak self] touch, event in
            self?.handlePencilMoved(touch, event: event)
        }
        pencilRecognizer.onPencilEnded = { [weak self] touch, event in
            self?.handlePencilEnded(touch, event: event)
        }
        pencilRecognizer.onPencilCancelled = { [weak self] touch, event in
            self?.handlePencilEnded(touch, event: event)
        }
        pencilRecognizer.onPencilReset = { [weak self] in
            self?.handlePencilResetFallback()
        }
        scrollView.addGestureRecognizer(pencilRecognizer)
    }

    private func setupTapUndoGestures() {
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.numberOfTapsRequired = 1
        twoFingerTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        twoFingerTap.cancelsTouchesInView = false
        twoFingerTap.delaysTouchesBegan = false
        twoFingerTap.delaysTouchesEnded = false
        twoFingerTap.delegate = self

        let threeFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleThreeFingerTap))
        threeFingerTap.numberOfTouchesRequired = 3
        threeFingerTap.numberOfTapsRequired = 1
        threeFingerTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        threeFingerTap.cancelsTouchesInView = false
        threeFingerTap.delaysTouchesBegan = false
        threeFingerTap.delaysTouchesEnded = false
        threeFingerTap.delegate = self

        twoFingerTap.require(toFail: threeFingerTap)
        scrollView.addGestureRecognizer(twoFingerTap)
        scrollView.addGestureRecognizer(threeFingerTap)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UITapGestureRecognizer && otherGestureRecognizer is UITapGestureRecognizer {
            return false
        }
        return true
    }

    @objc private func handleTwoFingerTap() {
        guard activePageView == nil, CACurrentMediaTime() - lastPencilUpTime > 0.16 else { return }
        if !undoStack.isEmpty {
            performUndo()
            toolState.showToast("Undo")
        }
    }

    @objc private func handleThreeFingerTap() {
        guard activePageView == nil, CACurrentMediaTime() - lastPencilUpTime > 0.16 else { return }
        if !redoStack.isEmpty {
            performRedo()
            toolState.showToast("Redo")
        }
    }

    func jumpToPage(_ pageNumber: Int, animated: Bool = true) {
        let idx = max(0, min(pageFrames.count - 1, pageNumber - 1))
        guard idx >= 0, idx < pageFrames.count else { return }
        let zoom = max(0.1, scrollView.zoomScale)
        let targetY = max(0, pageFrames[idx].minY * zoom - 72)
        let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom)
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: min(targetY, maxY)), animated: animated)
        updateCurrentPageLabel()
        updateVisiblePages(forceSharp: true)
    }

    private func loadPDF() {
        guard let doc = PDFDocument(url: pdfURL) else { return }
        pdfDoc = doc
        let count = doc.pageCount
        DispatchQueue.main.async {
            self.toolState.totalPages = max(1, count)
            self.toolState.currentPage = 1
        }

        let gap: CGFloat = 14
        let topPad: CGFloat = 80
        let bottomPad: CGFloat = 90
        var maxW: CGFloat = 595
        var sizes: [CGSize] = []
        sizes.reserveCapacity(count)
        for i in 0..<count {
            let sz = doc.page(at: i).map { PageCanvasView.normalizedPageSize(for: $0) } ?? CGSize(width: 595, height: 842)
            sizes.append(sz)
            if sz.width > maxW { maxW = sz.width }
        }

        let sidePad: CGFloat = 16
        let containerW = maxW + sidePad * 2
        var y = topPad
        pageViews.removeAll()
        pageFrames.removeAll()

        for i in 0..<count {
            let sz = sizes[i]
            let x = (containerW - sz.width) * 0.5
            let frame = CGRect(x: x, y: y, width: sz.width, height: sz.height)
            let pv = PageCanvasView(pageIndex: i, pageSize: sz)
            pv.frame = frame
            if let strokes = inkDoc.pages[pv.pageKey], !strokes.isEmpty {
                pv.setStrokes(strokes)
            }
            documentContainer.addSubview(pv)
            pageViews.append(pv)
            pageFrames.append(frame)
            y += sz.height + gap
        }

        let totalH = y - gap + bottomPad
        documentContainer.frame = CGRect(x: 0, y: 0, width: containerW, height: totalH)
        scrollView.contentSize = documentContainer.frame.size
    }

    private func fitToWidth() {
        guard documentContainer.bounds.width > 0, view.bounds.width > 0 else { return }
        let fit = view.bounds.width / documentContainer.bounds.width
        baseFitScale = fit
        scrollView.minimumZoomScale = fit * 0.6
        scrollView.maximumZoomScale = fit * 6.0
        scrollView.setZoomScale(fit, animated: false)
        centerContentIfNeeded()
    }

    private func centerContentIfNeeded() {
        let boundsSize = scrollView.bounds.size
        let contentSize = scrollView.contentSize
        let insetX = max(0, (boundsSize.width - contentSize.width) * 0.5)
        let insetY = max(0, (boundsSize.height - contentSize.height) * 0.5)
        scrollView.contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
    }

    // MARK: - UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        documentContainer
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContentIfNeeded()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateCurrentPageLabel()
        updateVisiblePages(forceSharp: false)
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        centerContentIfNeeded()
        updateVisiblePages(forceSharp: true)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updateVisiblePages(forceSharp: true)
    }

    private func updateCurrentPageLabel() {
        guard !pageFrames.isEmpty else { return }
        let zoom = max(0.01, scrollView.zoomScale)
        let midY = (scrollView.contentOffset.y + scrollView.bounds.height * 0.4) / zoom
        var current = 1
        for (idx, frame) in pageFrames.enumerated() {
            if frame.maxY >= midY {
                current = idx + 1
                break
            }
        }
        if toolState.currentPage != current {
            UserDefaults.standard.set(current, forKey: lastPageStorageKey)
            DispatchQueue.main.async {
                self.toolState.currentPage = current
            }
        }
    }

    private func updateVisiblePages(forceSharp: Bool) {
        guard let doc = pdfDoc, !pageViews.isEmpty else { return }
        let zoom = max(0.1, scrollView.zoomScale)
        let visibleInDoc = CGRect(
            x: scrollView.contentOffset.x / zoom,
            y: scrollView.contentOffset.y / zoom,
            width: scrollView.bounds.width / zoom,
            height: scrollView.bounds.height / zoom
        )
        let renderZone = visibleInDoc.insetBy(dx: 0, dy: -visibleInDoc.height * 1.2)
        let keepZone = visibleInDoc.insetBy(dx: 0, dy: -visibleInDoc.height * 3.0)

        for (idx, pv) in pageViews.enumerated() {
            let f = pageFrames[idx]
            if !f.intersects(keepZone) {
                if pv.isRendered && pv !== activePageView {
                    pv.evictBitmap()
                }
                continue
            }
            guard f.intersects(renderZone) else { continue }
            let needScale = !pv.isRendered || (forceSharp && abs(pv.renderedZoomScale - zoom) / max(0.1, pv.renderedZoomScale) > 0.25)
            guard needScale, !renderingPages.contains(idx) else { continue }
            renderingPages.insert(idx)
            let pageSize = pv.pageSize
            let targetZoom = zoom
            renderQueue.async { [weak self, weak pv] in
                guard let self, let pv, let page = doc.page(at: idx) else { return }
                let img = PageCanvasView.renderPage(page, pageSize: pageSize, zoomScale: targetZoom)
                DispatchQueue.main.async {
                    self.renderingPages.remove(idx)
                    pv.applyRenderedImage(img, zoomScale: targetZoom)
                }
            }
        }
    }

    // MARK: - Hardware 240Hz Pencil Input

    private func pageView(at docPoint: CGPoint) -> PageCanvasView? {
        for (idx, frame) in pageFrames.enumerated() {
            if frame.contains(docPoint) {
                return pageViews[idx]
            }
        }
        return nil
    }

    private func localPoint(of touch: UITouch, in pageView: PageCanvasView, prev: InkPoint?) -> InkPoint {
        let p = touch.preciseLocation(in: pageView)
        let x = max(0, min(pageView.pageSize.width, p.x))
        let y = max(0, min(pageView.pageSize.height, p.y))
        let t = touch.timestamp

        let pressure: CGFloat
        if touch.maximumPossibleForce > 0 && touch.force > 0 {
            pressure = max(0.08, min(1.0, touch.force / touch.maximumPossibleForce))
        } else if toolState.tool == .pen && toolState.penStyle != .ball {
            // Velocity-driven expressive pressure for 3rd-party styluses without pressure sensors!
            if let prev = prev {
                let dt = max(0.002, t - prev.t)
                let speed = hypot(x - prev.x, y - prev.y) / CGFloat(dt)
                // Slower strokes -> fuller ink (0.78); brisk strokes -> sleeker line (0.28)
                let targetP = max(0.26, min(0.82, 0.80 - (speed / 950.0) * 0.52))
                activeVelPressure = activeVelPressure * 0.72 + targetP * 0.28
                pressure = activeVelPressure
            } else {
                activeVelPressure = 0.58
                pressure = 0.58
            }
        } else {
            pressure = 0.5
        }
        return InkPoint(x: x, y: y, p: pressure, t: t)
    }

    private func cancelHoldTimer() {
        holdTimer?.cancel()
        holdTimer = nil
    }

    private func scheduleHoldToShape(for pv: PageCanvasView) {
        cancelHoldTimer()
        guard toolState.holdToShape, toolState.tool == .pen || (toolState.tool == .highlighter && !toolState.hlStraight) else { return }
        guard snappedShape == nil, activePoints.count >= 10 else { return }
        let zoom = scrollView.zoomScale
        let item = DispatchWorkItem { [weak self, weak pv] in
            guard let self, let pv, self.activePageView === pv, self.snappedShape == nil else { return }
            if let detected = ShapeDetector.detect(from: self.activePoints, zoomScale: zoom) {
                self.rawPointsBeforeSnap = self.activePoints
                self.snappedShape = detected
                self.activePoints = detected.points
                if let last = self.rawPointsBeforeSnap?.last {
                    self.shapeSnapTipPoint = CGPoint(x: last.x, y: last.y)
                }
                self.paintLive(on: pv)
                self.toolState.showToast("Snapped to \(detected.kind)")
            }
        }
        holdTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: item)
    }

    private func handlePencilBegan(_ touch: UITouch, event: UIEvent?) {
        cancelHoldTimer()
        snappedShape = nil
        rawPointsBeforeSnap = nil
        shapeSnapTipPoint = nil

        let docPt = touch.preciseLocation(in: documentContainer)
        guard let pv = pageView(at: docPt) else { return }
        activePageView = pv

        if toolState.tool == .laser {
            if let oldPV = laserPageView, oldPV !== pv {
                oldPV.clearLiveOverlay()
                laserPoints.removeAll()
            }
            laserPageView = pv
            laserDown = true
            let pt = localPoint(of: touch, in: pv, prev: nil)
            laserPoints.append(LaserPoint(x: pt.x, y: pt.y, time: CACurrentMediaTime()))
            startLaserLoop()
            onLaserTick()
            return
        }

        if toolState.tool == .eraser {
            activeErasePageKey = pv.pageKey
            activeEraseOriginals = []
            activeErasePieces = [:]
            let pt = localPoint(of: touch, in: pv, prev: nil)
            let cgPt = CGPoint(x: pt.x, y: pt.y)
            activeEraseLastPoint = cgPt
            eraseAt(cgPt, in: pv)
            pv.updateEraserRing(center: cgPt, radius: CGFloat(toolState.activeEraserRadius), zoomScale: scrollView.zoomScale)
            return
        }

        let smoother = OneEuroSmoother(scale: max(0.5, scrollView.zoomScale), level: toolState.penSmooth)
        activeSmoother = smoother
        activePoints = []
        activeVelPressure = 0.58

        let coalesced = event?.coalescedTouches(for: touch) ?? [touch]
        for t in coalesced {
            let raw = localPoint(of: t, in: pv, prev: activePoints.last)
            let filtered = smoother.filter(raw)
            if activeStartPoint == nil {
                activeStartPoint = CGPoint(x: filtered.x, y: filtered.y)
                holdAnchor = activeStartPoint
            }
            appendLivePoint(filtered, on: pv)
        }
        paintLive(on: pv)
    }

    private func handlePencilMoved(_ touch: UITouch, event: UIEvent?) {
        guard let pv = activePageView else { return }
        let coalesced = event?.coalescedTouches(for: touch) ?? [touch]

        if toolState.tool == .laser {
            let now = CACurrentMediaTime()
            for t in coalesced {
                let pt = localPoint(of: t, in: pv, prev: nil)
                laserPoints.append(LaserPoint(x: pt.x, y: pt.y, time: now))
            }
            startLaserLoop()
            return
        }

        if toolState.tool == .eraser {
            let radius = CGFloat(toolState.activeEraserRadius)
            for t in coalesced {
                let pt = localPoint(of: t, in: pv, prev: nil)
                let cur = CGPoint(x: pt.x, y: pt.y)
                if let last = activeEraseLastPoint {
                    let dist = hypot(cur.x - last.x, cur.y - last.y)
                    let steps = max(1, Int(ceil(dist / max(1.5, radius * 0.45))))
                    for i in 1...steps {
                        let frac = CGFloat(i) / CGFloat(steps)
                        let interp = CGPoint(x: last.x + (cur.x - last.x) * frac, y: last.y + (cur.y - last.y) * frac)
                        eraseAt(interp, in: pv)
                    }
                } else {
                    eraseAt(cur, in: pv)
                }
                activeEraseLastPoint = cur
            }
            if let last = activeEraseLastPoint {
                pv.updateEraserRing(center: last, radius: radius, zoomScale: scrollView.zoomScale)
            }
            return
        }

        guard let smoother = activeSmoother else { return }
        for t in coalesced {
            let raw = localPoint(of: t, in: pv, prev: activePoints.last)
            let filtered = smoother.filter(raw)
            appendLivePoint(filtered, on: pv)
        }
        paintLive(on: pv)
    }

    private func appendLivePoint(_ pt: InkPoint, on pv: PageCanvasView) {
        // Straight Highlighter mode
        if toolState.tool == .highlighter && toolState.hlStraight && snappedShape == nil {
            let start = activeStartPoint ?? CGPoint(x: pt.x, y: pt.y)
            activeStartPoint = start
            var ex = pt.x
            var ey = pt.y
            let ang = atan2(abs(ey - start.y), abs(ex - start.x)) * 180.0 / CGFloat.pi
            if ang < 7.0 { ey = start.y }
            else if ang > 83.0 { ex = start.x }
            activePoints = [
                InkPoint(x: start.x, y: start.y, p: 0.5, t: pt.t - 0.008),
                InkPoint(x: ex, y: ey, p: 0.5, t: pt.t)
            ]
            return
        }

        // Interactive resize/adjust after Hold-to-Shape snap
        if var shape = snappedShape {
            let tEnd = pt.t
            let tStart = max(0, tEnd - 0.04)
            switch shape.geom {
            case let .line(x0, y0, _, _):
                var ex = pt.x, ey = pt.y
                let dx = ex - x0, dy = ey - y0
                let ang = atan2(abs(dy), abs(dx)) * 180.0 / CGFloat.pi
                if ang < 5.0 { ey = y0 }
                else if ang > 85.0 { ex = x0 }
                else if abs(ang - 45.0) < 4.0 {
                    let avg = (abs(dx) + abs(dy)) * 0.5
                    ex = x0 + (dx >= 0 ? avg : -avg)
                    ey = y0 + (dy >= 0 ? avg : -avg)
                }
                let g = DetectedShapeGeom.line(x0: x0, y0: y0, x1: ex, y1: ey)
                shape.geom = g
                activePoints = ShapeDetector.buildShapePoints(geom: g, tStart: tStart, tEnd: tEnd)
                snappedShape = shape

            case let .ellipse(cx, cy, rx, ry, isCircle):
                if let snapTip = shapeSnapTipPoint {
                    let d0 = max(8.0, hypot(snapTip.x - cx, snapTip.y - cy))
                    let dNow = max(8.0, hypot(pt.x - cx, pt.y - cy))
                    let ratio = max(0.2, min(4.0, dNow / d0))
                    let g = DetectedShapeGeom.ellipse(cx: cx, cy: cy, rx: rx * ratio, ry: ry * ratio, isCircle: isCircle)
                    activePoints = ShapeDetector.buildShapePoints(geom: g, tStart: tStart, tEnd: tEnd)
                }

            case let .rect(x0, y0, x1, y1, isSquare):
                if let snapTip = shapeSnapTipPoint {
                    let cx = (x0 + x1) * 0.5, cy = (y0 + y1) * 0.5
                    let d0 = max(8.0, hypot(snapTip.x - cx, snapTip.y - cy))
                    let dNow = max(8.0, hypot(pt.x - cx, pt.y - cy))
                    let ratio = max(0.2, min(4.0, dNow / d0))
                    let hw = (x1 - x0) * 0.5 * ratio
                    let hh = (y1 - y0) * 0.5 * ratio
                    let g = DetectedShapeGeom.rect(x0: cx - hw, y0: cy - hh, x1: cx + hw, y1: cy + hh, isSquare: isSquare)
                    activePoints = ShapeDetector.buildShapePoints(geom: g, tStart: tStart, tEnd: tEnd)
                }

            case .triangle:
                break
            }
            return
        }

        if let last = activePoints.last {
            if hypot(pt.x - last.x, pt.y - last.y) < 0.05 { return }
        }
        activePoints.append(pt)

        // Hold-to-Shape anchor check
        let holdRadius = 3.5 / max(0.5, scrollView.zoomScale)
        if let anchor = holdAnchor {
            if hypot(pt.x - anchor.x, pt.y - anchor.y) > holdRadius {
                holdAnchor = CGPoint(x: pt.x, y: pt.y)
                scheduleHoldToShape(for: pv)
            }
        } else {
            holdAnchor = CGPoint(x: pt.x, y: pt.y)
            scheduleHoldToShape(for: pv)
        }
    }

    private func handlePencilEnded(_ touch: UITouch, event: UIEvent?) {
        cancelHoldTimer()
        lastPencilUpTime = CACurrentMediaTime()

        defer {
            activePageView = nil
            activeSmoother = nil
            activeStartPoint = nil
            holdAnchor = nil
            snappedShape = nil
            rawPointsBeforeSnap = nil
            shapeSnapTipPoint = nil
            activePoints.removeAll(keepingCapacity: true)
            activeErasePageKey = nil
            activeEraseOriginals = []
            activeErasePieces = [:]
            activeEraseLastPoint = nil
        }

        guard let pv = activePageView else { return }

        if toolState.tool == .laser {
            laserDown = false
            return
        }

        if toolState.tool == .eraser {
            pv.clearLiveOverlay()
            let pieces = Array(activeErasePieces.values)
            if !activeEraseOriginals.isEmpty || !pieces.isEmpty, let key = activeErasePageKey {
                pushUndo(UndoAction(pageKey: key, added: pieces, removed: activeEraseOriginals))
                scheduleSave()
            }
            return
        }

        pv.clearLiveOverlay()
        guard !activePoints.isEmpty else { return }

        let isHL = toolState.tool == .highlighter
        let isStraight = (isHL && toolState.hlStraight) || (snappedShape?.straight == true)
        let stroke = makeCommittedStroke(
            points: activePoints,
            tool: isHL ? "highlighter" : "pen",
            style: isHL ? "ball" : toolState.penStyle.rawValue,
            color: isHL ? toolState.activeHlColorHex : toolState.activePenColorHex,
            size: isHL ? toolState.activeHlSize : toolState.activePenSize,
            straight: isStraight,
            smartShape: snappedShape?.kind
        )

        var list = inkDoc.pages[pv.pageKey] ?? []
        list.append(stroke)
        inkDoc.pages[pv.pageKey] = list
        pv.setStrokes(list)

        // Two-step undo for smart shapes: Undo #1 unsnaps to raw stroke; Undo #2 removes stroke
        if let rawPts = rawPointsBeforeSnap, !rawPts.isEmpty, snappedShape != nil {
            let rawStroke = makeCommittedStroke(
                points: rawPts,
                tool: stroke.tool,
                style: stroke.style ?? "ball",
                color: stroke.color,
                size: stroke.size,
                straight: false,
                smartShape: nil
            )
            pushUndo(UndoAction(pageKey: pv.pageKey, added: [rawStroke], removed: []))
            pushUndo(UndoAction(pageKey: pv.pageKey, added: [stroke], removed: [rawStroke]))
        } else {
            pushUndo(UndoAction(pageKey: pv.pageKey, added: [stroke], removed: []))
        }
        scheduleSave()
    }

    private func handlePencilResetFallback() {
        cancelHoldTimer()
        activePageView?.clearLiveOverlay()
        activePageView = nil
        activeSmoother = nil
        activeStartPoint = nil
        holdAnchor = nil
        snappedShape = nil
        rawPointsBeforeSnap = nil
        shapeSnapTipPoint = nil
        activePoints.removeAll(keepingCapacity: true)
        activeErasePageKey = nil
        activeEraseOriginals = []
        activeErasePieces = [:]
        activeEraseLastPoint = nil
        laserDown = false
    }

    private func makeCommittedStroke(
        points: [InkPoint],
        tool: String,
        style: String,
        color: String,
        size: Double,
        straight: Bool,
        smartShape: String?
    ) -> InkStroke {
        var flat: [Double] = []
        flat.reserveCapacity(points.count * 3)
        for pt in points {
            flat.append((Double(pt.x) * 100).rounded() / 100)
            flat.append((Double(pt.y) * 100).rounded() / 100)
            flat.append(max(0.001, (Double(pt.p) * 1000).rounded() / 1000))
        }
        return InkStroke(
            id: InkStroke.newID(),
            t: Int64(Date().timeIntervalSince1970 * 1000),
            tool: tool,
            style: style,
            color: color,
            size: size,
            pts: flat,
            straight: straight,
            _bakedSmooth: !straight && smartShape == nil && toolState.penSmooth > 0,
            _smoothLevel: straight ? 0 : toolState.penSmooth,
            _sens: 1.0,
            _smartShape: smartShape
        )
    }

    private func paintLive(on pv: PageCanvasView) {
        let isHL = toolState.tool == .highlighter
        let col = UIColor(hex: isHL ? toolState.activeHlColorHex : toolState.activePenColorHex)
        let sz = CGFloat(isHL ? toolState.activeHlSize : toolState.activePenSize)
        let isStraight = (isHL && toolState.hlStraight) || (snappedShape?.straight == true)
        pv.updateLiveStroke(
            points: activePoints,
            color: col,
            size: sz,
            tool: isHL ? "highlighter" : "pen",
            style: isHL ? "ball" : toolState.penStyle.rawValue,
            straight: isStraight,
            isSmartShape: snappedShape != nil
        )
    }

    // MARK: - Eraser Engine (Stroke + Precise Pixel Eraser)

    private func noteErased(_ s: InkStroke, nowMs: Int64) {
        inkDoc.deleted[s.id] = nowMs
        if activeErasePieces[s.id] != nil {
            activeErasePieces.removeValue(forKey: s.id)
        } else {
            activeEraseOriginals.append(s)
        }
    }

    private func eraseAt(_ pt: CGPoint, in pv: PageCanvasView) {
        guard var list = inkDoc.pages[pv.pageKey], !list.isEmpty else { return }
        let radius = CGFloat(toolState.activeEraserRadius)
        let hlOnly = toolState.eraseHlOnly
        let pixelMode = toolState.eraserMode == .pixel
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        var kept: [InkStroke] = []
        kept.reserveCapacity(list.count)
        var changed = false

        for stroke in list {
            if hlOnly && stroke.tool != "highlighter" {
                kept.append(stroke)
                continue
            }
            if !pixelMode {
                if StrokeGeometry.strokeHits(stroke, point: pt, radius: radius) {
                    noteErased(stroke, nowMs: nowMs)
                    changed = true
                } else {
                    kept.append(stroke)
                }
            } else {
                if let pieces = StrokeGeometry.cutStroke(stroke, at: pt, radius: radius) {
                    noteErased(stroke, nowMs: nowMs)
                    for pc in pieces {
                        activeErasePieces[pc.id] = pc
                        kept.append(pc)
                    }
                    changed = true
                } else {
                    kept.append(stroke)
                }
            }
        }

        if changed {
            list = kept
            if list.isEmpty {
                inkDoc.pages.removeValue(forKey: pv.pageKey)
            } else {
                inkDoc.pages[pv.pageKey] = list
            }
            pv.setStrokes(list)
        }
    }

    // MARK: - Laser Pointer Loop (120Hz CADisplayLink)

    private func startLaserLoop() {
        guard laserDisplayLink == nil else { return }
        let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick))
        link.add(to: .main, forMode: .common)
        laserDisplayLink = link
    }

    private func stopLaserLoop() {
        laserDisplayLink?.invalidate()
        laserDisplayLink = nil
    }

    func onLaserTick() {
        guard let pv = laserPageView else {
            stopLaserLoop()
            return
        }
        let now = CACurrentMediaTime()
        let life: CFTimeInterval = toolState.laserTrail ? 0.95 : 0.18
        laserPoints.removeAll { now - $0.time >= life }
        pv.updateLaser(
            points: laserPoints,
            color: UIColor(hex: toolState.laserColorHex),
            showTrail: toolState.laserTrail,
            zoomScale: scrollView.zoomScale,
            now: now
        )
        if laserPoints.isEmpty && !laserDown {
            stopLaserLoop()
            laserPageView = nil
        }
    }

    // MARK: - Undo / Redo & Auto-Save

    private func pushUndo(_ action: UndoAction) {
        undoStack.append(action)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        syncUndoFlags()
    }

    func performUndo() {
        guard let action = undoStack.popLast() else { return }
        applyInverse(action)
        redoStack.append(action)
        syncUndoFlags()
        scheduleSave()
    }

    func performRedo() {
        guard let action = redoStack.popLast() else { return }
        applyForward(action)
        undoStack.append(action)
        syncUndoFlags()
        scheduleSave()
    }

    private func applyInverse(_ action: UndoAction) {
        var list = inkDoc.pages[action.pageKey] ?? []
        let addedIds = Set(action.added.map { $0.id })
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if !addedIds.isEmpty {
            list.removeAll { addedIds.contains($0.id) }
            for id in addedIds { inkDoc.deleted[id] = nowMs }
        }
        for s in action.removed {
            inkDoc.deleted.removeValue(forKey: s.id)
            list.append(s)
        }
        list.sort { $0.t < $1.t }
        updatePageStrokes(pageKey: action.pageKey, strokes: list)
    }

    private func applyForward(_ action: UndoAction) {
        var list = inkDoc.pages[action.pageKey] ?? []
        let removedIds = Set(action.removed.map { $0.id })
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if !removedIds.isEmpty {
            list.removeAll { removedIds.contains($0.id) }
            for id in removedIds { inkDoc.deleted[id] = nowMs }
        }
        for s in action.added {
            inkDoc.deleted.removeValue(forKey: s.id)
            list.append(s)
        }
        list.sort { $0.t < $1.t }
        updatePageStrokes(pageKey: action.pageKey, strokes: list)
    }

    private func updatePageStrokes(pageKey: String, strokes: [InkStroke]) {
        if strokes.isEmpty {
            inkDoc.pages.removeValue(forKey: pageKey)
        } else {
            inkDoc.pages[pageKey] = strokes
        }
        if let pv = pageViews.first(where: { $0.pageKey == pageKey }) {
            pv.setStrokes(strokes)
        }
    }

    private func syncUndoFlags() {
        DispatchQueue.main.async {
            self.toolState.canUndo = !self.undoStack.isEmpty
            self.toolState.canRedo = !self.redoStack.isEmpty
        }
    }

    private func scheduleSave() {
        isDirty = true
        DispatchQueue.main.async { self.toolState.saveStatus = "Saving…" }
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.saveNow()
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: item)
    }

    func saveNow() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        guard isDirty else { return }
        isDirty = false
        let snapshot = inkDoc
        let targetURL = pdfURL
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                try snapshot.save(for: targetURL)
                DispatchQueue.main.async {
                    self?.toolState.saveStatus = "Saved"
                }
            } catch {
                DispatchQueue.main.async {
                    self?.toolState.saveStatus = "Save error"
                }
            }
        }
    }
}

struct PDFNotebookRepresentable: UIViewControllerRepresentable {
    let pdfURL: URL
    let toolState: NotebookToolState
    let controllerBox: ControllerBox

    final class ControllerBox {
        weak var vc: PDFNotebookViewController?
    }

    func makeUIViewController(context: Context) -> PDFNotebookViewController {
        let vc = PDFNotebookViewController(pdfURL: pdfURL, toolState: toolState)
        controllerBox.vc = vc
        return vc
    }

    func updateUIViewController(_ uiViewController: PDFNotebookViewController, context: Context) {
        controllerBox.vc = uiViewController
    }
}
