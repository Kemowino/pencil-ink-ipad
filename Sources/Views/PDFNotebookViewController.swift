import UIKit
import SwiftUI
import PDFKit
import QuartzCore
import Combine

struct PDFOutlineEntry: Identifiable, Hashable {
    let id: String
    let title: String
    let pageNumber: Int     // 1-based slot index
    let depth: Int
}

struct PDFSearchHit: Identifiable, Hashable {
    let id: String
    let pageNumber: Int     // 1-based slot index
    let snippet: String
}

enum DrawingTool: String, CaseIterable, Identifiable {
    case pen
    case eraser
    case highlighter
    case hand
    case lasso
    case text
    case laser

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hand: return "Scroll / Hand Mode"
        case .pen: return "Pen"
        case .eraser: return "Eraser"
        case .highlighter: return "Highlighter"
        case .lasso: return "Lasso Select"
        case .text: return "Text Box"
        case .laser: return "Laser Pointer"
        }
    }

    var settingsIcon: String {
        switch self {
        case .hand: return "hand.raised"
        case .pen: return "pencil.tip"
        case .eraser: return "eraser"
        case .highlighter: return "highlighter"
        case .lasso: return "lasso"
        case .text: return "textbox"
        case .laser: return "scope"
        }
    }
}

enum TextFontOption: String, CaseIterable, Identifiable {
    case sans = "sans"
    case serif = "serif"
    case mono = "mono"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sans: return "Sans"
        case .serif: return "Serif"
        case .mono: return "Mono"
        }
    }
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

/// High-frequency HUD state isolated from `NotebookToolState` so scrolling across 2,500 pages
/// or toggling `isWriting`/`saveStatus` updates ONLY the tiny bottom badge & bookmark button —
/// causing ZERO full-screen SwiftUI re-renders of `NotebookScreen` or its toolbars!
@MainActor
final class NotebookHUDState: ObservableObject {
    @Published var currentPage: Int = 1
    @Published var totalPages: Int = 1
    @Published var currentSlotLabel: String = ""
    @Published var saveStatus: String = "Saved"
    @Published var toastMessage: String = ""
    @Published var isWriting: Bool = false
    @Published var isOnHoboNotes: Bool = false
    @Published var isCurrentPageBookmarked: Bool = false
}

@MainActor
final class NotebookToolState: ObservableObject {
    @Published var tool: DrawingTool = .pen

    // Isolated high-frequency HUD observer (never triggers NotebookScreen body rebuilds!)
    let hud = NotebookHUDState()

    // Low-frequency Per-Tab Toolbar State
    @Published var canUndo: Bool = false
    @Published var canRedo: Bool = false
    @Published var hasLassoSelection: Bool = false
    @Published var lassoSelectedCount: Int = 0
    @Published var hasLassoClipboard: Bool = false
    @Published var hasActiveTextBox: Bool = false
    @Published var pageSlots: [PageSlot] = []
    @Published var bookmarkedKeys: Set<String> = [] {
        didSet { syncCurrentBookmarkFlag() }
    }
    @Published var removedPagesCount: Int = 0
    @Published var isHobonichi: Bool = false
    var previousTool: DrawingTool = .pen

    // Transparent proxies into `hud` so callers stay clean while skipping NotebookScreen rebuilds
    var currentPage: Int {
        get { hud.currentPage }
        set {
            if hud.currentPage != newValue {
                hud.currentPage = newValue
                syncCurrentBookmarkFlag()
            }
        }
    }
    var totalPages: Int {
        get { hud.totalPages }
        set { if hud.totalPages != newValue { hud.totalPages = newValue } }
    }
    var saveStatus: String {
        get { hud.saveStatus }
        set { if hud.saveStatus != newValue { hud.saveStatus = newValue } }
    }
    var toastMessage: String {
        get { hud.toastMessage }
        set { if hud.toastMessage != newValue { hud.toastMessage = newValue } }
    }
    var currentSlotLabel: String {
        get { hud.currentSlotLabel }
        set { if hud.currentSlotLabel != newValue { hud.currentSlotLabel = newValue } }
    }
    var isOnHoboNotes: Bool {
        get { hud.isOnHoboNotes }
        set { if hud.isOnHoboNotes != newValue { hud.isOnHoboNotes = newValue } }
    }
    var isWriting: Bool {
        get { hud.isWriting }
        set { if hud.isWriting != newValue { hud.isWriting = newValue } }
    }
    var isCurrentPageBookmarked: Bool {
        hud.isCurrentPageBookmarked
    }

    private var toastWorkItem: DispatchWorkItem?

    func syncCurrentBookmarkFlag() {
        let idx = hud.currentPage - 1
        let marked = (idx >= 0 && idx < pageSlots.count) && bookmarkedKeys.contains(pageSlots[idx].key)
        if hud.isCurrentPageBookmarked != marked {
            hud.isCurrentPageBookmarked = marked
        }
    }

    // Shared Cross-File Palette Proxies (all tabs & future files share these seamlessly!)
    var palette: ToolPaletteStore { ToolPaletteStore.shared }

    var penStyle: PenStyleOption { get { palette.penStyle } set { palette.penStyle = newValue } }
    var penSmooth: Int { get { palette.penSmooth } set { palette.penSmooth = newValue } }
    var penColors: [String] { get { palette.penColors } set { palette.penColors = newValue } }
    var penColorIndex: Int { get { palette.penColorIndex } set { palette.penColorIndex = newValue } }
    var penSizes: [Double] { get { palette.penSizes } set { palette.penSizes = newValue } }
    var penSizeIndex: Int { get { palette.penSizeIndex } set { palette.penSizeIndex = newValue } }
    var holdToShape: Bool { get { palette.holdToShape } set { palette.holdToShape = newValue } }

    var hlColors: [String] { get { palette.hlColors } set { palette.hlColors = newValue } }
    var hlColorIndex: Int { get { palette.hlColorIndex } set { palette.hlColorIndex = newValue } }
    var hlSizes: [Double] { get { palette.hlSizes } set { palette.hlSizes = newValue } }
    var hlSizeIndex: Int { get { palette.hlSizeIndex } set { palette.hlSizeIndex = newValue } }
    var hlStraight: Bool { get { palette.hlStraight } set { palette.hlStraight = newValue } }

    var eraserMode: EraserModeOption { get { palette.eraserMode } set { palette.eraserMode = newValue } }
    var eraserSizes: [Double] { get { palette.eraserSizes } set { palette.eraserSizes = newValue } }
    var eraserSizeIndex: Int { get { palette.eraserSizeIndex } set { palette.eraserSizeIndex = newValue } }
    var eraseHlOnly: Bool { get { palette.eraseHlOnly } set { palette.eraseHlOnly = newValue } }

    var textColors: [String] { get { palette.textColors } set { palette.textColors = newValue } }
    var textColorIndex: Int { get { palette.textColorIndex } set { palette.textColorIndex = newValue } }
    var textSize: Double { get { palette.textSize } set { palette.textSize = newValue } }
    var textFont: TextFontOption { get { palette.textFont } set { palette.textFont = newValue } }
    var textBold: Bool { get { palette.textBold } set { palette.textBold = newValue } }
    var textBgHex: String { get { palette.textBgHex } set { palette.textBgHex = newValue } }

    var laserColorHex: String { palette.activeLaserColorHex }
    var laserTrail: Bool { get { palette.laserTrail } set { palette.laserTrail = newValue } }

    var activePenColorHex: String { palette.activePenColorHex }
    var activePenSize: Double { palette.activePenSize }
    var activeHlColorHex: String { palette.activeHlColorHex }
    var activeHlSize: Double { palette.activeHlSize }
    var activeEraserRadius: Double { palette.activeEraserRadius }
    var activeTextColorHex: String { palette.activeTextColorHex }

    init() {}

    func showToast(_ message: String) {
        DispatchQueue.main.async {
            self.toastWorkItem?.cancel()
            self.hud.toastMessage = message
            let item = DispatchWorkItem { [weak self] in
                self?.hud.toastMessage = ""
            }
            self.toastWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: item)
        }
    }
}

private enum UndoAction {
    case strokes(pageKey: String, added: [InkStroke], removed: [InkStroke])
    case texts(pageKey: String, added: [InkTextBox], removed: [InkTextBox])
    case addBlank(blank: BlankPage, strokes: [InkStroke])
    case deleteBlank(blank: BlankPage, strokes: [InkStroke])
    case setRemoved(pdfN: Int, newRemoved: Bool)
}


private final class CachedPageBitmap {
    let image: UIImage
    let zoomScale: CGFloat
    let readingMode: PDFReadingMode

    init(image: UIImage, zoomScale: CGFloat, readingMode: PDFReadingMode) {
        self.image = image
        self.zoomScale = zoomScale
        self.readingMode = readingMode
    }
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


/// Interactive Goodnotes-style inline text box editor hosted directly on `documentContainer`.
private final class InlineTextBoxEditorView: UIView, UITextViewDelegate {
    var pageKey: String
    var pageFrame: CGRect
    var box: InkTextBox
    var originalBox: InkTextBox?
    var smartDarkInk: Bool

    var onChanged: ((InkTextBox) -> Void)?
    var onCommitRequested: (() -> Void)?

    private let dragBar = UIView()
    private let gripPill = UIView()
    private let textView = UITextView()
    private let resizeHandle = UIView()
    private let borderLayer = CAShapeLayer()
    private let dragBarHeight: CGFloat = 18

    private var dragStartOrigin: CGPoint = .zero
    private var resizeStartWidth: CGFloat = 220

    init(pageKey: String, pageFrame: CGRect, box: InkTextBox, originalBox: InkTextBox?, smartDarkInk: Bool) {
        self.pageKey = pageKey
        self.pageFrame = pageFrame
        self.box = box
        self.originalBox = originalBox
        self.smartDarkInk = smartDarkInk
        super.init(frame: .zero)
        setupUI()
        applyStyling()
        updateFrameFromBox()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        backgroundColor = .clear
        clipsToBounds = false

        borderLayer.fillColor = UIColor.clear.cgColor
        borderLayer.strokeColor = UIColor.systemBlue.cgColor
        borderLayer.lineWidth = 1.4
        borderLayer.lineDashPattern = [5, 3]
        layer.addSublayer(borderLayer)

        // Top drag bar to reposition text box smoothly
        dragBar.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.16)
        dragBar.layer.cornerRadius = 5
        dragBar.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        dragBar.isUserInteractionEnabled = true
        addSubview(dragBar)

        gripPill.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.7)
        gripPill.layer.cornerRadius = 1.5
        dragBar.addSubview(gripPill)

