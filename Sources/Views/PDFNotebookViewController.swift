import UIKit
import SwiftUI
import PDFKit

enum DrawingTool: String {
    case pen
    case highlighter
    case eraser
}

final class NotebookToolState: ObservableObject {
    @Published var tool: DrawingTool = .pen
    @Published var penColorHex: String = "#1c1c1e"
    @Published var penSize: Double = 2.6
    @Published var highlighterColorHex: String = "#ffde59"
    @Published var highlighterSize: Double = 16.0
    @Published var eraserRadius: Double = 14.0
    @Published var twoFingerScrollLock: Bool = false
    @Published var canUndo: Bool = false
    @Published var canRedo: Bool = false
    @Published var currentPage: Int = 1
    @Published var totalPages: Int = 1
    @Published var saveStatus: String = "Saved"

    let penColors = ["#1c1c1e", "#007aff", "#ff3b30", "#30d158"]
    let penSizes: [Double] = [1.6, 2.6, 4.5]
    let hlColors = ["#ffde59", "#69e6a6", "#ff94af"]
    let hlSizes: [Double] = [12.0, 16.0, 26.0]
}

private struct UndoAction {
    let pageKey: String
    let added: [InkStroke]
    let removed: [InkStroke]
}

final class PDFNotebookViewController: UIViewController, UIScrollViewDelegate {
    let pdfURL: URL
    let toolState: NotebookToolState

    private var pdfDoc: PDFDocument?
    private var inkDoc: InkDocument
    private var pageViews: [PageCanvasView] = []
    private var pageFrames: [CGRect] = []

    private let scrollView = UIScrollView()
    private let documentContainer = UIView()
    private let pencilRecognizer = PencilDrawingGestureRecognizer()

    private let renderQueue = DispatchQueue(label: "com.pencilink.pdfrender", qos: .userInitiated)
    private var renderingPages = Set<Int>()
    private var baseFitScale: CGFloat = 1.0
    private var didInitialLayout = false

    // Active stroke state
    private var activePageView: PageCanvasView?
    private var activePoints: [InkPoint] = []
    private var activeSmoother: OneEuroSmoother?
    private var activeErased: [InkStroke] = []
    private var activeErasePageKey: String?

    // Undo / Redo + debounced save
    private var undoStack: [UndoAction] = []
    private var redoStack: [UndoAction] = []
    private var saveWorkItem: DispatchWorkItem?
    private var isDirty = false

    init(pdfURL: URL, toolState: NotebookToolState) {
        self.pdfURL = pdfURL
        self.toolState = toolState
        self.inkDoc = InkDocument.load(for: pdfURL)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.118, green: 0.122, blue: 0.141, alpha: 1.0)
        setupScrollView()
        loadPDF()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !didInitialLayout && view.bounds.width > 0 && !pageViews.isEmpty {
            didInitialLayout = true
            fitToWidth()
            updateVisiblePages(forceSharp: true)
        } else if didInitialLayout {
            centerContentIfNeeded()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        saveNow()
    }

    private func setupScrollView() {
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.backgroundColor = .clear
        scrollView.delegate = self
        scrollView.minimumZoomScale = 0.5
        scrollView.maximumZoomScale = 6.0
        scrollView.bouncesZoom = true
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = false
        scrollView.contentInsetAdjustmentBehavior = .never
        // NATIVE UIKIT HARDWARE SPLIT:
        // Fingers (.direct) scroll & pinch natively with Apple's capacitive palm rejection.
        // Pencil (.pencil) NEVER triggers scrolling!
        scrollView.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        scrollView.pinchGestureRecognizer?.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        applyScrollLockSetting()
        view.addSubview(scrollView)

        documentContainer.backgroundColor = .clear
        documentContainer.isMultipleTouchEnabled = true
        scrollView.addSubview(documentContainer)

        // Dedicated hardware Pencil gesture recognizer (requiresExclusiveTouchType = false)
        pencilRecognizer.pencilOnly = true
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
        documentContainer.addGestureRecognizer(pencilRecognizer)
    }

