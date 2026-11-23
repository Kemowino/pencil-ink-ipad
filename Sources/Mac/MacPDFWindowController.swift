import AppKit
import PDFKit
import Combine
import UniformTypeIdentifiers

private extension NSToolbarItem.Identifier {
    static let sidebarToggle = NSToolbarItem.Identifier("pencilink.sidebarToggle")
    static let toolMode = NSToolbarItem.Identifier("pencilink.toolMode")
    static let bookmark = NSToolbarItem.Identifier("pencilink.bookmark")
    static let paperMode = NSToolbarItem.Identifier("pencilink.paperMode")
    static let zoomControls = NSToolbarItem.Identifier("pencilink.zoomControls")
    static let pageIndicator = NSToolbarItem.Identifier("pencilink.pageIndicator")
    static let syncStatus = NSToolbarItem.Identifier("pencilink.syncStatus")
}

private enum MacUndoAction {
    case strokes(entries: [(pageKey: String, added: [InkStroke], removed: [InkStroke])])
    case texts(pageKey: String, added: [InkTextBox], removed: [InkTextBox])
}

/// Pure AppKit tabbed PDF Reader & Annotation window running directly on Apple Preview's `PDFView`
/// + `PDFPageOverlayViewProvider` with zero Catalyst/SwiftUI overhead, inline `NSTextView` text boxes,
/// drag & selection highlighting, Undo/Redo, Export Annotated PDF, and full Google Drive CRDT sync.
@MainActor
final class MacPDFWindowController: NSWindowController,
    NSWindowDelegate, NSToolbarDelegate,
    PDFPageOverlayViewProvider, MacPDFCanvasDelegate, MacSidebarDelegate {

    let pdfURL: URL
    let relativePath: String
    let syncManager: DriveSyncManager
    var onRequestNewTab: ((MacPDFWindowController) -> Void)?
    var onRequestOpenSyncSettings: (() -> Void)?
    var onWindowClosed: ((MacPDFWindowController) -> Void)?

    private let splitVC = NSSplitViewController()
    private let sidebarVC = MacSidebarViewController()
    private let optionsBar = MacToolOptionsBar()
    private var optionsBarHeightConstraint: NSLayoutConstraint?
    private let pdfView = MacPDFCanvasView()

    private var inkDoc: InkDocument
    private var virtualResult: MacVirtualPDFResult?
    private var overlayByPageID: [ObjectIdentifier: MacPageOverlayView] = [:]
    private var overlayByKey: [String: MacPageOverlayView] = [:]

    // Static cached SF Symbol images (ZERO per-page/per-tick NSImage lookups!)
    private static let iconBookmark = NSImage(systemSymbolName: "bookmark", accessibilityDescription: "Bookmark")
    private static let iconBookmarkFilled = NSImage(systemSymbolName: "bookmark.fill", accessibilityDescription: "Bookmarked")
    private static let iconSyncOK = NSImage(systemSymbolName: "checkmark.icloud", accessibilityDescription: "Synced")
    private static let iconSyncing = NSImage(systemSymbolName: "arrow.triangle.2.circlepath.icloud", accessibilityDescription: "Syncing")
    private static let iconSyncError = NSImage(systemSymbolName: "exclamationmark.icloud", accessibilityDescription: "Sync Error")
    private static let iconSyncOff = NSImage(systemSymbolName: "icloud.slash", accessibilityDescription: "Disconnected")

    // Toolbar controls
    private let modeSegment = NSSegmentedControl(labels: ["Read", "Highlight", "Text Box"], trackingMode: .selectOne, target: nil, action: nil)
    private let bookmarkButton = NSButton()
    private let paperPopup = NSPopUpButton()
    private let pageField = NSTextField()
    private let syncButton = NSButton(title: "Sync", target: nil, action: nil)

    // State, Undo/Redo & Coalesced Leeway Timers
    private var undoStack: [MacUndoAction] = []
    private var redoStack: [MacUndoAction] = []
    private var isInitialInkLoaded = false
    private var pendingSaveAfterLoad = false
    private var pendingSavedPageRestore: Int? = nil
    private var isDirty = false
    private var saveWorkItem: DispatchWorkItem?
    private var pagePersistTimer: DispatchSourceTimer?
    private var idleCheckTimer: DispatchSourceTimer?
    private var lastDriveCheckAt: Date?
    private var lastResignedAt: Date?
    private var lastDisplayedPage: Int = -1
    private var lastDisplayedTotal: Int = -1
    private var lastDisplayedBookmarked: Bool? = nil
    private var lastSyncVisualState: SyncVisualState? = nil
    private var cancellables = Set<AnyCancellable>()

    // Active drag highlight state
    private var activeHighlightSlot: PageSlot?
    private var activeHighlightOverlay: MacPageOverlayView?
    private var activeHighlightStart: CGPoint?
    private var activeHighlightPoints: [InkPoint] = []

    // Active inline text box editor
    private var activeTextEditor: MacInlineTextBoxView?

    private var lastPageStorageKey: String {
        "pencilink.lastpage." + pdfURL.lastPathComponent
    }

    var canUndoDocument: Bool { !undoStack.isEmpty }
    var canRedoDocument: Bool { !redoStack.isEmpty }
    var hasTextSelection: Bool {
        guard let s = pdfView.currentSelection?.string else { return false }
        return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(pdfURL: URL, relativePath: String, syncManager: DriveSyncManager) {
        self.pdfURL = pdfURL
        self.relativePath = relativePath
        self.syncManager = syncManager
        self.inkDoc = InkDocument.empty(name: relativePath)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = pdfURL.deletingPathExtension().lastPathComponent
        win.minSize = NSSize(width: 640, height: 480)
        win.tabbingMode = .preferred
        win.tabbingIdentifier = "PencilInkDocumentTab"
        win.titlebarAppearsTransparent = false
        super.init(window: win)
        win.delegate = self

        setupToolbar()
        setupSplitView()
        setupObservers()
        loadDocumentAndInk()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        saveWorkItem?.cancel()
        pagePersistTimer?.cancel()
        idleCheckTimer?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Native AppKit Toolbar & Split View

    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: NSToolbar.Identifier("PencilInkMacToolbar"))
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
        window?.toolbarStyle = .unifiedCompact
    }

    private func setupSplitView() {
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 210
        sidebarItem.maximumThickness = 360
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = true // Collapsed by default for zero sidebar CPU!
        sidebarVC.delegate = self

        let contentVC = NSViewController()
        let hostView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 700))

        optionsBar.translatesAutoresizingMaskIntoConstraints = false
        optionsBar.isHidden = true
        optionsBar.onStyleChanged = { [weak self] in
            self?.updateActiveTextBoxStyle()
        }
        optionsBar.onDuplicateTextBox = { [weak self] in
            self?.duplicateActiveTextBox()
        }
        optionsBar.onDeleteTextBox = { [weak self] in
            self?.deleteActiveTextBox()
        }
        optionsBar.onCommitTextBox = { [weak self] in
            self?.commitActiveTextBox()
        }
        hostView.addSubview(optionsBar)

        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.canvasDelegate = self
        pdfView.pageOverlayViewProvider = self
        hostView.addSubview(pdfView)

        let barH = optionsBar.heightAnchor.constraint(equalToConstant: 0)
        optionsBarHeightConstraint = barH

        NSLayoutConstraint.activate([
            optionsBar.topAnchor.constraint(equalTo: hostView.topAnchor),
            optionsBar.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            optionsBar.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            barH,

            pdfView.topAnchor.constraint(equalTo: optionsBar.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: hostView.bottomAnchor)
        ])

        contentVC.view = hostView

        let mainItem = NSSplitViewItem(viewController: contentVC)
        splitVC.addSplitViewItem(sidebarItem)
        splitVC.addSplitViewItem(mainItem)
        window?.contentViewController = splitVC
    }

    private func updateOptionsBarVisibility() {
        let hasActiveBox = (activeTextEditor != nil)
        let shouldShow = (pdfView.toolMode != .read) || hasActiveBox
        optionsBar.isHidden = !shouldShow
        optionsBarHeightConstraint?.constant = shouldShow ? 36 : 0
        if shouldShow {
            optionsBar.update(for: pdfView.toolMode, hasActiveTextBox: hasActiveBox)
        }
    }

    private func setupObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePageChanged),
            name: .PDFViewPageChanged,
            object: pdfView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePaperModePrefChanged),
            name: .macPaperModeDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleToolPrefsChanged),
            name: .macToolPrefsDidChange,
            object: nil
        )
        syncManager.$statusText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                guard let self else { return }
                self.syncButton.toolTip = "Google Drive: \(text)"
                let st = self.syncManager.visualState
                if self.lastSyncVisualState != st {
                    self.lastSyncVisualState = st
                    switch st {
                    case .ok: self.syncButton.image = Self.iconSyncOK
                    case .syncing: self.syncButton.image = Self.iconSyncing
                    case .error: self.syncButton.image = Self.iconSyncError
                    case .disconnected: self.syncButton.image = Self.iconSyncOff
                    }
                }
            }
            .store(in: &cancellables)
    }

    @objc private func handleToolPrefsChanged() {
        optionsBar.syncFromPreferences()
    }

    // MARK: - Document Loading (Instant PDF Open + Async `.ink.json` Merge)

    private func loadDocumentAndInk() {
        var emptyDoc = inkDoc
        if let built = MacVirtualPDFBuilder.build(from: pdfURL, inkDoc: &emptyDoc) {
            self.inkDoc = emptyDoc
            applyVirtualResult(built, preservePageIndex: nil)
            restoreSavedPageIfPossible()
        }

        let url = pdfURL
        let rel = relativePath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var loaded = InkDocument.load(for: url)
            if loaded.name.isEmpty { loaded.name = rel }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isInitialInkLoaded = true
                let hasContent = !loaded.pages.isEmpty
                    || !loaded.blanks.isEmpty
                    || !loaded.bookmarks.isEmpty
                    || !loaded.removed.isEmpty
                    || !loaded.texts.isEmpty
                    || !loaded.deleted.isEmpty
                if hasContent {
                    self.applyLoadedOrRemoteInkDoc(loaded)
                }
                if let pendingPage = self.pendingSavedPageRestore,
                   let doc = self.pdfView.document,
                   pendingPage > 1 && pendingPage <= doc.pageCount,
                   let page = doc.page(at: pendingPage - 1) {
                    self.pendingSavedPageRestore = nil
                    self.pdfView.go(to: page)
                    self.updatePageIndicatorAndBookmarkUI()
                }
                if self.pendingSaveAfterLoad {
                    self.pendingSaveAfterLoad = false
                    self.saveNow(flushDriveImmediately: false)
                }
                self.startSmartDriveSync()
            }
        }
    }

    private func applyVirtualResult(_ res: MacVirtualPDFResult, preservePageIndex: Int?) {
        commitActiveTextBox()
        overlayByPageID.removeAll()
        overlayByKey.removeAll()
        virtualResult = res
        pdfView.document = res.document
        pdfView.autoScales = true
        pdfView.applyPaperMode(MacPreferences.shared.paperMode)

        if let idx = preservePageIndex, idx >= 0, idx < res.document.pageCount, let p = res.document.page(at: idx) {
            pdfView.go(to: p)
        }
        sidebarVC.configure(document: res.document, bookmarks: currentBookmarkItems())
        lastDisplayedPage = -1
        updatePageIndicatorAndBookmarkUI()
    }

    private func restoreSavedPageIfPossible() {
        guard let doc = pdfView.document else { return }
        let saved = UserDefaults.standard.integer(forKey: lastPageStorageKey)
        guard saved > 1 else { return }
        if saved <= doc.pageCount, let page = doc.page(at: saved - 1) {
            pdfView.go(to: page)
            updatePageIndicatorAndBookmarkUI()
            pendingSavedPageRestore = nil
        } else if !isInitialInkLoaded {
            // Hobonichi journals or PDFs with inserted blank pages: defer jump until async inkDoc finishes loading!
            pendingSavedPageRestore = saved
        }
    }

    private func applyLoadedOrRemoteInkDoc(_ remoteMerged: InkDocument) {
        // Preserve any brand-new local highlights or text boxes created while Drive sync was in flight!
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
        let curIdx = currentPageIndex()
        inkDoc = combined

        if structureChanged {
            var docCopy = inkDoc
            if let rebuilt = MacVirtualPDFBuilder.build(from: pdfURL, inkDoc: &docCopy) {
                inkDoc = docCopy
                applyVirtualResult(rebuilt, preservePageIndex: min(curIdx, max(0, rebuilt.slots.count - 1)))
            }
        } else {
            refreshAllMountedOverlays()
            sidebarVC.updateBookmarks(currentBookmarkItems())
            updatePageIndicatorAndBookmarkUI()
        }
    }

    private func refreshAllMountedOverlays() {
        let activeHiddenID = activeTextEditor?.originalBox?.id
        let activeKey = activeTextEditor?.pageKey
        for overlay in overlayByPageID.values {
            let k = overlay.slot.key
            overlay.setContent(
                strokes: inkDoc.pages[k] ?? [],
                textBoxes: inkDoc.texts[k] ?? [],
                hiddenTextBoxID: (k == activeKey) ? activeHiddenID : nil
            )
        }
    }

    private func overlayForPageKey(_ pageKey: String) -> MacPageOverlayView? {
        overlayByKey[pageKey]
    }

    private func currentPageIndex() -> Int {
        guard let doc = pdfView.document, let cur = pdfView.currentPage else { return 0 }
        let idx = doc.index(for: cur)
        return idx == NSNotFound ? 0 : idx
    }

    private func currentSlot() -> PageSlot? {
        guard let cur = pdfView.currentPage else { return nil }
        return virtualResult?.slotByPageID[ObjectIdentifier(cur)]
    }

    private func currentBookmarkItems() -> [MacBookmarkItem] {
        guard let res = virtualResult else { return [] }
        var out: [MacBookmarkItem] = []
        for (idx, slot) in res.slots.enumerated() where inkDoc.isBookmarked(slot.key) {
            let custom = inkDoc.bookmarks[slot.key]?.title ?? ""
            let label = custom.isEmpty ? "Page \(idx + 1)" : custom
            out.append(MacBookmarkItem(key: slot.key, pageIndex: idx, label: label))
        }
        return out
    }

    // MARK: - PDFPageOverlayViewProvider (Zero-Cost Overlay Management, macOS 13.0+ Safe)

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        let pid = ObjectIdentifier(page)
        if let existing = overlayByPageID[pid] {
            return existing
        }
        guard let slot = virtualResult?.slotByPageID[pid] else { return nil }
        let overlay = MacPageOverlayView(slot: slot)
        overlay.setContent(
            strokes: inkDoc.pages[slot.key] ?? [],
            textBoxes: inkDoc.texts[slot.key] ?? []
        )
        overlayByPageID[pid] = overlay
        overlayByKey[slot.key] = overlay
        return overlay
    }

    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: NSView, for page: PDFPage) {
        if let ov = overlayView as? MacPageOverlayView {
            // Re-register in case PDFKit reused a cached overlay without re-calling overlayViewFor!
            overlayByPageID[ObjectIdentifier(page)] = ov
            overlayByKey[ov.slot.key] = ov
            let k = ov.slot.key
            let hid = (activeTextEditor?.pageKey == k) ? activeTextEditor?.originalBox?.id : nil
            ov.setContent(strokes: inkDoc.pages[k] ?? [], textBoxes: inkDoc.texts[k] ?? [], hiddenTextBoxID: hid)
        }
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: NSView, for page: PDFPage) {
        let pid = ObjectIdentifier(page)
        if let ov = overlayView as? MacPageOverlayView {
            if activeTextEditor?.hostOverlay === ov {
                commitActiveTextBox()
            }
            if overlayByKey[ov.slot.key] === ov {
                overlayByKey.removeValue(forKey: ov.slot.key)
            }
        }
        overlayByPageID.removeValue(forKey: pid)
    }

    // MARK: - MacPDFCanvasDelegate (Selection Highlight, Drag Highlight, Erase Highlight, & Inline Text Box)

    func canvasView(_ view: MacPDFCanvasView, overlayFor page: PDFPage) -> MacPageOverlayView? {
        overlayByPageID[ObjectIdentifier(page)]
    }

    func canvasViewDidClickOutsideTextBox(_ view: MacPDFCanvasView) {
        if activeTextEditor != nil {
            commitActiveTextBox()
        }
    }

    func canvasView(_ view: MacPDFCanvasView, didHighlightSelection selection: PDFSelection) {
        let lines = selection.selectionsByLine()
        guard !lines.isEmpty else { return }
        let colorHex = MacPreferences.shared.activeHlColorHex
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        var addedByKey: [String: [InkStroke]] = [:]

        for lineSel in lines {
            guard let page = lineSel.pages.first,
                  let slot = virtualResult?.slotByPageID[ObjectIdentifier(page)] else { continue }
            let pdfRect = lineSel.bounds(for: page)
            guard pdfRect.width > 1, pdfRect.height > 1 else { continue }

            let topLeftRect: CGRect
            if let overlay = overlayByPageID[ObjectIdentifier(page)] {
                let inPDFView = pdfView.convert(pdfRect, from: page)
                let inOverlay = overlay.convert(inPDFView, from: pdfView)
                topLeftRect = overlay.viewRectToPageRect(inOverlay)
            } else {
                let crop = page.bounds(for: .cropBox)
                topLeftRect = CGRect(
                    x: pdfRect.minX - crop.minX,
                    y: crop.maxY - pdfRect.maxY,
                    width: pdfRect.width,
                    height: pdfRect.height
                )
            }

            let yMid = (Double(topLeftRect.midY) * 100).rounded() / 100
            let x0 = (Double(topLeftRect.minX) * 100).rounded() / 100
            let x1 = (Double(topLeftRect.maxX) * 100).rounded() / 100
            let strokeSize = max(8.0, min(40.0, (Double(topLeftRect.height) * 1.05 * 10).rounded() / 10))

            let stroke = InkStroke(
                id: InkStroke.newID(),
                t: nowMs,
                tool: "highlighter",
                style: "ball",
                color: colorHex,
                size: strokeSize,
                pts: [x0, yMid, 0.5, x1, yMid, 0.5],
                straight: true,
                _bakedSmooth: false,
                _smoothLevel: 0,
                _sens: 1.0,
                _smartShape: nil
            )
            var list = inkDoc.pages[slot.key] ?? []
            list.append(stroke)
            inkDoc.pages[slot.key] = list
            overlayByPageID[ObjectIdentifier(page)]?.appendStroke(stroke)
            addedByKey[slot.key, default: []].append(stroke)
        }

        if !addedByKey.isEmpty {
            let entries = addedByKey.map { (pageKey: $0.key, added: $0.value, removed: [InkStroke]()) }
            pushUndo(.strokes(entries: entries))
            scheduleSave()
        }
    }

    func canvasView(_ view: MacPDFCanvasView, didBeginHighlightAt pagePoint: CGPoint, on page: PDFPage) {
        guard let slot = virtualResult?.slotByPageID[ObjectIdentifier(page)],
              let overlay = overlayByPageID[ObjectIdentifier(page)] else { return }
        cancelIdleCheckTimer()
        syncManager.cancelScheduledSync(for: relativePath)
        activeHighlightSlot = slot
        activeHighlightOverlay = overlay
        activeHighlightStart = pagePoint
        let pt = InkPoint(x: pagePoint.x, y: pagePoint.y, p: 0.5, t: CACurrentMediaTime())
        activeHighlightPoints = [pt]
        overlay.updateLiveHighlight(
            points: activeHighlightPoints,
            colorHex: MacPreferences.shared.activeHlColorHex,
            size: CGFloat(MacPreferences.shared.activeHlSize),
            straight: MacPreferences.shared.hlStraight
        )
    }

    func canvasView(_ view: MacPDFCanvasView, didDragHighlightTo pagePoint: CGPoint, on page: PDFPage, shiftHeld: Bool) {
        guard let overlay = activeHighlightOverlay else { return }
        let straight = MacPreferences.shared.hlStraight || shiftHeld
        let now = CACurrentMediaTime()
        if straight, let start = activeHighlightStart {
            var ex = pagePoint.x
            var ey = pagePoint.y
            let ang = atan2(abs(ey - start.y), abs(ex - start.x)) * 180.0 / CGFloat.pi
            if ang < 8.0 { ey = start.y }
            else if ang > 82.0 { ex = start.x }
            if activeHighlightPoints.count == 2,
               hypot(ex - activeHighlightPoints[1].x, ey - activeHighlightPoints[1].y) < 0.75 {
                return
            }
            activeHighlightPoints = [
                InkPoint(x: start.x, y: start.y, p: 0.5, t: now - 0.01),
                InkPoint(x: ex, y: ey, p: 0.5, t: now)
            ]
        } else {
            if let last = activeHighlightPoints.last, hypot(pagePoint.x - last.x, pagePoint.y - last.y) < 1.0 { return }
            activeHighlightPoints.append(InkPoint(x: pagePoint.x, y: pagePoint.y, p: 0.5, t: now))
        }
        overlay.updateLiveHighlight(
            points: activeHighlightPoints,
            colorHex: MacPreferences.shared.activeHlColorHex,
            size: CGFloat(MacPreferences.shared.activeHlSize),
            straight: straight
        )
    }

    func canvasView(_ view: MacPDFCanvasView, didEndHighlightOn page: PDFPage) {
        defer {
            activeHighlightOverlay?.clearLiveHighlight()
            activeHighlightOverlay = nil
            activeHighlightSlot = nil
            activeHighlightStart = nil
            activeHighlightPoints.removeAll(keepingCapacity: true)
        }
        guard let slot = activeHighlightSlot, !activeHighlightPoints.isEmpty else { return }
        var flat: [Double] = []
        flat.reserveCapacity(activeHighlightPoints.count * 3)
        for p in activeHighlightPoints {
            flat.append((Double(p.x) * 100).rounded() / 100)
            flat.append((Double(p.y) * 100).rounded() / 100)
            flat.append(0.5)
        }
        let stroke = InkStroke(
            id: InkStroke.newID(),
            t: Int64(Date().timeIntervalSince1970 * 1000),
            tool: "highlighter",
            style: "ball",
            color: MacPreferences.shared.activeHlColorHex,
            size: MacPreferences.shared.activeHlSize,
            pts: flat,
            straight: MacPreferences.shared.hlStraight || activeHighlightPoints.count == 2,
            _bakedSmooth: false,
            _smoothLevel: 0,
            _sens: 1.0,
            _smartShape: nil
        )
        var list = inkDoc.pages[slot.key] ?? []
        list.append(stroke)
        inkDoc.pages[slot.key] = list
        activeHighlightOverlay?.appendStroke(stroke)
        pushUndo(.strokes(entries: [(pageKey: slot.key, added: [stroke], removed: [])]))
        scheduleSave()
    }

    func canvasView(_ view: MacPDFCanvasView, didEraseHighlightAt pagePoint: CGPoint, on page: PDFPage) {
        guard let slot = virtualResult?.slotByPageID[ObjectIdentifier(page)],
              let list = inkDoc.pages[slot.key], !list.isEmpty else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        var dirty = CGRect.null
        var removed: [InkStroke] = []
        var kept: [InkStroke] = []
        for s in list {
            if s.tool == "highlighter" && StrokeGeometry.strokeHits(s, point: pagePoint, radius: 10.0) {
                let pad = CGFloat(s.size) * 2.0 + 8.0
                dirty = dirty.union(s.boundingBox().insetBy(dx: -pad, dy: -pad))
                inkDoc.deleted[s.id] = nowMs
                removed.append(s)
            } else {
                kept.append(s)
            }
        }
        if !removed.isEmpty {
            if kept.isEmpty { inkDoc.pages.removeValue(forKey: slot.key) }
            else { inkDoc.pages[slot.key] = kept }
            overlayByPageID[ObjectIdentifier(page)]?.setContent(
                strokes: kept,
                textBoxes: inkDoc.texts[slot.key] ?? [],
                dirtyPageRect: dirty
            )
            pushUndo(.strokes(entries: [(pageKey: slot.key, added: [], removed: removed)]))
            scheduleSave()
        }
    }

    func canvasView(_ view: MacPDFCanvasView, didDoubleClickInReadModeAt pagePoint: CGPoint, on page: PDFPage) -> Bool {
        guard let slot = virtualResult?.slotByPageID[ObjectIdentifier(page)],
              let overlay = overlayByPageID[ObjectIdentifier(page)] else { return false }
        let existing = inkDoc.texts[slot.key] ?? []
        for tb in existing.reversed() {
            if tb.measuredRect().insetBy(dx: -6, dy: -6).contains(pagePoint) {
                openTextBoxEditor(for: tb, original: tb, on: overlay)
                return true
            }
        }
        return false
    }

    func canvasView(_ view: MacPDFCanvasView, didClickTextBoxAt pagePoint: CGPoint, on page: PDFPage) {
        guard let slot = virtualResult?.slotByPageID[ObjectIdentifier(page)],
              let overlay = overlayByPageID[ObjectIdentifier(page)] else { return }

        // Check if clicking an existing text box first (topmost wins)
        let existing = inkDoc.texts[slot.key] ?? []
        for tb in existing.reversed() {
            if tb.measuredRect().insetBy(dx: -6, dy: -6).contains(pagePoint) {
                openTextBoxEditor(for: tb, original: tb, on: overlay)
                return
            }
        }

        // Create a brand new text box right where the user clicked!
        let prefs = MacPreferences.shared
        let boxW = min(240.0, max(120.0, Double(slot.size.width) - 24.0))
        let clampedX = max(10.0, min(Double(slot.size.width) - boxW - 10.0, Double(pagePoint.x) - 10.0))
        let clampedY = max(10.0, min(Double(slot.size.height) - 36.0, Double(pagePoint.y) - 10.0))
        let fresh = InkTextBox(
            x: (clampedX * 100).rounded() / 100,
            y: (clampedY * 100).rounded() / 100,
            w: (boxW * 100).rounded() / 100,
            text: "",
            fontSize: prefs.textSize,
            color: prefs.activeTextColorHex,
            fontName: prefs.textFont,
            bold: prefs.textBold,
            bgColor: prefs.textBgHex.isEmpty ? nil : prefs.textBgHex
        )
        openTextBoxEditor(for: fresh, original: nil, on: overlay)
    }

    // MARK: - Pure AppKit Inline Text Box Lifecycle

    private func openTextBoxEditor(for box: InkTextBox, original: InkTextBox?, on overlay: MacPageOverlayView) {
        commitActiveTextBox()

        let prefs = MacPreferences.shared
        if let idx = prefs.textColors.firstIndex(where: { $0.caseInsensitiveCompare(box.color) == .orderedSame }) {
            prefs.textColorIndex = idx
        }
        prefs.textSize = box.fontSize
        prefs.textFont = box.fontName ?? "sans"
        prefs.textBold = (box.bold == true)
        prefs.textBgHex = box.bgColor ?? ""

        let editor = MacInlineTextBoxView(pageKey: overlay.slot.key, hostOverlay: overlay, box: box, originalBox: original)
        editor.onChanged = { [weak self] _ in
            guard let self else { return }
            self.cancelIdleCheckTimer()
            self.syncManager.cancelScheduledSync(for: self.relativePath)
        }
        editor.onCommitRequested = { [weak self] in
            self?.commitActiveTextBox()
        }

        cancelIdleCheckTimer()
        syncManager.cancelScheduledSync(for: relativePath)
        overlay.addSubview(editor)
        overlay.activeTextEditor = editor
        overlay.setHiddenTextBoxID(original?.id)
        activeTextEditor = editor
        updateOptionsBarVisibility()
        editor.focusEditor()
    }

    func updateActiveTextBoxStyle() {
        guard let ed = activeTextEditor else { return }
        let prefs = MacPreferences.shared
        ed.box.color = prefs.activeTextColorHex
        ed.box.fontSize = prefs.textSize
        ed.box.fontName = prefs.textFont
        ed.box.bold = prefs.textBold
        ed.box.bgColor = prefs.textBgHex.isEmpty ? nil : prefs.textBgHex
        ed.box.t = Int64(Date().timeIntervalSince1970 * 1000)
        ed.applyStylingAndLayout()
    }

    func commitActiveTextBox() {
        guard let ed = activeTextEditor else { return }
        activeTextEditor = nil
        let overlay = ed.hostOverlay
        overlay?.activeTextEditor = nil
        ed.removeFromSuperview()
        updateOptionsBarVisibility()

        let key = ed.pageKey
        let original = ed.originalBox
        var finalBox = ed.box
        let cleaned = finalBox.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var list = inkDoc.texts[key] ?? []
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        if cleaned.isEmpty {
            if let orig = original {
                list.removeAll { $0.id == orig.id }
                inkDoc.deleted[orig.id] = nowMs
                if list.isEmpty { inkDoc.texts.removeValue(forKey: key) }
                else { inkDoc.texts[key] = list }
                overlayForPageKey(key)?.setContent(strokes: inkDoc.pages[key] ?? [], textBoxes: list, hiddenTextBoxID: nil)
                pushUndo(.texts(pageKey: key, added: [], removed: [orig]))
                scheduleSave()
            } else {
                overlay?.setHiddenTextBoxID(nil)
            }
            window?.makeFirstResponder(pdfView)
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
                overlayForPageKey(key)?.setContent(strokes: inkDoc.pages[key] ?? [], textBoxes: list, hiddenTextBoxID: nil)
                pushUndo(.texts(pageKey: key, added: [finalBox], removed: [orig]))
                scheduleSave()
            } else {
                overlay?.setHiddenTextBoxID(nil)
            }
        } else {
            list.append(finalBox)
            inkDoc.texts[key] = list
            overlayForPageKey(key)?.setContent(strokes: inkDoc.pages[key] ?? [], textBoxes: list, hiddenTextBoxID: nil)
            pushUndo(.texts(pageKey: key, added: [finalBox], removed: []))
            scheduleSave()
        }
        window?.makeFirstResponder(pdfView)
    }

    func duplicateActiveTextBox() {
        guard let ed = activeTextEditor, let overlay = ed.hostOverlay else { return }
        var copy = ed.box
        let key = ed.pageKey
        commitActiveTextBox()
        guard !copy.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        copy.id = InkStroke.newID()
        copy.t = Int64(Date().timeIntervalSince1970 * 1000)
        copy.x = min(Double(overlay.slot.size.width) - copy.w - 6, copy.x + 16)
        copy.y = min(Double(overlay.slot.size.height) - 32, copy.y + 16)
        var list = inkDoc.texts[key] ?? []
        list.append(copy)
        inkDoc.texts[key] = list
        overlay.setContent(strokes: inkDoc.pages[key] ?? [], textBoxes: list)
        pushUndo(.texts(pageKey: key, added: [copy], removed: []))
        scheduleSave()
        openTextBoxEditor(for: copy, original: copy, on: overlay)
    }

    func deleteActiveTextBox() {
        guard let ed = activeTextEditor else { return }
        let key = ed.pageKey
        let orig = ed.originalBox
        let overlay = ed.hostOverlay
        activeTextEditor = nil
        overlay?.activeTextEditor = nil
        ed.removeFromSuperview()
        updateOptionsBarVisibility()

        if let orig = orig {
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            var list = inkDoc.texts[key] ?? []
            list.removeAll { $0.id == orig.id }
            inkDoc.deleted[orig.id] = nowMs
            if list.isEmpty { inkDoc.texts.removeValue(forKey: key) }
            else { inkDoc.texts[key] = list }
            overlayForPageKey(key)?.setContent(strokes: inkDoc.pages[key] ?? [], textBoxes: list, hiddenTextBoxID: nil)
            pushUndo(.texts(pageKey: key, added: [], removed: [orig]))
            scheduleSave()
        } else {
            overlay?.setHiddenTextBoxID(nil)
        }
        window?.makeFirstResponder(pdfView)
    }

    // MARK: - Unified Document Undo / Redo

    private func pushUndo(_ action: MacUndoAction) {
        undoStack.append(action)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func performDocumentUndo() {
        commitActiveTextBox()
        guard let action = undoStack.popLast() else { return }
        applyUndo(action, isRedo: false)
        redoStack.append(action)
        scheduleSave()
    }

    func performDocumentRedo() {
        commitActiveTextBox()
        guard let action = redoStack.popLast() else { return }
        applyUndo(action, isRedo: true)
        undoStack.append(action)
        scheduleSave()
    }

    private func applyUndo(_ action: MacUndoAction, isRedo: Bool) {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        switch action {
        case let .strokes(entries):
            for entry in entries {
                let toRemove = isRedo ? entry.removed : entry.added
                let toAdd = isRedo ? entry.added : entry.removed
                var list = inkDoc.pages[entry.pageKey] ?? []
                let remIDs = Set(toRemove.map { $0.id })
                if !remIDs.isEmpty {
                    list.removeAll { remIDs.contains($0.id) }
                    for id in remIDs { inkDoc.deleted[id] = nowMs }
                }
                for s in toAdd {
                    inkDoc.deleted.removeValue(forKey: s.id)
                    list.append(s)
                }
                list.sort { $0.t < $1.t }
                if list.isEmpty { inkDoc.pages.removeValue(forKey: entry.pageKey) }
                else { inkDoc.pages[entry.pageKey] = list }
                overlayForPageKey(entry.pageKey)?.setContent(
                    strokes: list,
                    textBoxes: inkDoc.texts[entry.pageKey] ?? []
                )
            }

        case let .texts(pageKey, added, removed):
            let toRemove = isRedo ? removed : added
            let toAdd = isRedo ? added : removed
            var list = inkDoc.texts[pageKey] ?? []
            let remIDs = Set(toRemove.map { $0.id })
            if !remIDs.isEmpty {
                list.removeAll { remIDs.contains($0.id) }
                for id in remIDs { inkDoc.deleted[id] = nowMs }
            }
            for tb in toAdd {
                inkDoc.deleted.removeValue(forKey: tb.id)
                list.removeAll { $0.id == tb.id }
                list.append(tb)
            }
            list.sort { $0.t < $1.t }
            if list.isEmpty { inkDoc.texts.removeValue(forKey: pageKey) }
            else { inkDoc.texts[pageKey] = list }
            overlayForPageKey(pageKey)?.setContent(
                strokes: inkDoc.pages[pageKey] ?? [],
                textBoxes: list
            )
        }
    }

    // MARK: - Export Annotated PDF (Pure CoreGraphics, Background Queue)

    func exportAnnotatedPDFAction() {
        commitActiveTextBox()
        guard let res = virtualResult, !res.slots.isEmpty else { return }
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.pdf]
        savePanel.nameFieldStringValue = "\(pdfURL.deletingPathExtension().lastPathComponent) (Annotated).pdf"
        guard let win = window else { return }
        savePanel.beginSheetModal(for: win) { [weak self] response in
            guard response == .OK, let outURL = savePanel.url, let self else { return }
            let slots = res.slots
            let isHobo = res.isHobonichi
            let docCopy = self.inkDoc
            let srcURL = self.pdfURL
            DispatchQueue.global(qos: .userInitiated).async {
                var cgDoc = CGPDFDocument(srcURL as CFURL)
                var drawnPDFPages = 0
                let pdfData = PlatformGraphics.makePDFData(pageSizes: slots.map { $0.size }) { idx, ctx, rect in
                    autoreleasepool {
                        let slot = slots[idx]
                        if isHobo, HobonichiEngine.slotKind(for: slot, isHobo: true) != nil {
                            HobonichiEngine.drawSpread(in: ctx, slot: slot, doc: docCopy, allSlots: slots, isHobo: true)
                        } else if let pdfN = slot.effectivePDFPageNumber {
                            drawnPDFPages += 1
                            if drawnPDFPages >= 50 {
                                cgDoc = CGPDFDocument(srcURL as CFURL)
                                drawnPDFPages = 0
                            }
                            if let cgPage = cgDoc?.page(at: pdfN) {
                                ctx.saveGState()
                                ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
                                ctx.fill(rect)
                                ctx.translateBy(x: 0, y: slot.size.height)
                                ctx.scaleBy(x: 1, y: -1)
                                let xform = cgPage.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true)
                                ctx.concatenate(xform)
                                ctx.clip(to: cgPage.getBoxRect(.cropBox))
                                ctx.drawPDFPage(cgPage)
                                ctx.restoreGState()
                            }
                        } else {
                            slot.template.draw(in: ctx, size: slot.size)
                        }
                        if let strokes = docCopy.pages[slot.key], !strokes.isEmpty {
                            MacPageOverlayView.drawStrokes(strokes, in: ctx)
                        }
                        if let tBoxes = docCopy.texts[slot.key], !tBoxes.isEmpty {
                            MacPageOverlayView.drawTextBoxes(tBoxes, in: ctx)
                        }
                    }
                }
                try? pdfData.write(to: outURL, options: .atomic)
            }
        }
    }

    // MARK: - MacSidebarDelegate

    func sidebarDidSelectPage(at index: Int) {
        guard let doc = pdfView.document, index >= 0, index < doc.pageCount, let p = doc.page(at: index) else { return }
        pdfView.go(to: p)
        updatePageIndicatorAndBookmarkUI()
    }

    func sidebarDidSelectSearchResult(_ item: MacSearchResultItem) {
        pdfView.setCurrentSelection(item.selection, animate: true)
        pdfView.go(to: item.selection)
        updatePageIndicatorAndBookmarkUI()
    }

    // MARK: - Actions & Native Window Tabbing

    @objc func toggleSidebarAction() {
        splitVC.toggleSidebar(nil)
        let isOpen = !(splitVC.splitViewItems.first?.isCollapsed ?? true)
        sidebarVC.setSidebarVisible(isOpen)
    }

    @objc func focusSearchAction() {
        commitActiveTextBox()
        if let first = splitVC.splitViewItems.first, first.isCollapsed {
            splitVC.toggleSidebar(nil)
        }
        sidebarVC.setSidebarVisible(true)
        sidebarVC.focusSearch()
    }

    @objc func highlightSelectionAction() {
        guard let sel = pdfView.currentSelection,
              !(sel.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        canvasView(pdfView, didHighlightSelection: sel)
        pdfView.clearSelection()
    }

    func setToolMode(_ mode: MacToolMode) {
        if mode != .textBox {
            commitActiveTextBox()
        }
        pdfView.toolMode = mode
        modeSegment.selectedSegment = mode.rawValue
        updateOptionsBarVisibility()
    }

    @objc private func modeSegmentChanged() {
        setToolMode(MacToolMode(rawValue: modeSegment.selectedSegment) ?? .read)
    }

    @objc func toggleBookmarkAction() {
        guard let slot = currentSlot() else { return }
        let nowOn = !inkDoc.isBookmarked(slot.key)
        let prev = inkDoc.bookmarks[slot.key]
        inkDoc.bookmarks[slot.key] = PageMark(
            on: nowOn,
            t: Int64(Date().timeIntervalSince1970 * 1000),
            title: prev?.title,
            tag: prev?.tag
        )
        sidebarVC.updateBookmarks(currentBookmarkItems())
        updatePageIndicatorAndBookmarkUI()
        scheduleSave()
    }

    @objc private func paperPopupChanged() {
        let idx = paperPopup.indexOfSelectedItem
        guard idx >= 0 && idx < MacPaperMode.allCases.count else { return }
        MacPreferences.shared.paperMode = MacPaperMode.allCases[idx]
    }

    @objc private func handlePaperModePrefChanged() {
        let mode = MacPreferences.shared.paperMode
        pdfView.applyPaperMode(mode)
        if let idx = MacPaperMode.allCases.firstIndex(of: mode) {
            paperPopup.selectItem(at: idx)
        }
    }

    @objc private func zoomSegmentClicked(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: zoomOutAction()
        case 1: zoomToFitAction()
        case 2: zoomInAction()
        default: break
        }
    }

    @objc func zoomInAction() {
        pdfView.autoScales = false
        pdfView.scaleFactor = min(6.0, pdfView.scaleFactor * 1.2)
    }

    @objc func zoomOutAction() {
        pdfView.autoScales = false
        pdfView.scaleFactor = max(0.25, pdfView.scaleFactor / 1.2)
    }

    @objc func zoomToFitAction() {
        pdfView.autoScales = true
    }

    @objc private func pageFieldSubmitted() {
        let digits = pageField.stringValue.split(separator: "/").first.map(String.init) ?? pageField.stringValue
        if let num = Int(digits.trimmingCharacters(in: .whitespacesAndNewlines)),
           let doc = pdfView.document, num >= 1, num <= doc.pageCount,
           let page = doc.page(at: num - 1) {
            pdfView.go(to: page)
        }
        updatePageIndicatorAndBookmarkUI()
        window?.makeFirstResponder(pdfView)
    }

    @objc func syncNowAction() {
        commitActiveTextBox()
        if !syncManager.config.isConnected {
            onRequestOpenSyncSettings?()
            return
        }
        saveNow(flushDriveImmediately: false)
        triggerDriveSync(forceFolderScan: true)
    }

    @objc override func newWindowForTab(_ sender: Any?) {
        onRequestNewTab?(self)
    }

    @objc private func handlePageChanged() {
        updatePageIndicatorAndBookmarkUI()
        let pageNum = currentPageIndex() + 1
        pagePersistTimer?.cancel()
        let key = lastPageStorageKey
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .milliseconds(1800), leeway: .milliseconds(250))
        t.setEventHandler { [weak self] in
            self?.pagePersistTimer?.cancel()
            self?.pagePersistTimer = nil
            UserDefaults.standard.set(pageNum, forKey: key)
        }
        pagePersistTimer = t
        t.resume()
    }

    private func updatePageIndicatorAndBookmarkUI() {
        let total = max(1, pdfView.document?.pageCount ?? 1)
        let cur = min(total, currentPageIndex() + 1)
        if cur != lastDisplayedPage || total != lastDisplayedTotal {
            lastDisplayedPage = cur
            lastDisplayedTotal = total
            pageField.stringValue = "\(cur) / \(total)"
        }
        let marked = currentSlot().map { inkDoc.isBookmarked($0.key) } ?? false
        if marked != lastDisplayedBookmarked {
            lastDisplayedBookmarked = marked
            bookmarkButton.image = marked ? Self.iconBookmarkFilled : Self.iconBookmark
            bookmarkButton.contentTintColor = marked ? .systemOrange : nil
        }
    }

    // MARK: - Save & Smart Idle Google Drive Sync

    func scheduleSave() {
        isDirty = true
        saveWorkItem?.cancel()
        cancelIdleCheckTimer()
        syncManager.cancelScheduledSync(for: relativePath)
        let item = DispatchWorkItem { [weak self] in
            self?.saveNow(flushDriveImmediately: false)
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: item)
    }

    func saveNow(flushDriveImmediately: Bool = false) {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        guard isDirty else { return }
        if !isInitialInkLoaded {
            pendingSaveAfterLoad = true
            return
        }
        isDirty = false
        var snapshot = inkDoc
        snapshot.name = relativePath
        let targetURL = pdfURL
        let rel = relativePath
        DispatchQueue.global(qos: .utility).async { [weak self] in
            try? snapshot.save(for: targetURL)
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.syncManager.config.isConnected,
                      self.syncManager.config.autoSync,
                      MacPreferences.shared.syncMode == .smart else { return }
                if flushDriveImmediately {
                    self.syncManager.cancelScheduledSync(for: rel)
                    self.triggerDriveSync(forceFolderScan: false)
                } else if self.activeTextEditor == nil {
                    self.syncManager.scheduleBookSync(
                        pdfURL: targetURL,
                        relativePath: rel,
                        delaySeconds: 4.0,
                        localDocProvider: { [weak self] in self?.inkDoc ?? snapshot },
                        onMerged: { [weak self] merged in self?.applyLoadedOrRemoteInkDoc(merged) }
                    )
                    self.scheduleNextIdleCheck(stage: 0)
                }
            }
        }
    }

    private func startSmartDriveSync() {
        guard syncManager.config.isConnected,
              syncManager.config.autoSync,
              MacPreferences.shared.syncMode == .smart else { return }
        let recentlyChecked = lastDriveCheckAt.map { Date().timeIntervalSince($0) < 60.0 } ?? false
        if !recentlyChecked {
            triggerDriveSync(forceFolderScan: true)
        }
        scheduleNextIdleCheck(stage: 0)
    }

    private func triggerDriveSync(forceFolderScan: Bool, onComplete: ((Bool) -> Void)? = nil) {
        guard isInitialInkLoaded, syncManager.config.isConnected else {
            onComplete?(false)
            return
        }
        let snap = inkDoc
        let url = pdfURL
        let rel = relativePath
        lastDriveCheckAt = Date()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let (merged, changed) = await self.syncManager.syncBook(
                pdfURL: url,
                relativePath: rel,
                localDoc: snap,
                forceFolderScan: forceFolderScan
            ) {
                if changed {
                    self.applyLoadedOrRemoteInkDoc(merged)
                }
                onComplete?(changed)
            } else {
                onComplete?(false)
            }
        }
    }

    private func cancelIdleCheckTimer() {
        idleCheckTimer?.cancel()
        idleCheckTimer = nil
    }

    private func scheduleNextIdleCheck(stage: Int) {
        cancelIdleCheckTimer()
        guard syncManager.config.isConnected,
              syncManager.config.autoSync,
              MacPreferences.shared.syncMode == .smart else { return }
        // Never arm idle timers while window is hidden or occluded behind other apps!
        if let win = window, !win.occlusionState.contains(.visible) { return }
        let delaysSec: [Int] = [180, 600]
        guard stage >= 0 && stage < delaysSec.count else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .seconds(delaysSec[stage]), leeway: .seconds(15))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.cancelIdleCheckTimer()
            Task { @MainActor in
                guard !self.isDirty,
                      self.activeTextEditor == nil,
                      self.window?.occlusionState.contains(.visible) == true,
                      self.syncManager.config.isConnected,
                      MacPreferences.shared.syncMode == .smart else {
                    return
                }
                self.triggerDriveSync(forceFolderScan: false) { [weak self] gotUpdate in
                    self?.scheduleNextIdleCheck(stage: gotUpdate ? 0 : stage + 1)
                }
            }
        }
        idleCheckTimer = t
        t.resume()
    }

    // MARK: - NSWindowDelegate

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let win = window else { return }
        if !win.occlusionState.contains(.visible) {
            cancelIdleCheckTimer()
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard isInitialInkLoaded,
              activeTextEditor == nil,
              syncManager.config.isConnected,
              syncManager.config.autoSync,
              MacPreferences.shared.syncMode == .smart else { return }
        let now = Date()
        let awayEnough = lastResignedAt.map { now.timeIntervalSince($0) >= 120.0 } ?? false
        let stale = lastDriveCheckAt.map { now.timeIntervalSince($0) >= 120.0 } ?? false
        if awayEnough || stale {
            triggerDriveSync(forceFolderScan: true)
            scheduleNextIdleCheck(stage: 0)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        lastResignedAt = Date()
    }

    func windowWillClose(_ notification: Notification) {
        cancelIdleCheckTimer()
        pagePersistTimer?.cancel()
        pagePersistTimer = nil
        let finalPage = currentPageIndex() + 1
        if finalPage > 0 {
            UserDefaults.standard.set(finalPage, forKey: lastPageStorageKey)
        }
        commitActiveTextBox()
        saveNow(flushDriveImmediately: true)
        onWindowClosed?(self)
    }

    // MARK: - NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarToggle, .flexibleSpace, .toolMode, .flexibleSpace, .bookmark, .paperMode, .zoomControls, .pageIndicator, .syncStatus]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarToggle, .bookmark, .flexibleSpace, .toolMode, .flexibleSpace, .pageIndicator, .zoomControls, .paperMode, .syncStatus]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier {
        case .sidebarToggle:
            let img = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Sidebar") ?? NSImage()
            let btn = NSButton(image: img, target: self, action: #selector(toggleSidebarAction))
            btn.bezelStyle = .texturedRounded
            item.view = btn
            item.label = "Sidebar"

        case .toolMode:
            modeSegment.selectedSegment = pdfView.toolMode.rawValue
            modeSegment.target = self
            modeSegment.action = #selector(modeSegmentChanged)
            item.view = modeSegment
            item.label = "Mode"

        case .bookmark:
            bookmarkButton.bezelStyle = .texturedRounded
            bookmarkButton.image = NSImage(systemSymbolName: "bookmark", accessibilityDescription: "Bookmark")
            bookmarkButton.target = self
            bookmarkButton.action = #selector(toggleBookmarkAction)
            item.view = bookmarkButton
            item.label = "Bookmark"

        case .paperMode:
            paperPopup.removeAllItems()
            for m in MacPaperMode.allCases { paperPopup.addItem(withTitle: m.title) }
            if let idx = MacPaperMode.allCases.firstIndex(of: MacPreferences.shared.paperMode) {
                paperPopup.selectItem(at: idx)
            }
            paperPopup.target = self
            paperPopup.action = #selector(paperPopupChanged)
            item.view = paperPopup
            item.label = "Paper Mode"

        case .zoomControls:
            let seg = NSSegmentedControl(
                images: [
                    NSImage(systemSymbolName: "minus.magnifyingglass", accessibilityDescription: "Zoom Out") ?? NSImage(),
                    NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Fit") ?? NSImage(),
                    NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: "Zoom In") ?? NSImage()
                ],
                trackingMode: .momentary,
                target: self,
                action: #selector(zoomSegmentClicked(_:))
            )
            item.view = seg
            item.label = "Zoom"

        case .pageIndicator:
            pageField.alignment = .center
            pageField.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            pageField.bezelStyle = .roundedBezel
            pageField.frame = NSRect(x: 0, y: 0, width: 88, height: 24)
            pageField.target = self
            pageField.action = #selector(pageFieldSubmitted)
            item.view = pageField
            item.label = "Page"

        case .syncStatus:
            syncButton.bezelStyle = .texturedRounded
            syncButton.image = NSImage(systemSymbolName: "icloud", accessibilityDescription: "Sync")
            syncButton.imagePosition = .imageOnly
            syncButton.target = self
            syncButton.action = #selector(syncNowAction)
            item.view = syncButton
            item.label = "Sync"

        default:
            return nil
        }
        return item
    }
}