        let dragPan = UIPanGestureRecognizer(target: self, action: #selector(handleDragPan(_:)))
        dragPan.maximumNumberOfTouches = 1
        dragBar.addGestureRecognizer(dragPan)

        // Live UITextView
        textView.delegate = self
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        textView.textContainer.lineFragmentPadding = 0
        textView.autocorrectionType = .default
        textView.spellCheckingType = .default
        textView.text = box.text
        addSubview(textView)

        // Right-edge circular resize handle
        resizeHandle.backgroundColor = .white
        resizeHandle.layer.borderColor = UIColor.systemBlue.cgColor
        resizeHandle.layer.borderWidth = 2.0
        resizeHandle.layer.cornerRadius = 8
        resizeHandle.isUserInteractionEnabled = true
        addSubview(resizeHandle)

        let resizePan = UIPanGestureRecognizer(target: self, action: #selector(handleResizePan(_:)))
        resizePan.maximumNumberOfTouches = 1
        resizeHandle.addGestureRecognizer(resizePan)
    }

    func focusTextView() {
        textView.becomeFirstResponder()
    }

    func applyStyling() {
        textView.font = box.resolvedUIFont()
        textView.textColor = PageCanvasView.displayColor(for: box.color, smartDark: smartDarkInk)
        textView.tintColor = UIColor.systemBlue
        if let bgHex = box.bgColor, !bgHex.isEmpty {
            textView.backgroundColor = UIColor(hex: bgHex).withAlphaComponent(smartDarkInk ? 0.24 : 0.88)
            textView.layer.cornerRadius = 5
        } else {
            textView.backgroundColor = UIColor.systemBlue.withAlphaComponent(smartDarkInk ? 0.08 : 0.04)
            textView.layer.cornerRadius = 5
        }
        updateFrameFromBox()
    }

    func updateFrameFromBox() {
        box.text = textView.text ?? ""
        let measured = box.measuredRect()
        let totalW = max(72, measured.width)
        let bodyH = max(32, measured.height)
        frame = CGRect(
            x: pageFrame.minX + CGFloat(box.x),
            y: pageFrame.minY + CGFloat(box.y) - dragBarHeight,
            width: totalW,
            height: bodyH + dragBarHeight
        )
        dragBar.frame = CGRect(x: 0, y: 0, width: totalW, height: dragBarHeight)
        gripPill.frame = CGRect(x: (totalW - 28) * 0.5, y: (dragBarHeight - 3) * 0.5, width: 28, height: 3)
        textView.frame = CGRect(x: 0, y: dragBarHeight, width: totalW, height: bodyH)
        resizeHandle.frame = CGRect(x: totalW - 8, y: dragBarHeight + (bodyH - 16) * 0.5, width: 16, height: 16)
        borderLayer.path = UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: totalW, height: bodyH + dragBarHeight), cornerRadius: 5).cgPath
    }

    func textViewDidChange(_ textView: UITextView) {
        box.text = textView.text ?? ""
        box.t = Int64(Date().timeIntervalSince1970 * 1000)
        updateFrameFromBox()
        onChanged?(box)
    }

    @objc private func handleDragPan(_ gr: UIPanGestureRecognizer) {
        guard let parent = superview else { return }
        switch gr.state {
        case .began:
            dragStartOrigin = CGPoint(x: CGFloat(box.x), y: CGFloat(box.y))
        case .changed:
            let tr = gr.translation(in: parent)
            let nx = max(4, min(pageFrame.width - CGFloat(box.w) - 4, dragStartOrigin.x + tr.x))
            let ny = max(4, min(pageFrame.height - 28, dragStartOrigin.y + tr.y))
            box.x = (Double(nx) * 100).rounded() / 100
            box.y = (Double(ny) * 100).rounded() / 100
            box.t = Int64(Date().timeIntervalSince1970 * 1000)
            updateFrameFromBox()
            onChanged?(box)
        default:
            break
        }
    }

    @objc private func handleResizePan(_ gr: UIPanGestureRecognizer) {
        guard let parent = superview else { return }
        switch gr.state {
        case .began:
            resizeStartWidth = CGFloat(box.w)
        case .changed:
            let tr = gr.translation(in: parent)
            let maxAvail = max(90, pageFrame.width - CGFloat(box.x) - 6)
            let nw = max(76, min(maxAvail, resizeStartWidth + tr.x))
            box.w = (Double(nw) * 100).rounded() / 100
            box.t = Int64(Date().timeIntervalSince1970 * 1000)
            updateFrameFromBox()
            onChanged?(box)
        default:
            break
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Allow tapping/dragging the protruding right-edge resize handle cleanly
        if resizeHandle.frame.insetBy(dx: -10, dy: -10).contains(point) {
            return resizeHandle
        }
        return super.hitTest(point, with: event)
    }
}