    func applyScrollLockSetting() {
        // 1 line of UIKit gives 100% forearm-proof 2-finger scrolling whenever toggled on!
        scrollView.panGestureRecognizer.minimumNumberOfTouches = toolState.twoFingerScrollLock ? 2 : 1
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
        let bottomPad: CGFloat = 80
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

    private func localPoint(of touch: UITouch, in pageView: PageCanvasView) -> InkPoint {
        let p = touch.preciseLocation(in: pageView)
        let x = max(0, min(pageView.pageSize.width, p.x))
        let y = max(0, min(pageView.pageSize.height, p.y))
        let force: CGFloat = touch.maximumPossibleForce > 0 ? max(0.05, min(1.0, touch.force / touch.maximumPossibleForce)) : 0.5
        return InkPoint(x: x, y: y, p: force, t: touch.timestamp)
    }

    private func handlePencilBegan(_ touch: UITouch, event: UIEvent?) {
        // Freeze native UIScrollView immediately while tip is on glass (0ms release on lift!)
        scrollView.isScrollEnabled = false

        let docPt = touch.preciseLocation(in: documentContainer)
        guard let pv = pageView(at: docPt) else { return }
        activePageView = pv

        if toolState.tool == .eraser {
            activeErased = []
            activeErasePageKey = pv.pageKey
            let pt = localPoint(of: touch, in: pv)
            eraseAt(CGPoint(x: pt.x, y: pt.y), in: pv)
            return
        }

        let smoother = OneEuroSmoother(scale: max(0.5, scrollView.zoomScale))
        activeSmoother = smoother
        activePoints = []

        let coalesced = event?.coalescedTouches(for: touch) ?? [touch]
        for t in coalesced {
            let raw = localPoint(of: t, in: pv)
            activePoints.append(smoother.filter(raw))
        }
        paintLive(on: pv)
    }

    private func handlePencilMoved(_ touch: UITouch, event: UIEvent?) {
        guard let pv = activePageView else { return }
        let coalesced = event?.coalescedTouches(for: touch) ?? [touch]

        if toolState.tool == .eraser {
            for t in coalesced {
                let pt = localPoint(of: t, in: pv)
                eraseAt(CGPoint(x: pt.x, y: pt.y), in: pv)
            }
            return
        }

        guard let smoother = activeSmoother else { return }
        for t in coalesced {
            let raw = localPoint(of: t, in: pv)
            let filtered = smoother.filter(raw)
            if let last = activePoints.last {
                if hypot(filtered.x - last.x, filtered.y - last.y) < 0.05 { continue }
            }
            activePoints.append(filtered)
        }
        paintLive(on: pv)
    }

    private func handlePencilEnded(_ touch: UITouch, event: UIEvent?) {
        defer {
            // Re-enable native 120Hz UIScrollView in 0ms!
            scrollView.isScrollEnabled = true
            activePageView = nil
            activeSmoother = nil
            activePoints.removeAll(keepingCapacity: true)
            activeErased = []
            activeErasePageKey = nil
        }

        guard let pv = activePageView else { return }

        if toolState.tool == .eraser {
            if !activeErased.isEmpty, let key = activeErasePageKey {
                pushUndo(UndoAction(pageKey: key, added: [], removed: activeErased))
                scheduleSave()
            }
            return
        }

        pv.clearLiveStroke()
        guard !activePoints.isEmpty else { return }

        var flat: [Double] = []
        flat.reserveCapacity(activePoints.count * 3)
        for pt in activePoints {
            flat.append((Double(pt.x) * 100).rounded() / 100)
            flat.append((Double(pt.y) * 100).rounded() / 100)
            flat.append(max(0.001, (Double(pt.p) * 1000).rounded() / 1000))
        }

        let isHL = toolState.tool == .highlighter
        let stroke = InkStroke(
            id: InkStroke.newID(),
            t: Int64(Date().timeIntervalSince1970 * 1000),
            tool: isHL ? "highlighter" : "pen",
            style: "ball",
            color: isHL ? toolState.highlighterColorHex : toolState.penColorHex,
            size: isHL ? toolState.highlighterSize : toolState.penSize,
            pts: flat,
            straight: false,
            _bakedSmooth: true,
            _smartShape: nil
        )

        var list = inkDoc.pages[pv.pageKey] ?? []
        list.append(stroke)
        inkDoc.pages[pv.pageKey] = list
        pv.setStrokes(list)
        pushUndo(UndoAction(pageKey: pv.pageKey, added: [stroke], removed: []))
        scheduleSave()
    }

    private func paintLive(on pv: PageCanvasView) {
        let isHL = toolState.tool == .highlighter
        let col = UIColor(hex: isHL ? toolState.highlighterColorHex : toolState.penColorHex)
        let sz = CGFloat(isHL ? toolState.highlighterSize : toolState.penSize)
        pv.updateLiveStroke(points: activePoints, color: col, size: sz, isHighlighter: isHL)
    }

    private func eraseAt(_ pt: CGPoint, in pv: PageCanvasView) {
        guard var list = inkDoc.pages[pv.pageKey], !list.isEmpty else { return }
        let radius = CGFloat(toolState.eraserRadius)
        var kept: [InkStroke] = []
        var changed = false
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        for stroke in list {
            if StrokeGeometry.strokeHits(stroke, point: pt, radius: radius) {
                activeErased.append(stroke)
                inkDoc.deleted[stroke.id] = nowMs
                changed = true
            } else {
                kept.append(stroke)
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

    // MARK: - Undo / Redo & Auto-Save

    private func pushUndo(_ action: UndoAction) {
        undoStack.append(action)
        if undoStack.count > 80 { undoStack.removeFirst() }
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
    @ObservedObject var toolState: NotebookToolState
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
        uiViewController.applyScrollLockSetting()
    }
}
