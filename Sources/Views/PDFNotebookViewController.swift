import UIKit
import SwiftUI
import PDFKit
import QuartzCore

enum DrawingTool: String {
    case pen
    case highlighter
    case eraser
    case lasso
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

    // Live UI State
    @Published var canUndo: Bool = false
    @Published var canRedo: Bool = false
    @Published var currentPage: Int = 1
    @Published var totalPages: Int = 1
    @Published var saveStatus: String = "Saved"
    @Published var toastMessage: String = ""

    // Lasso & Page Overview State
    @Published var hasLassoSelection: Bool = false
    @Published var lassoSelectedCount: Int = 0
    @Published var hasLassoClipboard: Bool = false
    @Published var pageSlots: [PageSlot] = []
    @Published var bookmarkedKeys: Set<String> = []
    @Published var removedPagesCount: Int = 0

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
    var isCurrentPageBookmarked: Bool {
        let idx = currentPage - 1
        guard idx >= 0 && idx < pageSlots.count else { return false }
        return bookmarkedKeys.contains(pageSlots[idx].key)
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
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

private enum UndoAction {
    case strokes(pageKey: String, added: [InkStroke], removed: [InkStroke])
    case addBlank(blank: BlankPage, strokes: [InkStroke])
    case deleteBlank(blank: BlankPage, strokes: [InkStroke])
    case setRemoved(pdfN: Int, newRemoved: Bool)
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
    let relativePath: String
    let toolState: NotebookToolState
    let syncManager: DriveSyncManager?

    private var pdfDoc: PDFDocument?
    private var pdfPageSizes: [CGSize] = []
    private var inkDoc: InkDocument
    private var pageSlots: [PageSlot] = []
    private var pageViews: [PageCanvasView] = []
    private var pageFrames: [CGRect] = []

    private let scrollView = InkScrollView()
    private let documentContainer = UIView()
    private let pencilRecognizer = PencilDrawingGestureRecognizer()

    private let renderQueue = DispatchQueue(label: "com.pencilink.pdfrender", qos: .userInitiated)
    private var renderingKeys = Set<String>()
    private var layoutGeneration: Int = 0
    private var isRebuildingPages: Bool = false
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

    // Lasso state
    private var lassoSelection: LassoSelection?
    private var lassoClipboard: LassoClipboard?

    // Laser Pointer state
    private var laserPageView: PageCanvasView?
    private var laserPoints: [LaserPoint] = []
    private var laserDown = false
    private var laserDisplayLink: CADisplayLink?

    // Undo / Redo + debounced save + live Drive poll
    private var undoStack: [UndoAction] = []
    private var redoStack: [UndoAction] = []
    private var saveWorkItem: DispatchWorkItem?
    private var isDirty = false
    private var syncPollTimer: Timer?
    private var pendingRemoteDoc: InkDocument?

    private var lastPageStorageKey: String {
        "pencilink.lastpage." + pdfURL.lastPathComponent
    }

    init(pdfURL: URL, relativePath: String, toolState: NotebookToolState, syncManager: DriveSyncManager?) {
        self.pdfURL = pdfURL
        self.relativePath = relativePath
        self.toolState = toolState
        self.syncManager = syncManager
        var loaded = InkDocument.load(for: pdfURL)
        if loaded.name.isEmpty { loaded.name = relativePath }
        self.inkDoc = loaded
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopLaserLoop()
        syncPollTimer?.invalidate()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.118, green: 0.122, blue: 0.141, alpha: 1.0)
        setupScrollView()
        setupTapUndoGestures()
        loadPDF()
        startLiveDriveSync()
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
        syncPollTimer?.invalidate()
        syncPollTimer = nil
        cancelHoldTimer()
        clearLassoSelection(commitFirst: true)
        stopLaserLoop()
        saveNow()
        syncNowWithDrive(silent: true)
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

    func onToolChanged(to newTool: DrawingTool) {
        if newTool != .lasso && lassoSelection != nil {
            clearLassoSelection(commitFirst: true)
        }
    }

    func resetZoom() {
        fitToWidth()
        updateVisiblePages(forceSharp: true)
        toolState.showToast("Fit to width")
    }

    func jumpToPage(_ pageNumber: Int, animated: Bool = true) {
        let idx = max(0, min(pageFrames.count - 1, pageNumber - 1))
        guard idx >= 0, idx < pageFrames.count else { return }
        let zoom = max(0.1, scrollView.zoomScale)
        let targetY = max(0, pageFrames[idx].minY * zoom - 76)
        let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom)
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: min(targetY, maxY)), animated: animated)
        updateCurrentPageLabel()
        updateVisiblePages(forceSharp: true)
    }

    // MARK: - PDF Loading & Page Slot Rebuilding

    private func loadPDF() {
        guard let doc = PDFDocument(url: pdfURL) else { return }
        pdfDoc = doc
        let count = doc.pageCount
        pdfPageSizes.removeAll()
        pdfPageSizes.reserveCapacity(count)
        for i in 0..<count {
            let sz = doc.page(at: i).map { PageCanvasView.normalizedPageSize(for: $0) } ?? CGSize(width: 595, height: 842)
            pdfPageSizes.append(sz)
        }
        rebuildPageViews(focusKey: nil)
    }

    private func rebuildPageViews(focusKey: String?) {
        let wasLaidOut = didInitialLayout
        let prevZoom = wasLaidOut ? scrollView.zoomScale : 1.0
        let keepKey = focusKey ?? pageSlots[safe: toolState.currentPage - 1]?.key

        // Snapshot existing rendered PDF bitmaps so unchanged pages never flash blank!
        var preservedBitmaps: [String: (image: UIImage, zoom: CGFloat)] = [:]
        for pv in pageViews {
            if !pv.isTemplateOnly, pv.isRendered, let img = pv.renderedImage {
                preservedBitmaps[pv.pageKey] = (img, pv.renderedZoomScale)
            }
        }

        isRebuildingPages = true
        layoutGeneration += 1
        renderingKeys.removeAll()

        // Reset UIScrollView zoom cleanly to 1.0 BEFORE resizing documentContainer so UIKit
        // guarantees documentContainer.frame.origin == (0, 0) and contentSize stays 100% in sync!
        if wasLaidOut && abs(scrollView.zoomScale - 1.0) > 0.0001 {
            scrollView.minimumZoomScale = min(scrollView.minimumZoomScale, 1.0)
            scrollView.maximumZoomScale = max(scrollView.maximumZoomScale, 1.0)
            scrollView.setZoomScale(1.0, animated: false)
        }

        for pv in pageViews { pv.removeFromSuperview() }
        pageViews.removeAll()
        pageFrames.removeAll()

        let defSize = pdfPageSizes.first ?? CGSize(width: 595, height: 842)
        pageSlots = inkDoc.buildPageSlots(pdfPageSizes: pdfPageSizes, defaultSize: defSize)

        let gap: CGFloat = 14
        let topPad: CGFloat = 80
        let bottomPad: CGFloat = 90
        var maxW: CGFloat = 595
        for s in pageSlots {
            if s.size.width > maxW { maxW = s.size.width }
        }
        let sidePad: CGFloat = 16
        let containerW = maxW + sidePad * 2
        var y = topPad

        for slot in pageSlots {
            let x = (containerW - slot.size.width) * 0.5
            let frame = CGRect(x: x, y: y, width: slot.size.width, height: slot.size.height)
            let pv = PageCanvasView(slot: slot)
            pv.frame = frame
            if let strokes = inkDoc.pages[slot.key], !strokes.isEmpty {
                pv.setStrokes(strokes)
            }
            if let cached = preservedBitmaps[slot.key] {
                pv.applyRenderedImage(cached.image, zoomScale: cached.zoom)
            } else if pv.isTemplateOnly {
                pv.refreshVectorScale(for: prevZoom)
            }
            documentContainer.addSubview(pv)
            pageViews.append(pv)
            pageFrames.append(frame)
            y += slot.size.height + gap
        }

        let totalH = max(200, y - gap + bottomPad)
        documentContainer.transform = .identity
        documentContainer.frame = CGRect(x: 0, y: 0, width: containerW, height: totalH)
        scrollView.contentSize = CGSize(width: containerW, height: totalH)

        if wasLaidOut && view.bounds.width > 0 {
            let fit = view.bounds.width / max(1, containerW)
            baseFitScale = fit
            scrollView.minimumZoomScale = fit * 0.6
            scrollView.maximumZoomScale = fit * 6.0
            let clampedZoom = max(scrollView.minimumZoomScale, min(scrollView.maximumZoomScale, prevZoom))
            scrollView.setZoomScale(clampedZoom, animated: false)
            centerContentIfNeeded()
        }

        isRebuildingPages = false
        syncDocumentMetadataToUI()

        if wasLaidOut {
            if let fk = keepKey, let targetIdx = pageSlots.firstIndex(where: { $0.key == fk }) {
                jumpToPage(targetIdx + 1, animated: false)
            } else {
                updateCurrentPageLabel()
                updateVisiblePages(forceSharp: true)
            }
        }
    }

    private func syncDocumentMetadataToUI() {
        let slotsCopy = pageSlots
        let marked = Set(inkDoc.bookmarks.filter { $0.value.on }.keys)
        let removedCount = inkDoc.removedCount
        DispatchQueue.main.async {
            self.toolState.pageSlots = slotsCopy
            self.toolState.totalPages = max(1, slotsCopy.count)
            self.toolState.bookmarkedKeys = marked
            self.toolState.removedPagesCount = removedCount
            if self.toolState.currentPage > slotsCopy.count {
                self.toolState.currentPage = max(1, slotsCopy.count)
            }
        }
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
        guard !isRebuildingPages else { return }
        centerContentIfNeeded()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isRebuildingPages else { return }
        updateCurrentPageLabel()
        updateVisiblePages(forceSharp: false)
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        guard !isRebuildingPages else { return }
        centerContentIfNeeded()
        updateVisiblePages(forceSharp: true)
        if let sel = lassoSelection, let pv = pageView(forKey: sel.pageKey) {
            pv.updateLasso(selection: sel, zoomScale: scrollView.zoomScale)
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard !isRebuildingPages else { return }
        updateVisiblePages(forceSharp: true)
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard !isRebuildingPages else { return }
        updateCurrentPageLabel()
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
        guard !isRebuildingPages, !pageViews.isEmpty else { return }
        let zoom = max(0.1, scrollView.zoomScale)
        let visibleInDoc = CGRect(
            x: scrollView.contentOffset.x / zoom,
            y: scrollView.contentOffset.y / zoom,
            width: scrollView.bounds.width / zoom,
            height: scrollView.bounds.height / zoom
        )
        let renderZone = visibleInDoc.insetBy(dx: 0, dy: -visibleInDoc.height * 1.2)
        let keepZone = visibleInDoc.insetBy(dx: 0, dy: -visibleInDoc.height * 3.0)
        let doc = pdfDoc
        let gen = layoutGeneration

        for (idx, pv) in pageViews.enumerated() {
            let f = pageFrames[idx]
            if pv.isTemplateOnly {
                if f.intersects(renderZone) {
                    pv.refreshVectorScale(for: zoom)
                }
                continue
            }
            if !f.intersects(keepZone) {
                if pv.isRendered && pv !== activePageView {
                    pv.evictBitmap()
                }
                continue
            }
            guard f.intersects(renderZone) else { continue }
            let needScale = !pv.isRendered || (forceSharp && abs(pv.renderedZoomScale - zoom) / max(0.1, pv.renderedZoomScale) > 0.25)
            guard needScale, !renderingKeys.contains(pv.pageKey) else { continue }
            renderingKeys.insert(pv.pageKey)
            let slot = pv.slot
            let targetZoom = zoom
            renderQueue.async { [weak self, weak pv] in
                let img = PageCanvasView.renderSlotBackground(slot: slot, pdfDoc: doc, zoomScale: targetZoom)
                DispatchQueue.main.async {
                    guard let self, self.layoutGeneration == gen else { return }
                    self.renderingKeys.remove(slot.key)
                    pv?.applyRenderedImage(img, zoomScale: targetZoom)
                }
            }
        }
    }

    // MARK: - Page Management & Bookmarks

    func insertBlankPage(after slotIndex: Int, template: PaperTemplate) {
        clearLassoSelection(commitFirst: true)
        let ref = pageSlots[safe: max(0, min(pageSlots.count - 1, slotIndex))]
        let defSz = pdfPageSizes.first ?? CGSize(width: 595, height: 842)
        let w = Double(ref?.size.width ?? defSz.width)
        let h = Double(ref?.size.height ?? defSz.height)
        let pos = InkDocument.placeBlankTree(after: ref)
        let blank = BlankPage(
            id: InkStroke.newID(),
            anchor: pos.anchor,
            parent: pos.parent,
            ord: 0,
            w: w,
            h: h,
            t: pos.t,
            src: nil,
            pattern: template.rawValue
        )
        inkDoc.blanks[blank.id] = blank
        inkDoc.layoutBlanks()
        pushUndo(.addBlank(blank: blank, strokes: []))
        rebuildPageViews(focusKey: InkDocument.blankKey(blank.id))
        scheduleSave()
        toolState.showToast("Added \(template.title) page")
    }

    func duplicatePage(at slotIndex: Int) {
        clearLassoSelection(commitFirst: true)
        guard let slot = pageSlots[safe: slotIndex] else { return }
        let pos = InkDocument.placeBlankTree(after: slot)
        let blank = BlankPage(
            id: InkStroke.newID(),
            anchor: pos.anchor,
            parent: pos.parent,
            ord: 0,
            w: Double(slot.size.width),
            h: Double(slot.size.height),
            t: pos.t,
            src: slot.effectivePDFPageNumber,
            pattern: slot.blank?.pattern
        )
        inkDoc.blanks[blank.id] = blank
        inkDoc.layoutBlanks()

        let srcStrokes = inkDoc.pages[slot.key] ?? []
        let copiedStrokes: [InkStroke] = srcStrokes.map { s in
            var c = s
            c.id = InkStroke.newID()
            return c
        }
        if !copiedStrokes.isEmpty {
            inkDoc.pages[InkDocument.blankKey(blank.id)] = copiedStrokes
        }
        pushUndo(.addBlank(blank: blank, strokes: copiedStrokes))
        rebuildPageViews(focusKey: InkDocument.blankKey(blank.id))
        scheduleSave()
        toolState.showToast("Page duplicated")
    }

    func deletePage(at slotIndex: Int) {
        clearLassoSelection(commitFirst: true)
        guard pageSlots.count > 1, let slot = pageSlots[safe: slotIndex] else {
            toolState.showToast("Cannot delete the last page")
            return
        }
        let focusAfter = pageSlots[safe: max(0, slotIndex - 1)]?.key
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        if let blank = slot.blank {
            let strokes = inkDoc.pages[slot.key] ?? []
            inkDoc.blanks.removeValue(forKey: blank.id)
            inkDoc.pages.removeValue(forKey: slot.key)
            inkDoc.deleted[blank.id] = nowMs
            pushUndo(.deleteBlank(blank: blank, strokes: strokes))
            rebuildPageViews(focusKey: focusAfter)
            scheduleSave()
            toolState.showToast("Page deleted (Undo to restore)")
        } else if let pdfN = slot.pdfN {
            inkDoc.removed[String(pdfN)] = PageMark(on: true, t: nowMs)
            pushUndo(.setRemoved(pdfN: pdfN, newRemoved: true))
            rebuildPageViews(focusKey: focusAfter)
            scheduleSave()
            toolState.showToast("Page hidden (Restore in Overview)")
        }
    }

    func restoreAllRemovedPages() {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        var restored = 0
        for (k, mark) in inkDoc.removed where mark.on {
            inkDoc.removed[k] = PageMark(on: false, t: nowMs)
            restored += 1
        }
        guard restored > 0 else { return }
        rebuildPageViews(focusKey: nil)
        scheduleSave()
        toolState.showToast("Restored \(restored) page\(restored == 1 ? "" : "s")")
    }

    func toggleBookmarkForCurrentPage() {
        guard let slot = pageSlots[safe: toolState.currentPage - 1] else { return }
        toggleBookmark(for: slot.key)
    }

    func toggleBookmark(for pageKey: String) {
        let nowOn = !inkDoc.isBookmarked(pageKey)
        let prev = inkDoc.bookmarks[pageKey]
        inkDoc.bookmarks[pageKey] = PageMark(
            on: nowOn,
            t: Int64(Date().timeIntervalSince1970 * 1000),
            title: prev?.title,
            tag: prev?.tag
        )
        syncDocumentMetadataToUI()
        scheduleSave()
        toolState.showToast(nowOn ? "Page bookmarked" : "Bookmark removed")
    }

    func clearCurrentPageStrokes() {
        clearLassoSelection(commitFirst: true)
        guard let slot = pageSlots[safe: toolState.currentPage - 1],
              let existing = inkDoc.pages[slot.key], !existing.isEmpty else {
            toolState.showToast("Page is already clear")
            return
        }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        for s in existing { inkDoc.deleted[s.id] = nowMs }
        inkDoc.pages.removeValue(forKey: slot.key)
        pageView(forKey: slot.key)?.setStrokes([])
        pushUndo(.strokes(pageKey: slot.key, added: [], removed: existing))
        scheduleSave()
        toolState.showToast("Cleared page writing")
    }

    // MARK: - Thumbnails & Share / Export

    func renderThumbnailAsync(for slot: PageSlot, targetWidth: CGFloat, completion: @escaping (UIImage?) -> Void) {
        let doc = pdfDoc
        let strokes = inkDoc.pages[slot.key] ?? []
        let scale = max(0.25, targetWidth / max(1, slot.size.width))
        renderQueue.async {
            let img = PageCanvasView.renderCompositeImage(slot: slot, pdfDoc: doc, strokes: strokes, scale: scale)
            DispatchQueue.main.async {
                completion(img)
            }
        }
    }

    func exportCurrentPagePNG() {
        clearLassoSelection(commitFirst: true)
        guard let slot = pageSlots[safe: toolState.currentPage - 1] else { return }
        let strokes = inkDoc.pages[slot.key] ?? []
        let doc = pdfDoc
        let pageNum = toolState.currentPage
        let baseName = pdfURL.deletingPathExtension().lastPathComponent
        toolState.showToast("Rendering PNG…")
        renderQueue.async { [weak self] in
            let img = PageCanvasView.renderCompositeImage(slot: slot, pdfDoc: doc, strokes: strokes, scale: 2.0)
            guard let data = img.pngData() else { return }
            let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(baseName) - Page \(pageNum).png")
            do {
                try data.write(to: outURL, options: .atomic)
                DispatchQueue.main.async {
                    self?.presentShareSheet(items: [outURL])
                }
            } catch {
                self?.toolState.showToast("PNG export failed")
            }
        }
    }

    func exportAnnotatedPDF() {
        clearLassoSelection(commitFirst: true)
        let slots = pageSlots
        guard !slots.isEmpty else { return }
        let doc = pdfDoc
        let pagesCopy = inkDoc.pages
        let baseName = pdfURL.deletingPathExtension().lastPathComponent
        toolState.showToast("Exporting PDF (\(slots.count) pages)…")
        renderQueue.async { [weak self] in
            let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(baseName) (Annotated).pdf")
            let firstBounds = CGRect(origin: .zero, size: slots[0].size)
            let renderer = UIGraphicsPDFRenderer(bounds: firstBounds)
            do {
                try renderer.writePDF(to: outURL) { pdfCtx in
                    for slot in slots {
                        let pageRect = CGRect(origin: .zero, size: slot.size)
                        pdfCtx.beginPage(withBounds: pageRect, pageInfo: [:])
                        let cg = pdfCtx.cgContext
                        PageCanvasView.drawSlotBackground(slot: slot, pdfDoc: doc, in: cg)
                        if let strokes = pagesCopy[slot.key], !strokes.isEmpty {
                            PageCanvasView.drawStrokes(strokes, in: cg)
                        }
                    }
                }
                DispatchQueue.main.async {
                    self?.presentShareSheet(items: [outURL])
                }
            } catch {
                self?.toolState.showToast("PDF export failed")
            }
        }
    }

    private func presentShareSheet(items: [Any]) {
        let avc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let pop = avc.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: 76, width: 1, height: 1)
            pop.permittedArrowDirections = .up
        }
        present(avc, animated: true)
    }

    // MARK: - Lasso Operations (Called from Floating Action Bar & Pencil)

    private func syncLassoUIState() {
        let count = lassoSelection?.strokes.count ?? 0
        let hasClip = lassoClipboard != nil
        DispatchQueue.main.async {
            self.toolState.hasLassoSelection = count > 0
            self.toolState.lassoSelectedCount = count
            self.toolState.hasLassoClipboard = hasClip
        }
    }

    func clearLassoSelection(commitFirst: Bool = true) {
        if commitFirst { commitLassoTransformIfNeeded() }
        guard let sel = lassoSelection else {
            syncLassoUIState()
            return
        }
        lassoSelection = nil
        if let pv = pageView(forKey: sel.pageKey) {
            pv.setHiddenStrokeIDs([])
            pv.clearLiveOverlay()
        }
        syncLassoUIState()
    }

    private func commitLassoTransformIfNeeded() {
        guard var sel = lassoSelection, !sel.strokes.isEmpty, sel.hasTransform else {
            if var sel = lassoSelection {
                sel.tx = 0; sel.ty = 0; sel.scale = 1.0; sel.rotation = 0.0
                lassoSelection = sel
            }
            return
        }
        let selIds = Set(sel.strokes.map { $0.id })
        let list = inkDoc.pages[sel.pageKey] ?? []
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        var removed: [InkStroke] = []
        var added: [InkStroke] = []

        let nextList: [InkStroke] = list.map { item in
            guard selIds.contains(item.id) else { return item }
            removed.append(item)
            inkDoc.deleted[item.id] = nowMs
            let moved = LassoMath.transformedStroke(
                item,
                pivot: sel.pivot,
                tx: sel.tx,
                ty: sel.ty,
                scale: sel.scale,
                rotation: sel.rotation
            )
            added.append(moved)
            return moved
        }

        inkDoc.pages[sel.pageKey] = nextList
        let newBox = LassoMath.combinedBox(of: added)
        sel.strokes = added
        sel.origBox = newBox
        sel.box = newBox
        sel.pivot = CGPoint(x: newBox.midX, y: newBox.midY)
        sel.tx = 0; sel.ty = 0; sel.scale = 1.0; sel.rotation = 0.0
        lassoSelection = sel

        if let pv = pageView(forKey: sel.pageKey) {
            pv.setStrokes(nextList, hiddenIDs: sel.hiddenStrokeIDs)
            pv.updateLasso(selection: sel, zoomScale: scrollView.zoomScale)
        }
        pushUndo(.strokes(pageKey: sel.pageKey, added: added, removed: removed))
        scheduleSave()
    }

    func lassoRecolor(hex: String) {
        commitLassoTransformIfNeeded()
        guard var sel = lassoSelection, !sel.strokes.isEmpty else { return }
        let selIds = Set(sel.strokes.map { $0.id })
        let list = inkDoc.pages[sel.pageKey] ?? []
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        var removed: [InkStroke] = []
        var added: [InkStroke] = []

        let nextList: [InkStroke] = list.map { item in
            guard selIds.contains(item.id) else { return item }
            removed.append(item)
            inkDoc.deleted[item.id] = nowMs
            var copy = item
            copy.id = InkStroke.newID()
            copy.t = nowMs
            copy.color = hex
            added.append(copy)
            return copy
        }

        inkDoc.pages[sel.pageKey] = nextList
        sel.strokes = added
        lassoSelection = sel
        if let pv = pageView(forKey: sel.pageKey) {
            pv.setStrokes(nextList, hiddenIDs: sel.hiddenStrokeIDs)
            pv.updateLasso(selection: sel, zoomScale: scrollView.zoomScale)
        }
        pushUndo(.strokes(pageKey: sel.pageKey, added: added, removed: removed))
        scheduleSave()
    }

    func lassoCopy() {
        commitLassoTransformIfNeeded()
        guard let sel = lassoSelection, !sel.strokes.isEmpty else { return }
        lassoClipboard = LassoClipboard(
            center: CGPoint(x: sel.box.midX, y: sel.box.midY),
            width: sel.box.width,
            height: sel.box.height,
            strokes: sel.strokes
        )
        syncLassoUIState()
        toolState.showToast("Copied \(sel.strokes.count) stroke\(sel.strokes.count == 1 ? "" : "s") — tap page to paste")
    }

    func lassoCut() {
        lassoCopy()
        lassoDelete()
    }

    func lassoDuplicate() {
        commitLassoTransformIfNeeded()
        guard var sel = lassoSelection, !sel.strokes.isEmpty else { return }
        let offset: CGFloat = 14.0
        let added = sel.strokes.map { LassoMath.translatedCopy($0, dx: offset, dy: offset) }
        var list = inkDoc.pages[sel.pageKey] ?? []
        list.append(contentsOf: added)
        inkDoc.pages[sel.pageKey] = list

        let newBox = LassoMath.combinedBox(of: added)
        sel.strokes = added
        sel.origBox = newBox
        sel.box = newBox
        sel.pivot = CGPoint(x: newBox.midX, y: newBox.midY)
        sel.tx = 0; sel.ty = 0; sel.scale = 1.0; sel.rotation = 0.0
        lassoSelection = sel

        if let pv = pageView(forKey: sel.pageKey) {
            pv.setStrokes(list, hiddenIDs: sel.hiddenStrokeIDs)
            pv.updateLasso(selection: sel, zoomScale: scrollView.zoomScale)
        }
        pushUndo(.strokes(pageKey: sel.pageKey, added: added, removed: []))
        scheduleSave()
        toolState.showToast("Duplicated selection")
    }

    func lassoDelete() {
        commitLassoTransformIfNeeded()
        guard let sel = lassoSelection, !sel.strokes.isEmpty else { return }
        let selIds = Set(sel.strokes.map { $0.id })
        let list = inkDoc.pages[sel.pageKey] ?? []
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        var removed: [InkStroke] = []
        var kept: [InkStroke] = []
        for item in list {
            if selIds.contains(item.id) {
                removed.append(item)
                inkDoc.deleted[item.id] = nowMs
            } else {
                kept.append(item)
            }
        }
        if kept.isEmpty { inkDoc.pages.removeValue(forKey: sel.pageKey) }
        else { inkDoc.pages[sel.pageKey] = kept }

        lassoSelection = nil
        if let pv = pageView(forKey: sel.pageKey) {
            pv.setStrokes(kept, hiddenIDs: [])
            pv.clearLiveOverlay()
        }
        syncLassoUIState()
        pushUndo(.strokes(pageKey: sel.pageKey, added: [], removed: removed))
        scheduleSave()
        toolState.showToast("Deleted selection")
    }

    private func pasteLassoClipboard(on pv: PageCanvasView, at pt: CGPoint) {
        guard let clip = lassoClipboard, !clip.strokes.isEmpty else { return }
        let dx = pt.x - clip.center.x
        let dy = pt.y - clip.center.y
        let added = clip.strokes.map { LassoMath.translatedCopy($0, dx: dx, dy: dy) }
        var list = inkDoc.pages[pv.pageKey] ?? []
        list.append(contentsOf: added)
        inkDoc.pages[pv.pageKey] = list

        let newBox = LassoMath.combinedBox(of: added)
        var sel = LassoSelection(pageKey: pv.pageKey)
        sel.mode = .none
        sel.strokes = added
        sel.origBox = newBox
        sel.box = newBox
        sel.pivot = CGPoint(x: newBox.midX, y: newBox.midY)
        lassoSelection = sel

        pv.setStrokes(list, hiddenIDs: sel.hiddenStrokeIDs)
        pv.updateLasso(selection: sel, zoomScale: scrollView.zoomScale)
        syncLassoUIState()
        pushUndo(.strokes(pageKey: pv.pageKey, added: added, removed: []))
        scheduleSave()
        toolState.showToast("Pasted selection")
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

    private func pageView(forKey key: String) -> PageCanvasView? {
        pageViews.first(where: { $0.pageKey == key })
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
            if let prev = prev {
                let dt = max(0.002, t - prev.t)
                let speed = hypot(x - prev.x, y - prev.y) / CGFloat(dt)
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

        if toolState.tool == .lasso {
            handleLassoBegan(touch, on: pv)
            return
        }

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

    private func handleLassoBegan(_ touch: UITouch, on pv: PageCanvasView) {
        let raw = localPoint(of: touch, in: pv, prev: nil)
        let pt = CGPoint(x: raw.x, y: raw.y)
        let zoom = max(0.5, scrollView.zoomScale)

        if let cur = lassoSelection, cur.pageKey != pv.pageKey {
            clearLassoSelection(commitFirst: true)
        }

        if var sel = lassoSelection, sel.pageKey == pv.pageKey, !sel.strokes.isEmpty {
            let h = sel.handles(zoomScale: zoom)
            let hitR = 16.0 / zoom

            // 1. Rotation handle
            if hypot(pt.x - h.cx, pt.y - h.rotY) <= hitR {
                commitLassoTransformIfNeeded()
                sel = lassoSelection ?? sel
                sel.mode = .rotating
                sel.pivot = CGPoint(x: h.cx, y: h.cy)
                sel.startAngle = atan2(pt.y - h.cy, pt.x - h.cx)
                sel.rotation = 0
                lassoSelection = sel
                return
            }

            // 2. Corner scaling handles
            for c in h.corners {
                if hypot(pt.x - c.x, pt.y - c.y) <= hitR {
                    commitLassoTransformIfNeeded()
                    sel = lassoSelection ?? sel
                    sel.mode = .scaling
                    sel.pivot = CGPoint(x: c.ax, y: c.ay)
                    sel.startDistX = max(8.0, abs(c.x - c.ax)) * (c.x >= c.ax ? 1.0 : -1.0)
                    sel.startDistY = max(8.0, abs(c.y - c.ay)) * (c.y >= c.ay ? 1.0 : -1.0)
                    sel.origBox = sel.box
                    sel.scale = 1.0
                    lassoSelection = sel
                    return
                }
            }

            // 3. Inside box -> drag
            if pt.x >= h.bx0 - hitR * 0.5 && pt.x <= h.bx1 + hitR * 0.5 &&
               pt.y >= h.by0 - hitR * 0.5 && pt.y <= h.by1 + hitR * 0.5 {
                commitLassoTransformIfNeeded()
                sel = lassoSelection ?? sel
                sel.mode = .dragging
                sel.startPoint = pt
                sel.origBox = sel.box
                sel.pivot = CGPoint(x: sel.box.midX, y: sel.box.midY)
                sel.tx = 0; sel.ty = 0
                lassoSelection = sel
                return
            }

            // Tapped outside selection -> commit & clear, then start new lasso
            clearLassoSelection(commitFirst: true)
        }

        var fresh = LassoSelection(pageKey: pv.pageKey)
        fresh.mode = .drawing
        fresh.poly = [pt]
        lassoSelection = fresh
        pv.updateLasso(selection: fresh, zoomScale: zoom)
    }

    private func handlePencilMoved(_ touch: UITouch, event: UIEvent?) {
        guard let pv = activePageView else { return }
        let coalesced = event?.coalescedTouches(for: touch) ?? [touch]

        if toolState.tool == .lasso {
            handleLassoMoved(touch, on: pv)
            return
        }

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

    private func handleLassoMoved(_ touch: UITouch, on pv: PageCanvasView) {
        guard var sel = lassoSelection, sel.pageKey == pv.pageKey else { return }
        let raw = localPoint(of: touch, in: pv, prev: nil)
        let pt = CGPoint(x: raw.x, y: raw.y)
        let zoom = max(0.5, scrollView.zoomScale)

        switch sel.mode {
        case .drawing:
            if let last = sel.poly.last, hypot(pt.x - last.x, pt.y - last.y) < 1.5 { return }
            sel.poly.append(pt)
        case .dragging:
            sel.tx = pt.x - sel.startPoint.x
            sel.ty = pt.y - sel.startPoint.y
            sel.box = sel.origBox.offsetBy(dx: sel.tx, dy: sel.ty)
        case .scaling:
            let rawSx = (pt.x - sel.pivot.x) / sel.startDistX
            let rawSy = (pt.y - sel.pivot.y) / sel.startDistY
            let uni = max(0.15, min(6.0, (abs(rawSx) + abs(rawSy)) * 0.5))
            sel.scale = uni
            let nx0 = sel.pivot.x + (sel.origBox.minX - sel.pivot.x) * uni
            let ny0 = sel.pivot.y + (sel.origBox.minY - sel.pivot.y) * uni
            let nx1 = sel.pivot.x + (sel.origBox.maxX - sel.pivot.x) * uni
            let ny1 = sel.pivot.y + (sel.origBox.maxY - sel.pivot.y) * uni
            sel.box = CGRect(x: min(nx0, nx1), y: min(ny0, ny1), width: max(1, abs(nx1 - nx0)), height: max(1, abs(ny1 - ny0)))
        case .rotating:
            let ang = atan2(pt.y - sel.pivot.y, pt.x - sel.pivot.x)
            sel.rotation = ang - sel.startAngle
        case .none:
            return
        }
        lassoSelection = sel
        pv.updateLasso(selection: sel, zoomScale: zoom)
    }

    private func handleLassoEnded(on pv: PageCanvasView) {
        guard var sel = lassoSelection, sel.pageKey == pv.pageKey else { return }
        let mode = sel.mode
        sel.mode = .none
        lassoSelection = sel

        switch mode {
        case .drawing:
            var pathLen: CGFloat = 0
            if sel.poly.count >= 2 {
                for i in 1..<sel.poly.count {
                    pathLen += hypot(sel.poly[i].x - sel.poly[i - 1].x, sel.poly[i].y - sel.poly[i - 1].y)
                }
            }
            if sel.poly.count < 3 || pathLen < 8.0 {
                if let tapPt = sel.poly.first, lassoClipboard != nil {
                    pasteLassoClipboard(on: pv, at: tapPt)
                } else {
                    clearLassoSelection(commitFirst: false)
                }
                return
            }
            let pageStrokes = inkDoc.pages[pv.pageKey] ?? []
            let res = LassoMath.selectStrokes(in: pageStrokes, polygon: sel.poly)
            if res.selected.isEmpty {
                clearLassoSelection(commitFirst: false)
                return
            }
            sel.strokes = res.selected
            sel.origBox = res.box
            sel.box = res.box
            sel.pivot = CGPoint(x: res.box.midX, y: res.box.midY)
            sel.tx = 0; sel.ty = 0; sel.scale = 1.0; sel.rotation = 0.0
            lassoSelection = sel
            pv.setHiddenStrokeIDs(sel.hiddenStrokeIDs)
            pv.updateLasso(selection: sel, zoomScale: scrollView.zoomScale)
            syncLassoUIState()
            toolState.showToast("\(res.selected.count) stroke\(res.selected.count == 1 ? "" : "s") selected")

        case .dragging, .scaling, .rotating:
            commitLassoTransformIfNeeded()

        case .none:
            break
        }
    }

    private func appendLivePoint(_ pt: InkPoint, on pv: PageCanvasView) {
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
            flushPendingRemoteDoc()
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

        if toolState.tool == .lasso {
            handleLassoEnded(on: pv)
            return
        }

        if toolState.tool == .laser {
            laserDown = false
            return
        }

        if toolState.tool == .eraser {
            pv.clearLiveOverlay()
            let pieces = Array(activeErasePieces.values)
            if !activeEraseOriginals.isEmpty || !pieces.isEmpty, let key = activeErasePageKey {
                pushUndo(.strokes(pageKey: key, added: pieces, removed: activeEraseOriginals))
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
            pushUndo(.strokes(pageKey: pv.pageKey, added: [rawStroke], removed: []))
            pushUndo(.strokes(pageKey: pv.pageKey, added: [stroke], removed: [rawStroke]))
        } else {
            pushUndo(.strokes(pageKey: pv.pageKey, added: [stroke], removed: []))
        }
        scheduleSave()
    }

    private func handlePencilResetFallback() {
        cancelHoldTimer()
        if let pv = activePageView, toolState.tool != .lasso {
            pv.clearLiveOverlay()
        }
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

    // MARK: - Eraser Engine

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

    // MARK: - Unified Undo / Redo & Auto-Save

    private func pushUndo(_ action: UndoAction) {
        undoStack.append(action)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        syncUndoFlags()
    }

    func performUndo() {
        clearLassoSelection(commitFirst: false)
        guard let action = undoStack.popLast() else { return }
        applyUndo(action, isRedo: false)
        redoStack.append(action)
        syncUndoFlags()
        scheduleSave()
    }

    func performRedo() {
        clearLassoSelection(commitFirst: false)
        guard let action = redoStack.popLast() else { return }
        applyUndo(action, isRedo: true)
        undoStack.append(action)
        syncUndoFlags()
        scheduleSave()
    }

    private func applyUndo(_ action: UndoAction, isRedo: Bool) {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        switch action {
        case let .strokes(pageKey, added, removed):
            let toRemove = isRedo ? removed : added
            let toAdd = isRedo ? added : removed
            var list = inkDoc.pages[pageKey] ?? []
            let remIds = Set(toRemove.map { $0.id })
            if !remIds.isEmpty {
                list.removeAll { remIds.contains($0.id) }
                for id in remIds { inkDoc.deleted[id] = nowMs }
            }
            for s in toAdd {
                inkDoc.deleted.removeValue(forKey: s.id)
                list.append(s)
            }
            list.sort { $0.t < $1.t }
            if list.isEmpty { inkDoc.pages.removeValue(forKey: pageKey) }
            else { inkDoc.pages[pageKey] = list }
            pageView(forKey: pageKey)?.setStrokes(list)

        case let .addBlank(blank, strokes):
            if isRedo {
                inkDoc.deleted.removeValue(forKey: blank.id)
                inkDoc.blanks[blank.id] = blank
                if !strokes.isEmpty { inkDoc.pages[InkDocument.blankKey(blank.id)] = strokes }
                rebuildPageViews(focusKey: InkDocument.blankKey(blank.id))
            } else {
                inkDoc.blanks.removeValue(forKey: blank.id)
                inkDoc.pages.removeValue(forKey: InkDocument.blankKey(blank.id))
                inkDoc.deleted[blank.id] = nowMs
                rebuildPageViews(focusKey: nil)
            }

        case let .deleteBlank(blank, strokes):
            if isRedo {
                inkDoc.blanks.removeValue(forKey: blank.id)
                inkDoc.pages.removeValue(forKey: InkDocument.blankKey(blank.id))
                inkDoc.deleted[blank.id] = nowMs
                rebuildPageViews(focusKey: nil)
            } else {
                inkDoc.deleted.removeValue(forKey: blank.id)
                inkDoc.blanks[blank.id] = blank
                if !strokes.isEmpty { inkDoc.pages[InkDocument.blankKey(blank.id)] = strokes }
                rebuildPageViews(focusKey: InkDocument.blankKey(blank.id))
            }

        case let .setRemoved(pdfN, newRemoved):
            let targetRemoved = isRedo ? newRemoved : !newRemoved
            inkDoc.removed[String(pdfN)] = PageMark(on: targetRemoved, t: nowMs)
            rebuildPageViews(focusKey: targetRemoved ? nil : String(pdfN))
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

    func startLiveDriveSync() {
        syncPollTimer?.invalidate()
        guard let sm = syncManager, sm.config.isConnected else { return }
        // Pull latest remote deltas right when opening the book
        syncNowWithDrive(silent: true)
        // Poll Google Drive every 10s while the book is open (yielding if writing)
        syncPollTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.activePageView == nil, !self.laserDown,
                      let sm = self.syncManager, sm.config.isConnected, sm.config.autoSync else { return }
                self.syncNowWithDrive(silent: true)
            }
        }
    }

    func syncNowWithDrive(silent: Bool = false) {
        guard let sm = syncManager else { return }
        let snap = inkDoc
        let url = pdfURL
        let rel = relativePath
        Task { @MainActor in
            guard sm.config.isConnected else { return }
            if let (merged, changed) = await sm.syncBook(pdfURL: url, relativePath: rel, localDoc: snap) {
                if changed {
                    self.applyRemoteMergedDocument(merged)
                    if !silent { self.toolState.showToast("Synced remote updates") }
                } else if !silent {
                    self.toolState.showToast("Up to date with Google Drive")
                }
            }
        }
    }

    private func flushPendingRemoteDoc() {
        guard activePageView == nil, !laserDown, let pending = pendingRemoteDoc else { return }
        pendingRemoteDoc = nil
        applyRemoteMergedDocument(pending)
    }

    private func applyRemoteMergedDocument(_ merged: InkDocument) {
        if activePageView != nil || laserDown {
            pendingRemoteDoc = merged
            return
        }
        let structureChanged = (inkDoc.blanks != merged.blanks || inkDoc.removed != merged.removed)
        let oldPages = inkDoc.pages
        inkDoc = merged

        if structureChanged {
            clearLassoSelection(commitFirst: false)
            rebuildPageViews(focusKey: nil)
        } else {
            let hidden = lassoSelection?.hiddenStrokeIDs ?? []
            for pv in pageViews {
                let newStrokes = inkDoc.pages[pv.pageKey] ?? []
                let oldStrokes = oldPages[pv.pageKey] ?? []
                if newStrokes.count != oldStrokes.count || Set(newStrokes.map { $0.id }) != Set(oldStrokes.map { $0.id }) {
                    pv.setStrokes(newStrokes, hiddenIDs: (lassoSelection?.pageKey == pv.pageKey) ? hidden : [])
                }
            }
            syncDocumentMetadataToUI()
        }
    }

    func saveNow() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        guard isDirty else { return }
        isDirty = false
        var snapshot = inkDoc
        snapshot.name = relativePath
        let targetURL = pdfURL
        let rel = relativePath
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                try snapshot.save(for: targetURL)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.toolState.saveStatus = "Saved"
                    if let sm = self.syncManager, sm.config.isConnected, sm.config.autoSync {
                        sm.scheduleBookSync(
                            pdfURL: targetURL,
                            relativePath: rel,
                            localDocProvider: { [weak self] in self?.inkDoc ?? snapshot },
                            onMerged: { [weak self] merged in self?.applyRemoteMergedDocument(merged) }
                        )
                    }
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.toolState.saveStatus = "Save error"
                }
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

struct PDFNotebookRepresentable: UIViewControllerRepresentable {
    let pdfURL: URL
    let relativePath: String
    let toolState: NotebookToolState
    let syncManager: DriveSyncManager
    let controllerBox: ControllerBox

    final class ControllerBox {
        weak var vc: PDFNotebookViewController?
    }

    func makeUIViewController(context: Context) -> PDFNotebookViewController {
        let vc = PDFNotebookViewController(
            pdfURL: pdfURL,
            relativePath: relativePath,
            toolState: toolState,
            syncManager: syncManager
        )
        controllerBox.vc = vc
        return vc
    }

    func updateUIViewController(_ uiViewController: PDFNotebookViewController, context: Context) {
        controllerBox.vc = uiViewController
    }
}