final class PDFNotebookViewController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let pdfURL: URL
    let relativePath: String
    let toolState: NotebookToolState
    let syncManager: DriveSyncManager?

    /// Fast pure-C CoreGraphics PDF handle for low-RAM, lock-free rendering.
    private var cgPDFDoc: CGPDFDocument?
    /// Heavy PDFKit document is loaded LAZILY only when Outline (TOC) or Text Search is used!
    private var lazyPDFDoc: PDFDocument?
    private var pdfPageSizes: [CGSize] = []
    private var inkDoc: InkDocument
    private var pageSlots: [PageSlot] = []
    private var slotIndexByKey: [String: Int] = [:]
    private var mountedPageViews: [String: PageCanvasView] = [:]
    /// Recycling pool for PDF `PageCanvasView`s — eliminates UIView/CALayer churn during 2,500-page scrolling!
    private var reusablePagePool: [PageCanvasView] = []
    private var pageFrames: [CGRect] = []
    private let pageBitmapCache: NSCache<NSString, CachedPageBitmap> = {
        let c = NSCache<NSString, CachedPageBitmap>()
        #if targetEnvironment(macCatalyst)
        c.countLimit = 20
        c.totalCostLimit = 96 * 1024 * 1024
        #else
        c.countLimit = 18
        c.totalCostLimit = 64 * 1024 * 1024
        #endif
        return c
    }()

    private let scrollView = InkScrollView()
    private let documentContainer = UIView()
    private let pencilRecognizer = PencilDrawingGestureRecognizer()

    private let renderQueue = DispatchQueue(label: "com.pencilink.pdfrender", qos: .userInitiated)
    private var renderingKeys = Set<String>()
    private var layoutGeneration: Int = 0
    private let renderWindowLock = NSLock()
    private var activeRenderWindow: Range<Int> = 0..<0
    private var activeLayoutGenSnapshot: Int = 0
    private var textTapRecognizer: UITapGestureRecognizer?
    private var handDoubleTapRecognizer: UITapGestureRecognizer?
    private var twoFingerTapRecognizer: UITapGestureRecognizer?
    private var threeFingerTapRecognizer: UITapGestureRecognizer?
    private var isRebuildingPages: Bool = false
    private var isSnappingZoom: Bool = false
    private var zoomSettleWorkItem: DispatchWorkItem?
    private var scrollSettleWorkItem: DispatchWorkItem?
    private var pagePersistWorkItem: DispatchWorkItem?
    private var lastScrollSampleTime: CFTimeInterval = 0
    private var lastScrollOffsetY: CGFloat = 0
    private var scrollVelocityPtsPerSec: CGFloat = 0
    private var lastMountedKeepRange: Range<Int> = 0..<0
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

    // Active Inline Text Box Editor
    private var activeTextEditor: InlineTextBoxEditorView?

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
    private var idleCheckWorkItem: DispatchWorkItem?
    private var lastBackgroundedAt: Date?
    private var lastDriveSyncCheckAt: Date?
    private var pendingRemoteDoc: InkDocument?
    private var foregroundObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?
    private var resignActiveObserver: NSObjectProtocol?
    private var memoryWarningObserver: NSObjectProtocol?
    private var settingsCancellables = Set<AnyCancellable>()
    fileprivate var isTabActive: Bool = true
    private var currentReadingMode: PDFReadingMode = .original
    private var isHoboDoc: Bool = false
    private var lastHoboPlannerKey: String? = nil

    private var lastPageStorageKey: String {
        "pencilink.lastpage." + pdfURL.lastPathComponent
    }

    init(
        pdfURL: URL,
        relativePath: String,
        toolState: NotebookToolState,
        syncManager: DriveSyncManager?,
        isActive: Bool = true
    ) {
        self.pdfURL = pdfURL
        self.relativePath = relativePath
        self.toolState = toolState
        self.syncManager = syncManager
        self.isTabActive = isActive
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
        idleCheckWorkItem?.cancel()
        zoomSettleWorkItem?.cancel()
        scrollSettleWorkItem?.cancel()
        pagePersistWorkItem?.cancel()
        if let obs = foregroundObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = activeObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = resignActiveObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = memoryWarningObserver { NotificationCenter.default.removeObserver(obs) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.11, green: 0.114, blue: 0.129, alpha: 1.0)
                : UIColor(red: 0.902, green: 0.910, blue: 0.929, alpha: 1.0)
        }
        currentReadingMode = AppSettings.shared.pdfReadingMode
        setupScrollView()
        setupTapUndoGestures()
        setupPencilInteraction()
        bindAppSettings()
        loadPDF()
        startLiveDriveSync()

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleReturnedToApp()
        }
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleReturnedToApp()
        }
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.lastBackgroundedAt = Date()
            self.idleCheckWorkItem?.cancel()
            self.idleCheckWorkItem = nil
            // Flush any finished work when leaving the app without interrupting open text mid-typing
            if self.isDirty && self.activeTextEditor == nil {
                self.saveNow(flushDriveImmediately: true)
            }
        }
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.evictOffscreenBitmaps(keepOnlyVisible: true)
        }
    }

    private func setupPencilInteraction() {
        #if !targetEnvironment(macCatalyst)
        let interaction = UIPencilInteraction()
        interaction.delegate = self
        view.addInteraction(interaction)
        #endif
    }



    // MARK: - Mac & iPad Hardware Keyboard Shortcuts

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: "z", modifierFlags: .command, action: #selector(kbUndo)),
            UIKeyCommand(input: "z", modifierFlags: [.command, .shift], action: #selector(kbRedo)),
            UIKeyCommand(input: "=", modifierFlags: .command, action: #selector(kbZoomIn)),
            UIKeyCommand(input: "+", modifierFlags: .command, action: #selector(kbZoomIn)),
            UIKeyCommand(input: "-", modifierFlags: .command, action: #selector(kbZoomOut)),
            UIKeyCommand(input: "0", modifierFlags: .command, action: #selector(kbResetZoom)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(kbEscape)),
            UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(kbEscape))
        ]
    }

    @objc private func kbUndo() {
        guard activeTextEditor == nil else { return }
        performUndo()
    }

    @objc private func kbRedo() {
        guard activeTextEditor == nil else { return }
        performRedo()
    }

    @objc private func kbZoomIn() {
        let next = min(scrollView.maximumZoomScale, scrollView.zoomScale * 1.25)
        scrollView.setZoomScale(next, animated: true)
    }

    @objc private func kbZoomOut() {
        let next = max(scrollView.minimumZoomScale, scrollView.zoomScale / 1.25)
        scrollView.setZoomScale(next, animated: true)
    }

    @objc private func kbResetZoom() {
        resetZoom()
    }

    @objc private func kbEscape() {
        if activeTextEditor != nil {
            commitActiveTextBox()
        } else if lassoSelection != nil {
            clearLassoSelection(commitFirst: true)
        }
    }

    private func bindAppSettings() {
        let settings = AppSettings.shared
        pencilRecognizer.pencilOnly = !settings.drawWithFinger

        settings.$drawWithFinger
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] allowFinger in
                self?.pencilRecognizer.pencilOnly = !allowFinger
            }
            .store(in: &settingsCancellables)

        settings.$pdfReadingMode
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newMode in
                self?.applyReadingMode(newMode)
            }
            .store(in: &settingsCancellables)

        settings.$syncMode
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                guard let self, self.isTabActive else { return }
                if mode == .smart {
                    self.startLiveDriveSync()
                } else {
                    self.idleCheckWorkItem?.cancel()
                    self.idleCheckWorkItem = nil
                    self.syncManager?.cancelScheduledSync(for: self.relativePath)
                }
            }
            .store(in: &settingsCancellables)
    }

    func applyReadingMode(_ mode: PDFReadingMode) {
        guard currentReadingMode != mode else { return }
        currentReadingMode = mode
        layoutGeneration += 1
        renderWindowLock.lock()
        activeLayoutGenSnapshot = layoutGeneration
        renderWindowLock.unlock()
        renderingKeys.removeAll()
        pageBitmapCache.removeAllObjects()
        for pv in mountedPageViews.values {
            pv.setReadingMode(mode)
        }
        updateVisiblePages(forceSharp: true)
    }

    /// Called by `TabManager` when switching between open document tabs.
    func setTabActive(_ active: Bool) {
        guard isTabActive != active else { return }
        isTabActive = active
        if active {
            if cgPDFDoc == nil {
                cgPDFDoc = CGPDFDocument(pdfURL as CFURL)
            }
            if currentReadingMode != AppSettings.shared.pdfReadingMode {
                applyReadingMode(AppSettings.shared.pdfReadingMode)
            }
            pencilRecognizer.pencilOnly = !AppSettings.shared.drawWithFinger
            updateVisiblePages(forceSharp: true)
            startLiveDriveSync()
            if activeTextEditor == nil {
                becomeFirstResponder()
            }
        } else {
            idleCheckWorkItem?.cancel()
            idleCheckWorkItem = nil
            scrollSettleWorkItem?.cancel()
            scrollSettleWorkItem = nil
            cancelHoldTimer()
            commitActiveTextBox()
            clearLassoSelection(commitFirst: true)
            saveNow(flushDriveImmediately: true)
            evictOffscreenBitmaps(keepOnlyVisible: false)
            // Release PDF handles on inactive tabs so 6 open textbooks use the RAM of 1!
            lazyPDFDoc = nil
            cgPDFDoc = nil
        }
    }

    private func evictOffscreenBitmaps(keepOnlyVisible: Bool) {
        pageBitmapCache.removeAllObjects()
        reusablePagePool.removeAll()
        if !isTabActive {
            lazyPDFDoc = nil
        }
        guard !mountedPageViews.isEmpty else { return }
        if !keepOnlyVisible && !isTabActive {
            for (key, pv) in mountedPageViews where pv !== activePageView && pv !== laserPageView {
                pv.prepareForReuse()
                pv.removeFromSuperview()
                mountedPageViews.removeValue(forKey: key)
            }
            lastMountedKeepRange = 0..<0
            return
        }
        let zoom = max(0.1, scrollView.zoomScale)
        let visibleInDoc = CGRect(
            x: scrollView.contentOffset.x / zoom,
            y: scrollView.contentOffset.y / zoom,
            width: scrollView.bounds.width / zoom,
            height: scrollView.bounds.height / zoom
        )
        let visRange = visibleIndexRange(for: visibleInDoc)
        for (key, pv) in mountedPageViews where pv !== activePageView && pv !== laserPageView {
            if let idx = slotIndexByKey[key], !visRange.contains(idx) {
                pv.prepareForReuse()
                pv.removeFromSuperview()
                mountedPageViews.removeValue(forKey: key)
            }
        }
        lastMountedKeepRange = 0..<0
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if isTabActive && activeTextEditor == nil {
            becomeFirstResponder()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !didInitialLayout && view.bounds.width > 0 && !pageSlots.isEmpty {
            didInitialLayout = true
            lastLayoutWidth = view.bounds.width
            fitToWidth()
            let savedPage = UserDefaults.standard.integer(forKey: lastPageStorageKey)
            if savedPage > 1 && savedPage <= pageSlots.count {
                jumpToPage(savedPage, animated: false)
            }
            updateVisiblePages(forceSharp: true)
        } else if didInitialLayout {
            if abs(view.bounds.width - lastLayoutWidth) > 4 {
                let wasNearFit = baseFitScale <= 0 || abs(scrollView.zoomScale - baseFitScale) / max(0.01, baseFitScale) < 0.08
                let keepPage = toolState.currentPage
                lastLayoutWidth = view.bounds.width
                if wasNearFit {
                    fitToWidth()
                    jumpToPage(keepPage, animated: false)
                } else if documentContainer.bounds.width > 0 {
                    let fit = view.bounds.width / documentContainer.bounds.width
                    baseFitScale = fit
                    scrollView.minimumZoomScale = fit * 0.55
                    scrollView.maximumZoomScale = fit * 6.0
                    centerContentIfNeeded()
                }
                updateVisiblePages(forceSharp: true)
            } else {
                centerContentIfNeeded()
            }
        }
    }

    func cancelAllPendingIO() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        idleCheckWorkItem?.cancel()
        idleCheckWorkItem = nil
        isDirty = false
        syncManager?.cancelScheduledSync(for: relativePath)
    }

    /// Synchronously commits any pending edits to disk BEFORE moving/renaming the file on disk.
    func saveSynchronouslyBeforeRename() {
        commitActiveTextBox()
        clearLassoSelection(commitFirst: true)
        saveWorkItem?.cancel()
        saveWorkItem = nil
        idleCheckWorkItem?.cancel()
        idleCheckWorkItem = nil
        syncManager?.cancelScheduledSync(for: relativePath)
        guard isDirty else { return }
        isDirty = false
        var snapshot = inkDoc
        snapshot.name = relativePath
        try? snapshot.save(for: pdfURL)
        toolState.saveStatus = "Saved"
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        idleCheckWorkItem?.cancel()
        idleCheckWorkItem = nil
        cancelHoldTimer()
        commitActiveTextBox()
        clearLassoSelection(commitFirst: true)
        stopLaserLoop()
        saveNow(flushDriveImmediately: true)
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

        // Scroll pan touch types adapt automatically: Hand Mode lets stylus/mouse/finger pan smoothly!
        scrollView.panGestureRecognizer.minimumNumberOfTouches = 1
        scrollView.panGestureRecognizer.maximumNumberOfTouches = 1
        scrollView.pinchGestureRecognizer?.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        updateScrollPanTouchTypes()
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
        pencilRecognizer.shouldAcceptTouch = { [weak self] touch in
            guard let self else { return false }
            // Never steal touches inside an active inline Text Box editor!
            if let ed = self.activeTextEditor {
                let pt = touch.location(in: ed)
                if ed.bounds.insetBy(dx: -16, dy: -16).contains(pt) {
                    return false
                }
            }
            // Hand / Scrolling mode & Text tool let scroll/tap gestures handle touches directly!
            if self.toolState.tool == .hand || self.toolState.tool == .text {
                return false
            }
            return true
        }
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
        twoFingerTapRecognizer = twoFingerTap
        threeFingerTapRecognizer = threeFingerTap

        let textTap = UITapGestureRecognizer(target: self, action: #selector(handleTextToolTap(_:)))
        textTap.numberOfTouchesRequired = 1
        textTap.numberOfTapsRequired = 1
        textTap.cancelsTouchesInView = false
        textTap.delaysTouchesBegan = false
        textTap.delaysTouchesEnded = false
        textTap.delegate = self
        scrollView.addGestureRecognizer(textTap)
        textTapRecognizer = textTap

        let handDoubleTap = UITapGestureRecognizer(target: self, action: #selector(handleHandDoubleTap(_:)))
        handDoubleTap.numberOfTouchesRequired = 1
        handDoubleTap.numberOfTapsRequired = 2
        handDoubleTap.cancelsTouchesInView = false
        handDoubleTap.delaysTouchesBegan = false
        handDoubleTap.delaysTouchesEnded = false
        handDoubleTap.delegate = self
        scrollView.addGestureRecognizer(handDoubleTap)
        handDoubleTapRecognizer = handDoubleTap
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === handDoubleTapRecognizer {
            return toolState.tool == .hand && activeTextEditor == nil
        }
        if gestureRecognizer === textTapRecognizer {
            return toolState.tool == .text || activeTextEditor != nil
        }
        if gestureRecognizer === twoFingerTapRecognizer || gestureRecognizer === threeFingerTapRecognizer {
            return AppSettings.shared.fingerTapUndoRedo && activePageView == nil
        }
        return true
    }

    @objc private func handleHandDoubleTap(_ gr: UITapGestureRecognizer) {
        guard toolState.tool == .hand, activeTextEditor == nil, baseFitScale > 0 else { return }
        let cur = scrollView.zoomScale
        if abs(cur - baseFitScale) / max(0.01, baseFitScale) > 0.08 {
            // Snap cleanly back to Fit-to-Width
            isSnappingZoom = true
            scrollView.setZoomScale(baseFitScale, animated: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
                guard let self else { return }
                self.isSnappingZoom = false
                self.centerContentIfNeeded()
                self.updateVisiblePages(forceSharp: true)
            }
            Haptics.light()
            toolState.showToast("Fit to width")
        } else {
            // Zoom cleanly to 1.75x centered on the tapped point
            let targetScale = min(scrollView.maximumZoomScale, baseFitScale * 1.75)
            let tapPt = gr.location(in: documentContainer)
            let w = scrollView.bounds.width / targetScale
            let h = scrollView.bounds.height / targetScale
            let zoomRect = CGRect(x: tapPt.x - w * 0.5, y: tapPt.y - h * 0.5, width: w, height: h)
            scrollView.zoom(to: zoomRect, animated: true)
            Haptics.light()
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UITapGestureRecognizer && otherGestureRecognizer is UITapGestureRecognizer {
            return false
        }
        return true
    }

    @objc private func handleTwoFingerTap() {
        guard AppSettings.shared.fingerTapUndoRedo, activePageView == nil, CACurrentMediaTime() - lastPencilUpTime > 0.16 else { return }
        if !undoStack.isEmpty {
            performUndo()
            Haptics.light()
            toolState.showToast("Undo")
        }
    }

    @objc private func handleThreeFingerTap() {
        guard AppSettings.shared.fingerTapUndoRedo, activePageView == nil, CACurrentMediaTime() - lastPencilUpTime > 0.16 else { return }
        if !redoStack.isEmpty {
            performRedo()
            Haptics.light()
            toolState.showToast("Redo")
        }
    }

    func updateScrollPanTouchTypes() {
        if toolState.tool == .hand {
            scrollView.panGestureRecognizer.allowedTouchTypes = [
                NSNumber(value: UITouch.TouchType.direct.rawValue),
                NSNumber(value: UITouch.TouchType.pencil.rawValue),
                NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
            ]
        } else {
            scrollView.panGestureRecognizer.allowedTouchTypes = [
                NSNumber(value: UITouch.TouchType.direct.rawValue)
            ]
        }
    }

    func onToolChanged(to newTool: DrawingTool) {
        updateScrollPanTouchTypes()
        if newTool != .lasso && lassoSelection != nil {
            clearLassoSelection(commitFirst: true)
        }
        if newTool != .text && activeTextEditor != nil {
            commitActiveTextBox()
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
        let targetY = max(0, pageFrames[idx].minY * zoom - 16)
        let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom)
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: min(targetY, maxY)), animated: animated)
        updateCurrentPageLabel()
        updateVisiblePages(forceSharp: true)
    }

    // MARK: - PDF Loading & Page Slot Rebuilding

    private func ensurePDFKitDocument() -> PDFDocument? {
        if let doc = lazyPDFDoc { return doc }
        let opened = PDFDocument(url: pdfURL)
        lazyPDFDoc = opened
        return opened
    }

    private func loadPDF() {
        guard let cgDoc = CGPDFDocument(pdfURL as CFURL) else {
            // Fallback to PDFKit only if CGPDFDocument fails (e.g., encrypted edge case)
            guard let doc = PDFDocument(url: pdfURL) else { return }
            lazyPDFDoc = doc
            let count = doc.pageCount
            pdfPageSizes = (0..<count).map { i in
                doc.page(at: i).map { PageCanvasView.normalizedPageSize(for: $0) } ?? CGSize(width: 595, height: 842)
            }
            rebuildPageViews(focusKey: nil)
            return
        }

        cgPDFDoc = cgDoc
        let count = cgDoc.numberOfPages
        guard count > 0 else { return }

        let firstSize = cgDoc.page(at: 1).map { PageCanvasView.normalizedPageSize(for: $0) } ?? CGSize(width: 595, height: 842)

        if count <= 250 {
            pdfPageSizes.removeAll()
            pdfPageSizes.reserveCapacity(count)
            for i in 1...count {
                let sz = cgDoc.page(at: i).map { PageCanvasView.normalizedPageSize(for: $0) } ?? firstSize
                pdfPageSizes.append(sz)
            }
            rebuildPageViews(focusKey: nil)
        } else {
            // Instant <15ms open for 2,000+ page medical textbooks: seed uniform size immediately,
            // then verify exact page sizes off the main thread and only relayout if any page differs!
            pdfPageSizes = Array(repeating: firstSize, count: count)
            rebuildPageViews(focusKey: nil)

            let url = pdfURL
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let bgDoc = CGPDFDocument(url as CFURL), bgDoc.numberOfPages == count else { return }
                var exactSizes: [CGSize] = []
                exactSizes.reserveCapacity(count)
                var anyDifferent = false
                for i in 1...count {
                    let sz = bgDoc.page(at: i).map { PageCanvasView.normalizedPageSize(for: $0) } ?? firstSize
                    if abs(sz.width - firstSize.width) > 1.0 || abs(sz.height - firstSize.height) > 1.0 {
                        anyDifferent = true
                    }
                    exactSizes.append(sz)
                }
                guard anyDifferent else { return }
                DispatchQueue.main.async {
                    guard let self, self.pdfPageSizes.count == count else { return }
                    self.pdfPageSizes = exactSizes
                    self.rebuildPageViews(focusKey: nil)
                }
            }
        }
    }

    /// Virtualized layout: computes pure `CGRect` frames for all pages in O(N) with ZERO upfront UIViews!
    /// Only pages within the active viewport window are mounted as subviews — locking 2,000+ page PDFs to 60/120 FPS.
    private func rebuildPageViews(focusKey: String?) {
        let wasLaidOut = didInitialLayout
        let prevZoom = wasLaidOut ? scrollView.zoomScale : 1.0
        let keepKey = focusKey ?? pageSlots[safe: toolState.currentPage - 1]?.key

        // Cache currently mounted PDF bitmaps before tearing down subviews so unchanged pages never flash blank
        for (key, pv) in mountedPageViews {
            if !pv.isTemplateOnly, pv.isRendered, let img = pv.renderedImage {
                pageBitmapCache.setObject(
                    CachedPageBitmap(image: img, zoomScale: pv.renderedZoomScale, readingMode: currentReadingMode),
                    forKey: key as NSString,
                    cost: estimatedImageCost(img)
                )
            }
        }

        isRebuildingPages = true
        layoutGeneration += 1
        renderWindowLock.lock()
        activeLayoutGenSnapshot = layoutGeneration
        renderWindowLock.unlock()
        renderingKeys.removeAll()
        lastMountedKeepRange = 0..<0

        if wasLaidOut && abs(scrollView.zoomScale - 1.0) > 0.0001 {
            scrollView.minimumZoomScale = min(scrollView.minimumZoomScale, 1.0)
            scrollView.maximumZoomScale = max(scrollView.maximumZoomScale, 1.0)
            scrollView.setZoomScale(1.0, animated: false)
        }

        for pv in mountedPageViews.values { recycleOrRemove(pv) }
        mountedPageViews.removeAll()
        pageFrames.removeAll()
        slotIndexByKey.removeAll()

        let defSize = pdfPageSizes.first ?? CGSize(width: 595, height: 842)
        isHoboDoc = HobonichiEngine.isHobonichi(doc: inkDoc, pdfPageCount: pdfPageSizes.count, firstPageSize: pdfPageSizes.first)
        pageSlots = inkDoc.buildPageSlots(pdfPageSizes: pdfPageSizes, defaultSize: defSize)

        let gap: CGFloat = 18
        let topPad: CGFloat = 22
        let bottomPad: CGFloat = 76
        var maxW: CGFloat = 595
        for s in pageSlots {
            if s.size.width > maxW { maxW = s.size.width }
        }
        let sidePad: CGFloat = 16
        let containerW = maxW + sidePad * 2
        var y = topPad

        pageFrames.reserveCapacity(pageSlots.count)
        for (idx, slot) in pageSlots.enumerated() {
            let x = (containerW - slot.size.width) * 0.5
            pageFrames.append(CGRect(x: x, y: y, width: slot.size.width, height: slot.size.height))
            slotIndexByKey[slot.key] = idx
            y += slot.size.height + gap
        }

        let totalH = max(200, y - gap + bottomPad)
        documentContainer.transform = .identity
        documentContainer.frame = CGRect(x: 0, y: 0, width: containerW, height: totalH)
        scrollView.contentSize = CGSize(width: containerW, height: totalH)

        if wasLaidOut && view.bounds.width > 0 {
            let fit = view.bounds.width / max(1, containerW)
            baseFitScale = fit
            scrollView.minimumZoomScale = fit * 0.55
            scrollView.maximumZoomScale = fit * 6.0
            let clampedZoom = max(scrollView.minimumZoomScale, min(scrollView.maximumZoomScale, prevZoom))
            scrollView.setZoomScale(clampedZoom, animated: false)
            centerContentIfNeeded()
        }

        isRebuildingPages = false
        syncDocumentMetadataToUI()

        if wasLaidOut {
            if let fk = keepKey, let targetIdx = slotIndexByKey[fk] {
                jumpToPage(targetIdx + 1, animated: false)
            } else {
                updateCurrentPageLabel()
                updateVisiblePages(forceSharp: true)
            }
        }
    }

    private func estimatedImageCost(_ image: UIImage) -> Int {
        if let cg = image.cgImage {
            return cg.bytesPerRow * cg.height
        }
        let pxW = Int(image.size.width * image.scale)
        let pxH = Int(image.size.height * image.scale)
        return max(1024, pxW * pxH * 4)
    }

    private func recycleOrRemove(_ pv: PageCanvasView) {
        let recyclable = pv.isRecyclablePDFPage
        pv.prepareForReuse()
        pv.removeFromSuperview()
        if recyclable && reusablePagePool.count < 8 {
            reusablePagePool.append(pv)
        }
    }

    @discardableResult
    private func mountPageView(at idx: Int) -> PageCanvasView {
        let slot = pageSlots[idx]
        if let existing = mountedPageViews[slot.key] {
            return existing
        }
        let pv: PageCanvasView
        if !isHoboDoc && slot.effectivePDFPageNumber != nil, let pooled = reusablePagePool.popLast() {
            pv = pooled
            pv.configure(
                slot: slot,
                hoboDoc: inkDoc,
                hoboAllSlots: pageSlots,
                isHobo: isHoboDoc,
                readingMode: currentReadingMode
            )
        } else {
            pv = PageCanvasView(
                slot: slot,
                hoboDoc: inkDoc,
                hoboAllSlots: pageSlots,
                isHobo: isHoboDoc,
                readingMode: currentReadingMode
            )
        }
        pv.frame = pageFrames[idx]
        let hiddenStrokes = (lassoSelection?.pageKey == slot.key) ? (lassoSelection?.hiddenStrokeIDs ?? []) : []
        if let strokes = inkDoc.pages[slot.key], !strokes.isEmpty {
            pv.setStrokes(strokes, hiddenIDs: hiddenStrokes)
        }
        let hiddenTextID = (activeTextEditor?.pageKey == slot.key) ? activeTextEditor?.originalBox?.id : nil
        if let tBoxes = inkDoc.texts[slot.key], !tBoxes.isEmpty {
            pv.setTextBoxes(tBoxes, hiddenID: hiddenTextID)
        }
        if let cached = pageBitmapCache.object(forKey: slot.key as NSString),
           cached.readingMode == currentReadingMode {
            pv.applyRenderedImage(cached.image, zoomScale: cached.zoomScale)
        } else if pv.isTemplateOnly {
            pv.refreshVectorScale(for: max(0.5, scrollView.zoomScale))
        }
        documentContainer.addSubview(pv)
        if let ed = activeTextEditor {
            documentContainer.bringSubviewToFront(ed)
        }
        mountedPageViews[slot.key] = pv
        return pv
    }

    /// O(log N) binary search for the first page whose `maxY >= y`.
    private func firstPageIndex(withMaxYAtLeast y: CGFloat) -> Int {
        var lo = 0
        var hi = pageFrames.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if pageFrames[mid].maxY < y {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }

    /// O(log N) binary search for the index range of pages intersecting `rect`.
    private func visibleIndexRange(for rect: CGRect) -> Range<Int> {
        guard !pageFrames.isEmpty else { return 0..<0 }
        let start = firstPageIndex(withMaxYAtLeast: rect.minY)
        if start >= pageFrames.count { return pageFrames.count..<pageFrames.count }
        var lo = start
        var hi = pageFrames.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if pageFrames[mid].minY <= rect.maxY {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return start..<lo
    }

    private func syncDocumentMetadataToUI() {
        let slotsCopy = pageSlots
        let marked = Set(inkDoc.bookmarks.filter { $0.value.on }.keys)
        let removedCount = inkDoc.removedCount
        let hobo = isHoboDoc
        let curIdx = max(0, min(slotsCopy.count - 1, toolState.currentPage - 1))
        let curSlot = slotsCopy[safe: curIdx]
        let label = (hobo && curSlot != nil) ? HobonichiEngine.slotLabel(for: curSlot!, doc: inkDoc) : ""
        let onNotes = hobo && curSlot != nil && (curSlot!.pdfN == 2 || curSlot!.blank?.kind == "hobo-notes")
        if hobo, let firstSlot = slotsCopy.first, firstSlot.pdfN == 1, let pv0 = mountedPageViews[firstSlot.key] {
            pv0.updateHobonichiData(doc: inkDoc, allSlots: slotsCopy)
        }
        DispatchQueue.main.async {
            self.toolState.pageSlots = slotsCopy
            self.toolState.totalPages = max(1, slotsCopy.count)
            self.toolState.bookmarkedKeys = marked
            self.toolState.removedPagesCount = removedCount
            self.toolState.isHobonichi = hobo
            self.toolState.currentSlotLabel = label
            self.toolState.isOnHoboNotes = onNotes
            if self.toolState.currentPage > slotsCopy.count {
                self.toolState.currentPage = max(1, slotsCopy.count)
            }
        }
    }

    private func fitToWidth() {
        guard documentContainer.bounds.width > 0, view.bounds.width > 0 else { return }
        let fit = view.bounds.width / documentContainer.bounds.width
        baseFitScale = fit
        scrollView.minimumZoomScale = fit * 0.55
        scrollView.maximumZoomScale = fit * 6.0
        scrollView.setZoomScale(fit, animated: false)
        centerContentIfNeeded()
        scrollView.contentOffset.x = -scrollView.contentInset.left
    }

    private func centerContentIfNeeded() {
        let boundsSize = scrollView.bounds.size
        let contentSize = scrollView.contentSize
        let insetX = max(0, (boundsSize.width - contentSize.width) * 0.5)
        let insetY = max(0, (boundsSize.height - contentSize.height) * 0.5)
        let target = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
        if abs(scrollView.contentInset.left - target.left) > 0.5 || abs(scrollView.contentInset.top - target.top) > 0.5 {
            scrollView.contentInset = target
        }
    }

    /// Magnetic Snap-to-Fit-Width for both iPad pinch and macOS trackpad pinch!
    private func finishZoomInteraction() {
        zoomSettleWorkItem?.cancel()
        zoomSettleWorkItem = nil
        guard !isRebuildingPages, !isSnappingZoom, baseFitScale > 0 else { return }

        let cur = scrollView.zoomScale
        let lowerSnap = baseFitScale * 0.78
        let upperSnap = baseFitScale * 1.12
        let needsSnap = (cur >= lowerSnap && cur <= upperSnap && abs(cur - baseFitScale) / baseFitScale > 0.004)

        if needsSnap {
            isSnappingZoom = true
            let keepY = scrollView.contentOffset.y * (baseFitScale / max(0.01, cur))
            UIView.animate(
                withDuration: 0.22,
                delay: 0,
                usingSpringWithDamping: 0.92,
                initialSpringVelocity: 0,
                options: [.allowUserInteraction, .beginFromCurrentState]
            ) {
                self.scrollView.zoomScale = self.baseFitScale
                self.centerContentIfNeeded()
                let maxY = max(-self.scrollView.contentInset.top, self.scrollView.contentSize.height - self.scrollView.bounds.height + self.scrollView.contentInset.bottom)
                let clampedY = max(-self.scrollView.contentInset.top, min(maxY, keepY))
                self.scrollView.contentOffset = CGPoint(x: -self.scrollView.contentInset.left, y: clampedY)
            } completion: { [weak self] _ in
                guard let self else { return }
                self.isSnappingZoom = false
                self.centerContentIfNeeded()
                self.updateVisiblePages(forceSharp: true)
                if let sel = self.lassoSelection, let pv = self.pageView(forKey: sel.pageKey) {
                    pv.updateLasso(selection: sel, zoomScale: self.scrollView.zoomScale)
                }
            }
            Haptics.light()
            return
        }

        centerContentIfNeeded()
        updateVisiblePages(forceSharp: true)
        if let sel = lassoSelection, let pv = pageView(forKey: sel.pageKey) {
            pv.updateLasso(selection: sel, zoomScale: scrollView.zoomScale)
        }
    }

    // MARK: - UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        documentContainer
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        guard !isRebuildingPages else { return }
        centerContentIfNeeded()
        guard !isSnappingZoom else { return }
        // Debounced settle check ensures macOS trackpad pinch-to-zoom ALSO snaps cleanly to Fit-to-Width & sharpens!
        zoomSettleWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.scrollView.isZooming, !self.scrollView.isZoomBouncing else { return }
            self.finishZoomInteraction()
        }
        zoomSettleWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: item)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isRebuildingPages else { return }
        let now = CACurrentMediaTime()
        let curY = scrollView.contentOffset.y
        let dt = now - lastScrollSampleTime
        if dt > 0.004 && dt < 0.25 {
            let inst = abs(curY - lastScrollOffsetY) / CGFloat(dt)
            scrollVelocityPtsPerSec = scrollVelocityPtsPerSec * 0.45 + inst * 0.55
        } else {
            scrollVelocityPtsPerSec = 0
        }
        lastScrollSampleTime = now
        lastScrollOffsetY = curY

        updateCurrentPageLabel()
        updateVisiblePages(forceSharp: false)

        // Ensure macOS trackpad / mouse-wheel scrolls (which don't always call scrollViewDidEndDecelerating)
        // sharpen cleanly ~110ms after scrolling settles!
        scrollSettleWorkItem?.cancel()
        let settle = DispatchWorkItem { [weak self] in
            guard let self, !self.isRebuildingPages else { return }
            self.scrollVelocityPtsPerSec = 0
            self.updateVisiblePages(forceSharp: true)
        }
        scrollSettleWorkItem = settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11, execute: settle)
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        guard !isRebuildingPages else { return }
        finishZoomInteraction()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard !isRebuildingPages, !decelerate else { return }
        scrollVelocityPtsPerSec = 0
        updateVisiblePages(forceSharp: true)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard !isRebuildingPages else { return }
        scrollVelocityPtsPerSec = 0
        updateVisiblePages(forceSharp: true)
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard !isRebuildingPages else { return }
        scrollVelocityPtsPerSec = 0
        updateCurrentPageLabel()
        updateVisiblePages(forceSharp: true)
    }

    private func updateCurrentPageLabel() {
        guard !pageFrames.isEmpty else { return }
        let zoom = max(0.01, scrollView.zoomScale)
        let midY = (scrollView.contentOffset.y + scrollView.bounds.height * 0.4) / zoom
        let idx = min(pageFrames.count - 1, firstPageIndex(withMaxYAtLeast: midY))
        let current = idx + 1
        if toolState.currentPage != current {
            // Debounce UserDefaults disk IPC by 1.2s so scrolling 100 pages does ZERO disk writes mid-scroll!
            pagePersistWorkItem?.cancel()
            let key = lastPageStorageKey
            let pItem = DispatchWorkItem {
                UserDefaults.standard.set(current, forKey: key)
            }
            pagePersistWorkItem = pItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: pItem)

            let slot = pageSlots[safe: idx]
            let label = (isHoboDoc && slot != nil) ? HobonichiEngine.slotLabel(for: slot!, doc: inkDoc) : ""
            let onNotes = isHoboDoc && slot != nil && (slot!.pdfN == 2 || slot!.blank?.kind == "hobo-notes")
            if isHoboDoc, let s = slot, s.blank?.anchor == 1 {
                lastHoboPlannerKey = s.key
            }
            // Updates isolated NotebookHUDState directly on main thread (ZERO NotebookScreen body rebuilds!)
            self.toolState.currentPage = current
            self.toolState.currentSlotLabel = label
            self.toolState.isOnHoboNotes = onNotes
        }
    }

    private func updateVisiblePages(forceSharp: Bool) {
        guard isTabActive, !isRebuildingPages, !pageSlots.isEmpty else { return }
        let zoom = max(0.1, scrollView.zoomScale)
        let visibleInDoc = CGRect(
            x: scrollView.contentOffset.x / zoom,
            y: scrollView.contentOffset.y / zoom,
            width: scrollView.bounds.width / zoom,
            height: scrollView.bounds.height / zoom
        )

        let visRange = visibleIndexRange(for: visibleInDoc)
        let renderLo = max(0, visRange.lowerBound - 1)
        let renderHi = min(pageSlots.count, visRange.upperBound + 1)
        let renderRange = renderLo..<renderHi

        let keepLo = max(0, visRange.lowerBound - 2)
        let keepHi = min(pageSlots.count, visRange.upperBound + 2)
        let keepRange = keepLo..<keepHi

        // Fast-path recycle of offscreen views ONLY when the keep window actually moved!
        if keepRange != lastMountedKeepRange {
            lastMountedKeepRange = keepRange
            let protectedKeys: Set<String> = Set([
                activePageView?.pageKey,
                laserPageView?.pageKey,
                lassoSelection?.pageKey,
                activeTextEditor?.pageKey
            ].compactMap { $0 })

            for (key, pv) in mountedPageViews {
                if protectedKeys.contains(key) { continue }
                if let idx = slotIndexByKey[key], keepRange.contains(idx) { continue }
                if !pv.isTemplateOnly, pv.isRendered, let img = pv.renderedImage {
                    pageBitmapCache.setObject(
                        CachedPageBitmap(image: img, zoomScale: pv.renderedZoomScale, readingMode: currentReadingMode),
                        forKey: key as NSString,
                        cost: estimatedImageCost(img)
                    )
                }
                mountedPageViews.removeValue(forKey: key)
                recycleOrRemove(pv)
            }

            // Mount only the tiny window of nearby pages (typically 4–7 recycled views total!)
            for idx in keepRange {
                _ = mountPageView(at: idx)
            }
        }

        // Publish current render window immediately so stale queued pages abort in microseconds
        let cgDoc = cgPDFDoc
        let fallbackPDFDoc = lazyPDFDoc
        let gen = layoutGeneration
        let mode = currentReadingMode
        renderWindowLock.lock()
        activeRenderWindow = keepRange
        activeLayoutGenSnapshot = gen
        renderWindowLock.unlock()

        // Velocity Gate (Toaster Mode): during rapid 2,000-page flicks (> 2400 pt/s), NEVER saturate CPU/GPU
        // with throwaway page renders — serve instant cache hits / crisp paper sheets at locked 60/120 FPS,
        // and render immediately once velocity eases or scroll settles!
        if !forceSharp && scrollVelocityPtsPerSec > 2400 {
            return
        }

        let screenScale = max(1.0, traitCollection.displayScale > 0 ? traitCollection.displayScale : 2.0)
        #if targetEnvironment(macCatalyst)
        let dScale: CGFloat = forceSharp ? min(screenScale, 2.0) : min(screenScale, 1.5)
        let maxPx: CGFloat = forceSharp ? 3_200_000 : 2_000_000
        let maxConcurrentRenders = forceSharp ? 3 : 2
        #else
        let dScale: CGFloat = forceSharp ? min(screenScale, 2.0) : min(screenScale, 1.65)
        let maxPx: CGFloat = forceSharp ? 4_800_000 : 2_800_000
        let maxConcurrentRenders = 3
        #endif

        // Center-First Priority: render the page closest to the middle of the screen FIRST!
        let midY = visibleInDoc.midY
        let prioritized = Array(renderRange).sorted { a, b in
            abs(pageFrames[a].midY - midY) < abs(pageFrames[b].midY - midY)
        }

        for idx in prioritized {
            let pv = mountPageView(at: idx)
            if pv.isTemplateOnly {
                if forceSharp {
                    pv.refreshVectorScale(for: zoom)
                }
                continue
            }
            let effectiveTargetScale = zoom * (dScale / 2.0)
            let needScale = !pv.isRendered || (forceSharp && abs(pv.renderedZoomScale - effectiveTargetScale) / max(0.1, pv.renderedZoomScale) > 0.18)
            guard needScale, !renderingKeys.contains(pv.pageKey) else { continue }
            if renderingKeys.count >= maxConcurrentRenders { break }
            renderingKeys.insert(pv.pageKey)
            let slot = pv.slot
            let pageIdx = idx
            let targetZoom = zoom
            let useFast = !forceSharp
            renderQueue.async { [weak self, weak pv] in
                guard let self else { return }
                self.renderWindowLock.lock()
                let stillRelevant = (self.activeLayoutGenSnapshot == gen) && self.activeRenderWindow.contains(pageIdx)
                self.renderWindowLock.unlock()
                guard stillRelevant else {
                    DispatchQueue.main.async {
                        if self.layoutGeneration == gen {
                            self.renderingKeys.remove(slot.key)
                        }
                    }
                    return
                }
                let img = PageCanvasView.renderSlotBackground(
                    slot: slot,
                    cgPDFDoc: cgDoc,
                    pdfDoc: fallbackPDFDoc,
                    zoomScale: targetZoom,
                    maxPixels: maxPx,
                    readingMode: mode,
                    displayScale: dScale,
                    fastQuality: useFast
                )
                let cost = self.estimatedImageCost(img)
                DispatchQueue.main.async {
                    guard self.layoutGeneration == gen else { return }
                    self.renderingKeys.remove(slot.key)
                    self.pageBitmapCache.setObject(
                        CachedPageBitmap(image: img, zoomScale: effectiveTargetScale, readingMode: mode),
                        forKey: slot.key as NSString,
                        cost: cost
                    )
                    pv?.applyRenderedImage(img, zoomScale: effectiveTargetScale)
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
        let srcTexts = inkDoc.texts[slot.key] ?? []
        if !srcTexts.isEmpty {
            let copiedTexts: [InkTextBox] = srcTexts.map { tb in
                var c = tb
                c.id = InkStroke.newID()
                return c
            }
            inkDoc.texts[InkDocument.blankKey(blank.id)] = copiedTexts
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


    // MARK: - Hobonichi Techo Weeks Navigation & Auto-Expansion

    func jumpToHoboIndex() {
        guard isHoboDoc else { return }
        if let cur = pageSlots[safe: toolState.currentPage - 1], cur.blank?.anchor == 1 {
            lastHoboPlannerKey = cur.key
        }
        jumpToPage(1, animated: true)
    }

    func jumpToHoboCurrentWeek() {
        guard isHoboDoc else { return }
        let monStr = HobonichiEngine.dateStr(HobonichiEngine.mondayOf(Date()))
        let targetKey = InkDocument.blankKey("hw-\(monStr)")
        if let idx = pageSlots.firstIndex(where: { $0.key == targetKey }) {
            lastHoboPlannerKey = targetKey
            jumpToPage(idx + 1, animated: true)
            return
        }
        // Auto-expand current week + next 4 weeks so "This Week" always lands on today's spread!
        let added = HobonichiEngine.buildPlannerEntries(
            startDate: Date(),
            numWeeks: 4,
            existingBlanks: inkDoc.blanks,
            startNotePages: 0
        )
        if !added.isEmpty {
            for b in added { inkDoc.blanks[b.id] = b }
            inkDoc.layoutBlanks()
            rebuildPageViews(focusKey: targetKey)
            scheduleSave()
            toolState.showToast("Expanded journal to this week")
        }
    }

    func toggleHoboNotesRibbon() {
        guard isHoboDoc else { return }
        let curSlot = pageSlots[safe: toolState.currentPage - 1]
        let onNotes = (curSlot?.pdfN == 2 || curSlot?.blank?.kind == "hobo-notes")
        if onNotes {
            if let key = lastHoboPlannerKey, let idx = pageSlots.firstIndex(where: { $0.key == key }) {
                jumpToPage(idx + 1, animated: true)
            } else {
                jumpToHoboCurrentWeek()
            }
        } else {
            if let cur = curSlot, cur.blank?.anchor == 1 {
                lastHoboPlannerKey = cur.key
            }
            if let notesIdx = pageSlots.firstIndex(where: { $0.pdfN == 2 || $0.blank?.kind == "hobo-notes" }) {
                jumpToPage(notesIdx + 1, animated: true)
            }
        }
    }

    func expandHoboWeeks(_ count: Int) {
        guard isHoboDoc else { return }
        var latestDate = HobonichiEngine.mondayOf(Date())
        for b in inkDoc.blanks.values where b.kind == "hobo-week" {
            let d = HobonichiEngine.parseDate(b.monday)
            if d > latestDate { latestDate = d }
        }
        let nextStart = HobonichiEngine.calendar.date(byAdding: .day, value: 7, to: latestDate) ?? latestDate
        let added = HobonichiEngine.buildPlannerEntries(
            startDate: nextStart,
            numWeeks: count,
            existingBlanks: inkDoc.blanks,
            startNotePages: 0
        )
        guard !added.isEmpty else { return }
        for b in added { inkDoc.blanks[b.id] = b }
        inkDoc.layoutBlanks()
        let firstNewKey = InkDocument.blankKey(added[0].id)
        rebuildPageViews(focusKey: firstNewKey)
        scheduleSave()
        toolState.showToast("Added +\(count) weeks to journal")
    }

    func addHoboBackNotesPage() {
        guard isHoboDoc else { return }
        var maxNum = 1
        for b in inkDoc.blanks.values where b.kind == "hobo-notes" {
            if let n = b.noteNum, n > maxNum { maxNum = n }
        }
        let nextNum = maxNum + 1
        let id = "hn-\(nextNum)-\(Int(Date().timeIntervalSince1970) % 10000)"
        var b = BlankPage(
            id: id,
            anchor: 2,
            parent: "2",
            ord: nextNum,
            w: Double(HobonichiEngine.pageWidth),
            h: Double(HobonichiEngine.pageHeight),
            t: Int64(1000 + nextNum)
        )
        b.kind = "hobo-notes"
        b.noteNum = nextNum
        inkDoc.blanks[b.id] = b
        inkDoc.layoutBlanks()
        let key = InkDocument.blankKey(b.id)
        rebuildPageViews(focusKey: key)
        scheduleSave()
        toolState.showToast("Added Back Notes N-\(nextNum)")
    }


    // MARK: - PDF Outline (Table of Contents) & Text Search

    func extractPDFOutline() -> [PDFOutlineEntry] {
        guard let doc = ensurePDFKitDocument(), let root = doc.outlineRoot else { return [] }
        var out: [PDFOutlineEntry] = []
        var counter = 0

        func walk(_ node: PDFOutline, depth: Int) {
            let count = node.numberOfChildren
            for i in 0..<count {
                guard let child = node.child(at: i) else { continue }
                let label = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let destPage = child.destination?.page ?? (child.action as? PDFActionGoTo)?.destination.page
                if !label.isEmpty, let page = destPage {
                    let pdfIdx = doc.index(for: page)
                    if pdfIdx != NSNotFound {
                        let pdfN = pdfIdx + 1
                        let slotIdx = pageSlots.firstIndex(where: { $0.pdfN == pdfN }) ?? min(max(0, pdfIdx), max(0, pageSlots.count - 1))
                        counter += 1
                        out.append(PDFOutlineEntry(
                            id: "\(counter)-\(pdfN)",
                            title: label,
                            pageNumber: slotIdx + 1,
                            depth: min(depth, 3)
                        ))
                    }
                }
                if child.numberOfChildren > 0 && out.count < 800 {
                    walk(child, depth: depth + 1)
                }
            }
        }

        walk(root, depth: 0)
        return out
    }

    func searchPDFText(_ query: String, completion: @escaping ([PDFSearchHit]) -> Void) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, let doc = ensurePDFKitDocument() else {
            completion([])
            return
        }
        let slotsCopy = pageSlots
        renderQueue.async {
            let matches = doc.findString(trimmed, withOptions: [.caseInsensitive])
            var hits: [PDFSearchHit] = []
            var seenPages = Set<Int>()
            for (idx, sel) in matches.enumerated() {
                if hits.count >= 80 { break }
                guard let page = sel.pages.first else { continue }
                let pdfIdx = doc.index(for: page)
                guard pdfIdx != NSNotFound else { continue }
                let pdfN = pdfIdx + 1
                if seenPages.contains(pdfN) { continue }
                seenPages.insert(pdfN)

                let slotIdx = slotsCopy.firstIndex(where: { $0.pdfN == pdfN }) ?? min(max(0, pdfIdx), max(0, slotsCopy.count - 1))
                let snippet: String
                if let ext = sel.copy() as? PDFSelection {
                    ext.extend(atStart: 28)
                    ext.extend(atEnd: 48)
                    snippet = (ext.string ?? trimmed)
                        .replacingOccurrences(of: "\n", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    snippet = sel.string ?? trimmed
                }
                hits.append(PDFSearchHit(id: "\(pdfN)-\(idx)", pageNumber: slotIdx + 1, snippet: snippet))
            }
            DispatchQueue.main.async {
                completion(hits)
            }
        }
    }

    // MARK: - Thumbnails & Share / Export

    func renderThumbnailAsync(for slot: PageSlot, targetWidth: CGFloat, completion: @escaping (UIImage?) -> Void) {
        let cgDoc = cgPDFDoc
        let doc = lazyPDFDoc
        let strokes = inkDoc.pages[slot.key] ?? []
        let tBoxes = inkDoc.texts[slot.key] ?? []
        let hDoc = inkDoc
        let hSlots = pageSlots
        let hobo = isHoboDoc
        let scale = max(0.25, targetWidth / max(1, slot.size.width))
        renderQueue.async {
            let img = PageCanvasView.renderCompositeImage(slot: slot, cgPDFDoc: cgDoc, pdfDoc: doc, strokes: strokes, textBoxes: tBoxes, scale: scale, hoboDoc: hDoc, hoboAllSlots: hSlots, isHobo: hobo)
            DispatchQueue.main.async {
                completion(img)
            }
        }
    }

    func exportCurrentPagePNG() {
        commitActiveTextBox()
        clearLassoSelection(commitFirst: true)
        guard let slot = pageSlots[safe: toolState.currentPage - 1] else { return }
        let strokes = inkDoc.pages[slot.key] ?? []
        let tBoxes = inkDoc.texts[slot.key] ?? []
        let cgDoc = cgPDFDoc
        let doc = lazyPDFDoc
        let hDoc = inkDoc
        let hSlots = pageSlots
        let hobo = isHoboDoc
        let pageNum = toolState.currentPage
        let baseName = pdfURL.deletingPathExtension().lastPathComponent
        toolState.showToast("Rendering PNG…")
        renderQueue.async { [weak self] in
            let img = PageCanvasView.renderCompositeImage(slot: slot, cgPDFDoc: cgDoc, pdfDoc: doc, strokes: strokes, textBoxes: tBoxes, scale: 2.0, hoboDoc: hDoc, hoboAllSlots: hSlots, isHobo: hobo)
            guard let data = img.pngData() else { return }
            let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(baseName) - Page \(pageNum).png")
            do {
                try data.write(to: outURL, options: .atomic)
                DispatchQueue.main.async {
                    self?.presentShareSheet(items: [outURL])
                }
            } catch {
                DispatchQueue.main.async { self?.toolState.showToast("PNG export failed") }
            }
        }
    }

    func exportAnnotatedPDF() {
        commitActiveTextBox()
        clearLassoSelection(commitFirst: true)
        let slots = pageSlots
        guard !slots.isEmpty else { return }
        let cgDoc = cgPDFDoc
        let doc = lazyPDFDoc
        let hDoc = inkDoc
        let hobo = isHoboDoc
        let pagesCopy = inkDoc.pages
        let textsCopy = inkDoc.texts
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
                        PageCanvasView.drawSlotBackground(slot: slot, cgPDFDoc: cgDoc, pdfDoc: doc, in: cg, hoboDoc: hDoc, hoboAllSlots: slots, isHobo: hobo)
                        if let strokes = pagesCopy[slot.key], !strokes.isEmpty {
                            PageCanvasView.drawStrokes(strokes, in: cg)
                        }
                        if let tBoxes = textsCopy[slot.key], !tBoxes.isEmpty {
                            PageCanvasView.drawTextBoxes(tBoxes, in: cg)
                        }
                    }
                }
                DispatchQueue.main.async {
                    self?.presentShareSheet(items: [outURL])
                }
            } catch {
                DispatchQueue.main.async { self?.toolState.showToast("PDF export failed") }
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


    // MARK: - Text Box Tool (Create, Inline Edit, Drag, Resize, Style, Duplicate, Delete)

    private func syncTextBoxUIState() {
        let active = (activeTextEditor != nil)
        DispatchQueue.main.async {
            self.toolState.hasActiveTextBox = active
        }
    }

    @objc private func handleTextToolTap(_ gr: UITapGestureRecognizer) {
        guard gr.state == .ended else { return }

        // If an editor is open and user tapped inside it, let UITextView handle cursor placement
        if let ed = activeTextEditor {
            let ptInEd = gr.location(in: ed)
            if ed.bounds.insetBy(dx: -16, dy: -16).contains(ptInEd) {
                return
            }
            // Tapped outside the open text box -> commit it cleanly!
            commitActiveTextBox()
            if toolState.tool != .text { return }
        }

        guard toolState.tool == .text else { return }
        let docPt = gr.location(in: documentContainer)
        let idx = firstPageIndex(withMaxYAtLeast: docPt.y)
        guard idx < pageFrames.count, pageFrames[idx].contains(docPt) else { return }
        let pv = mountPageView(at: idx)
        let frame = pageFrames[idx]
        let localPt = CGPoint(x: docPt.x - frame.minX, y: docPt.y - frame.minY)

        // Check if user tapped an existing text box on this page (topmost first)
        let existing = inkDoc.texts[pv.pageKey] ?? []
        for tb in existing.reversed() {
            if tb.measuredRect().insetBy(dx: -8, dy: -8).contains(localPt) {
                openTextBoxEditor(for: tb, original: tb, on: pv, pageFrame: frame)
                return
            }
        }

        // Otherwise create a brand new text box right where the user tapped!
        let boxW = min(240.0, max(120.0, Double(pv.pageSize.width) - 24.0))
        let clampedX = max(10.0, min(Double(pv.pageSize.width) - boxW - 10.0, Double(localPt.x) - 10.0))
        let clampedY = max(10.0, min(Double(pv.pageSize.height) - 36.0, Double(localPt.y) - 10.0))
        let fresh = InkTextBox(
            x: (clampedX * 100).rounded() / 100,
            y: (clampedY * 100).rounded() / 100,
            w: (boxW * 100).rounded() / 100,
            text: "",
            fontSize: toolState.textSize,
            color: toolState.activeTextColorHex,
            fontName: toolState.textFont.rawValue,
            bold: toolState.textBold,
            bgColor: toolState.textBgHex.isEmpty ? nil : toolState.textBgHex
        )
        openTextBoxEditor(for: fresh, original: nil, on: pv, pageFrame: frame)
    }

    private func openTextBoxEditor(for box: InkTextBox, original: InkTextBox?, on pv: PageCanvasView, pageFrame: CGRect) {
        commitActiveTextBox()
        clearLassoSelection(commitFirst: true)

        // Sync toolbar controls to the selected text box's properties
        if let idx = toolState.textColors.firstIndex(where: { $0.caseInsensitiveCompare(box.color) == .orderedSame }) {
            toolState.textColorIndex = idx
        }
        toolState.textSize = box.fontSize
        toolState.textFont = TextFontOption(rawValue: box.fontName ?? "sans") ?? .sans
        toolState.textBold = (box.bold == true)
        toolState.textBgHex = box.bgColor ?? ""

        let editor = InlineTextBoxEditorView(
            pageKey: pv.pageKey,
            pageFrame: pageFrame,
            box: box,
            originalBox: original,
            smartDarkInk: (!pv.isHobonichiSlot && currentReadingMode == .dark)
        )
        editor.onChanged = { [weak self] _ in
            // User is actively typing/moving text box -> never sync mid-typing!
            guard let self else { return }
            self.idleCheckWorkItem?.cancel()
            self.syncManager?.cancelScheduledSync(for: self.relativePath)
        }
        editor.onCommitRequested = { [weak self] in
            self?.commitActiveTextBox()
        }
        idleCheckWorkItem?.cancel()
        syncManager?.cancelScheduledSync(for: relativePath)
        documentContainer.addSubview(editor)
        activeTextEditor = editor
        pv.setHiddenTextBoxID(original?.id)
        syncTextBoxUIState()
        editor.focusTextView()
    }

    func updateActiveTextBoxStyle() {
        guard let ed = activeTextEditor else { return }
        ed.box.color = toolState.activeTextColorHex
        ed.box.fontSize = toolState.textSize
        ed.box.fontName = toolState.textFont.rawValue
        ed.box.bold = toolState.textBold
        ed.box.bgColor = toolState.textBgHex.isEmpty ? nil : toolState.textBgHex
        ed.box.t = Int64(Date().timeIntervalSince1970 * 1000)
        ed.applyStyling()
    }

    func commitActiveTextBox() {
        guard let ed = activeTextEditor else { return }
        activeTextEditor = nil
        ed.resignFirstResponder()
        ed.removeFromSuperview()
        syncTextBoxUIState()
        if isTabActive {
            becomeFirstResponder()
        }

        let key = ed.pageKey
        let original = ed.originalBox
        var finalBox = ed.box
        let cleaned = finalBox.text.trimmingCharacters(in: .whitespacesAndNewlines)

        var list = inkDoc.texts[key] ?? []
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        if cleaned.isEmpty {
            // Empty box: discard if new, or delete if editing an existing box
            if let orig = original {
                list.removeAll { $0.id == orig.id }
                inkDoc.deleted[orig.id] = nowMs
                if list.isEmpty { inkDoc.texts.removeValue(forKey: key) }
                else { inkDoc.texts[key] = list }
                pageView(forKey: key)?.setTextBoxes(list, hiddenID: nil)
                pushUndo(.texts(pageKey: key, added: [], removed: [orig]))
                scheduleSave()
            } else {
                pageView(forKey: key)?.setHiddenTextBoxID(nil)
            }
            return
        }

        finalBox.t = nowMs
        if let orig = original {
            let changed = (orig.text != finalBox.text
                           || orig.x != finalBox.x || orig.y != finalBox.y || orig.w != finalBox.w
                           || orig.fontSize != finalBox.fontSize || orig.color != finalBox.color
                           || orig.fontName != finalBox.fontName || orig.bold != finalBox.bold
                           || orig.bgColor != finalBox.bgColor)
            if changed {
                list.removeAll { $0.id == orig.id }
                list.append(finalBox)
                inkDoc.texts[key] = list
                pageView(forKey: key)?.setTextBoxes(list, hiddenID: nil)
                pushUndo(.texts(pageKey: key, added: [finalBox], removed: [orig]))
                scheduleSave()
            } else {
                pageView(forKey: key)?.setHiddenTextBoxID(nil)
            }
        } else {
            list.append(finalBox)
            inkDoc.texts[key] = list
            pageView(forKey: key)?.setTextBoxes(list, hiddenID: nil)
            pushUndo(.texts(pageKey: key, added: [finalBox], removed: []))
            scheduleSave()
        }
    }

    func duplicateActiveTextBox() {
        guard let ed = activeTextEditor else { return }
        let key = ed.pageKey
        let pFrame = ed.pageFrame
        var copy = ed.box
        commitActiveTextBox()
        guard !copy.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let pv = pageView(forKey: key) else { return }
        copy.id = InkStroke.newID()
        copy.t = Int64(Date().timeIntervalSince1970 * 1000)
        copy.x = min(Double(pv.pageSize.width) - copy.w - 6, copy.x + 16)
        copy.y = min(Double(pv.pageSize.height) - 32, copy.y + 16)
        var list = inkDoc.texts[key] ?? []
        list.append(copy)
        inkDoc.texts[key] = list
        pv.setTextBoxes(list)
        pushUndo(.texts(pageKey: key, added: [copy], removed: []))
        scheduleSave()
        openTextBoxEditor(for: copy, original: copy, on: pv, pageFrame: pFrame)
        toolState.showToast("Text box duplicated")
    }

    func deleteActiveTextBox() {
        guard let ed = activeTextEditor else { return }
        let key = ed.pageKey
        let orig = ed.originalBox
        activeTextEditor = nil
        ed.removeFromSuperview()
        syncTextBoxUIState()

        if let orig = orig {
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            var list = inkDoc.texts[key] ?? []
            list.removeAll { $0.id == orig.id }
            inkDoc.deleted[orig.id] = nowMs
            if list.isEmpty { inkDoc.texts.removeValue(forKey: key) }
            else { inkDoc.texts[key] = list }
            pageView(forKey: key)?.setTextBoxes(list, hiddenID: nil)
            pushUndo(.texts(pageKey: key, added: [], removed: [orig]))
            scheduleSave()
            toolState.showToast("Text box deleted")
        } else {
            pageView(forKey: key)?.setHiddenTextBoxID(nil)
        }
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
        let idx = firstPageIndex(withMaxYAtLeast: docPoint.y)
        guard idx < pageFrames.count, pageFrames[idx].contains(docPoint) else { return nil }
        return mountPageView(at: idx)
    }

    private func pageView(forKey key: String) -> PageCanvasView? {
        mountedPageViews[key]
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
                Task { @MainActor in Haptics.light() }
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
        // Pause pending Drive uploads/checks while stylus is actively on screen!
        idleCheckWorkItem?.cancel()
        syncManager?.cancelScheduledSync(for: relativePath)
        if !toolState.isWriting {
            DispatchQueue.main.async { self.toolState.isWriting = true }
        }

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
            if toolState.isWriting {
                DispatchQueue.main.async { self.toolState.isWriting = false }
            }
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
        if toolState.isWriting {
            DispatchQueue.main.async { self.toolState.isWriting = false }
        }
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
        commitActiveTextBox()
        clearLassoSelection(commitFirst: false)
        guard let action = undoStack.popLast() else { return }
        applyUndo(action, isRedo: false)
        redoStack.append(action)
        syncUndoFlags()
        scheduleSave()
    }

    func performRedo() {
        commitActiveTextBox()
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

        case let .texts(pageKey, added, removed):
            let toRemove = isRedo ? removed : added
            let toAdd = isRedo ? added : removed
            var list = inkDoc.texts[pageKey] ?? []
            let remIds = Set(toRemove.map { $0.id })
            if !remIds.isEmpty {
                list.removeAll { remIds.contains($0.id) }
                for id in remIds { inkDoc.deleted[id] = nowMs }
            }
            for tb in toAdd {
                inkDoc.deleted.removeValue(forKey: tb.id)
                list.removeAll { $0.id == tb.id }
                list.append(tb)
            }
            list.sort { $0.t < $1.t }
            if list.isEmpty { inkDoc.texts.removeValue(forKey: pageKey) }
            else { inkDoc.texts[pageKey] = list }
            pageView(forKey: pageKey)?.setTextBoxes(list)

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
        idleCheckWorkItem?.cancel()
        syncManager?.cancelScheduledSync(for: relativePath)
        let item = DispatchWorkItem { [weak self] in
            self?.saveNow(flushDriveImmediately: false)
        }
        saveWorkItem = item
        // Save locally after 0.75s pause; Drive upload batches cleanly after 4.0s of idle!
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: item)
    }

    private func handleReturnedToApp() {
        guard isTabActive,
              AppSettings.shared.syncMode == .smart,
              let sm = syncManager, sm.config.isConnected, sm.config.autoSync else { return }
        // Only check Drive on return if we were away or haven't checked recently (>= 12s)
        let now = Date()
        let awayLongEnough = lastBackgroundedAt.map { now.timeIntervalSince($0) >= 8.0 } ?? false
        let staleCheck = lastDriveSyncCheckAt.map { now.timeIntervalSince($0) >= 15.0 } ?? true
        lastBackgroundedAt = nil
        if awayLongEnough || staleCheck {
            syncNowWithDrive(silent: true, forceFolderScan: true)
            scheduleNextIdleCheck(stage: 0)
        }
    }

    /// Adaptive idle pull backoff (60s -> 3m -> 10m -> sleep) — zero wasteful 3.5s/5s/10s polling!
    private func scheduleNextIdleCheck(stage: Int) {
        idleCheckWorkItem?.cancel()
        idleCheckWorkItem = nil
        guard isTabActive,
              AppSettings.shared.syncMode == .smart,
              let sm = syncManager, sm.config.isConnected, sm.config.autoSync else { return }
        let delays: [TimeInterval] = [60.0, 180.0, 600.0]
        guard stage >= 0 && stage < delays.count else { return }
        let delay = delays[stage]
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                // Never interrupt active drawing or active text-box typing!
                guard self.isTabActive,
                      AppSettings.shared.syncMode == .smart,
                      self.activePageView == nil,
                      self.activeTextEditor == nil,
                      !self.laserDown,
                      !self.isDirty,
                      let sm = self.syncManager, sm.config.isConnected, sm.config.autoSync else {
                    self.scheduleNextIdleCheck(stage: stage)
                    return
                }
                self.syncNowWithDrive(silent: true, forceFolderScan: false) { [weak self] gotRemoteUpdate in
                    guard let self else { return }
                    // If remote changes arrived, reset backoff; otherwise back off cleanly to save battery
                    self.scheduleNextIdleCheck(stage: gotRemoteUpdate ? 0 : stage + 1)
                }
            }
        }
        idleCheckWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func startLiveDriveSync() {
        idleCheckWorkItem?.cancel()
        idleCheckWorkItem = nil
        guard isTabActive,
              AppSettings.shared.syncMode == .smart,
              let sm = syncManager, sm.config.isConnected, sm.config.autoSync else { return }
        // Check once cleanly on open / tab focus, then switch to adaptive idle checks (no constant polling!)
        let recentlyChecked = lastDriveSyncCheckAt.map { Date().timeIntervalSince($0) < 10.0 } ?? false
        if !recentlyChecked {
            syncNowWithDrive(silent: true, forceFolderScan: true)
        }
        scheduleNextIdleCheck(stage: 0)
    }

    func syncNowWithDrive(
        silent: Bool = false,
        forceFolderScan: Bool = false,
        onComplete: ((Bool) -> Void)? = nil
    ) {
        guard let sm = syncManager else {
            onComplete?(false)
            return
        }
        let snap = inkDoc
        let url = pdfURL
        let rel = relativePath
        lastDriveSyncCheckAt = Date()
        Task { @MainActor in
            guard sm.config.isConnected else {
                onComplete?(false)
                return
            }
            if let (merged, changed) = await sm.syncBook(
                pdfURL: url,
                relativePath: rel,
                localDoc: snap,
                forceFolderScan: forceFolderScan || !silent
            ) {
                if changed {
                    self.applyRemoteMergedDocument(merged)
                    if !silent { self.toolState.showToast("Synced remote updates") }
                } else if !silent {
                    self.toolState.showToast("Up to date with Google Drive")
                }
                onComplete?(changed)
            } else {
                onComplete?(false)
            }
        }
    }

    private func flushPendingRemoteDoc() {
        guard activePageView == nil, !laserDown, let pending = pendingRemoteDoc else { return }
        pendingRemoteDoc = nil
        applyRemoteMergedDocument(pending)
    }

    private func applyRemoteMergedDocument(_ remoteMerged: InkDocument) {
        if activePageView != nil || laserDown {
            pendingRemoteDoc = remoteMerged
            return
        }
        // Safely preserve any brand-new local strokes drawn mid-flight while sync was running!
        var combined = remoteMerged
        for (pageKey, localList) in inkDoc.pages {
            var cur = combined.pages[pageKey] ?? []
            let haveIDs = Set(cur.map { $0.id })
            var addedAny = false
            for s in localList where !haveIDs.contains(s.id) && combined.deleted[s.id] == nil {
                cur.append(s)
                addedAny = true
            }
            if addedAny {
                cur.sort { $0.t != $1.t ? $0.t < $1.t : $0.id < $1.id }
                combined.pages[pageKey] = cur
            }
        }

        // Preserve any brand-new local text boxes created mid-flight
        for (pageKey, localBoxes) in inkDoc.texts {
            var cur = combined.texts[pageKey] ?? []
            var changed = false
            for tb in localBoxes where combined.deleted[tb.id] == nil {
                if let idx = cur.firstIndex(where: { $0.id == tb.id }) {
                    if tb.t > cur[idx].t { cur[idx] = tb; changed = true }
                } else {
                    cur.append(tb); changed = true
                }
            }
            if changed {
                cur.sort { $0.t != $1.t ? $0.t < $1.t : $0.id < $1.id }
                combined.texts[pageKey] = cur
            }
        }

        let structureChanged = (inkDoc.blanks != combined.blanks || inkDoc.removed != combined.removed)
        let oldPages = inkDoc.pages
        let oldTexts = inkDoc.texts
        inkDoc = combined

        if structureChanged {
            commitActiveTextBox()
            clearLassoSelection(commitFirst: false)
            rebuildPageViews(focusKey: nil)
        } else {
            let hidden = lassoSelection?.hiddenStrokeIDs ?? []
            let activeTextID = activeTextEditor?.originalBox?.id
            for pv in mountedPageViews.values {
                let newStrokes = inkDoc.pages[pv.pageKey] ?? []
                let oldStrokes = oldPages[pv.pageKey] ?? []
                if newStrokes.count != oldStrokes.count || Set(newStrokes.map { $0.id }) != Set(oldStrokes.map { $0.id }) {
                    pv.setStrokes(newStrokes, hiddenIDs: (lassoSelection?.pageKey == pv.pageKey) ? hidden : [])
                }
                let newTexts = inkDoc.texts[pv.pageKey] ?? []
                let oldT = oldTexts[pv.pageKey] ?? []
                if newTexts != oldT {
                    pv.setTextBoxes(newTexts, hiddenID: (activeTextEditor?.pageKey == pv.pageKey) ? activeTextID : nil)
                }
            }
            syncDocumentMetadataToUI()
        }
    }

    func saveNow(flushDriveImmediately: Bool = false) {
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
                    guard let sm = self.syncManager,
                          sm.config.isConnected,
                          sm.config.autoSync,
                          AppSettings.shared.syncMode == .smart else { return }
                    if flushDriveImmediately {
                        sm.cancelScheduledSync(for: rel)
                        self.syncNowWithDrive(silent: true, forceFolderScan: false)
                    } else if self.activePageView == nil && self.activeTextEditor == nil {
                        // Batch edits and push cleanly 4 seconds after you stop writing/typing!
                        sm.scheduleBookSync(
                            pdfURL: targetURL,
                            relativePath: rel,
                            delaySeconds: 4.0,
                            localDocProvider: { [weak self] in self?.inkDoc ?? snapshot },
                            onMerged: { [weak self] merged in self?.applyRemoteMergedDocument(merged) }
                        )
                        self.scheduleNextIdleCheck(stage: 0)
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


#if !targetEnvironment(macCatalyst)
extension PDFNotebookViewController: UIPencilInteractionDelegate {
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        guard isTabActive else { return }
        let action = AppSettings.shared.pencilDoubleTap
        switch action {
        case .off:
            return
        case .switchEraser:
            let next: DrawingTool = (toolState.tool == .eraser) ? .pen : .eraser
            toolState.previousTool = toolState.tool
            toolState.tool = next
            onToolChanged(to: next)
            Haptics.light()
            toolState.showToast(next == .eraser ? "Eraser" : "Pen")
        case .switchLastTool:
            let cur = toolState.tool
            let prev = (toolState.previousTool == cur) ? .eraser : toolState.previousTool
            toolState.previousTool = cur
            toolState.tool = prev
            onToolChanged(to: prev)
            Haptics.light()
            toolState.showToast(prev.rawValue.capitalized)
        }
    }
}
#endif

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
    let isActive: Bool
    let controllerBox: ControllerBox

    final class ControllerBox {
        weak var vc: PDFNotebookViewController?
    }

    func makeUIViewController(context: Context) -> PDFNotebookViewController {
        let vc = PDFNotebookViewController(
            pdfURL: pdfURL,
            relativePath: relativePath,
            toolState: toolState,
            syncManager: syncManager,
            isActive: isActive
        )
        controllerBox.vc = vc
        return vc
    }

    func updateUIViewController(_ uiViewController: PDFNotebookViewController, context: Context) {
        controllerBox.vc = uiViewController
        uiViewController.setTabActive(isActive)
    }
}
