import AppKit
import PDFKit
import Combine
import UniformTypeIdentifiers

private extension NSToolbarItem.Identifier {
    static let sidebarToggle = NSToolbarItem.Identifier("pencilink.v4.sidebarToggle")
    static let bookmark = NSToolbarItem.Identifier("pencilink.v4.bookmark")
    static let toolMode = NSToolbarItem.Identifier("pencilink.v4.toolMode")
    static let pageIndicator = NSToolbarItem.Identifier("pencilink.v4.pageIndicator")
    static let zoomControls = NSToolbarItem.Identifier("pencilink.v4.zoomControls")
    static let paperMode = NSToolbarItem.Identifier("pencilink.v5.paperMode")
    static let syncStatus = NSToolbarItem.Identifier("pencilink.v4.syncStatus")
    static let diagnostics = NSToolbarItem.Identifier("pencilink.v4.diagnostics")
}

enum MacWorkspaceUndoAction {
    case strokes(entries: [(pageKey: String, added: [InkStroke], removed: [InkStroke])])
    case texts(pageKey: String, added: [InkTextBox], removed: [InkTextBox])
}

/// Lightweight per-tab state retained in memory while a background tab's `IOSurface` buffers are hibernated (0 MB VRAM, 0% CPU).
@MainActor
final class MacTabSession: Identifiable {
    let id: String
    let isLibrary: Bool
    var title: String
    let pdfURL: URL?
    let relativePath: String

    var inkDoc: InkDocument
    var virtualResult: MacVirtualPDFResult?
    var isInitialInkLoaded: Bool = false
    var pendingSaveAfterLoad: Bool = false
    var pendingSavedPageRestore: Int? = nil

    var savedPageIndex: Int = 0
    var savedScrollX: CGFloat = 0
    var savedScrollY: CGFloat = 0
    var savedScaleFactor: CGFloat = 1.0
    var savedAutoScales: Bool = true
    var savedTwoUp: Bool = false

    var undoStack: [MacWorkspaceUndoAction] = []
    var redoStack: [MacWorkspaceUndoAction] = []
    var isDirty: Bool = false
    var lastDriveCheckAt: Date? = nil

    var lastPageStorageKey: String {
        guard let url = pdfURL else { return "" }
        return "pencilink.lastpage." + url.lastPathComponent
    }

    init(id: String, isLibrary: Bool, title: String, pdfURL: URL? = nil, relativePath: String = "") {
        self.id = id
        self.isLibrary = isLibrary
        self.title = title
        self.pdfURL = pdfURL
        self.relativePath = relativePath
        self.inkDoc = InkDocument.empty(name: relativePath)
    }
}

/// Single-window unified macOS Workspace hosting:
/// - **Tab 0 (Pinned):** `MacLibraryViewController` (Vault browser, folders, search, cover thumbnails)
/// - **Tabs 1…N (In-App):** PDF Reader tabs sharing one `MacZeroScrollCanvasView` + `MacIOSurfacePool`
/// - **Zero-Cost Background Tab Hibernation:** Switching tabs detaches & recycles 100% of `IOSurface`s immediately
///   (0.0% CPU, 0 wakeups/s, 0 MB active `IOSurface` VRAM for every background tab).
/// Appearance-aware opaque tab strip container (0% live blur overhead, updates immediately on Dark/Light toggle).
private final class MacTabStripContainerView: NSView {
    let syncProgressLayer = CALayer()
    private var currentFraction: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        syncProgressLayer.backgroundColor = DesignTokens.nsAccent.cgColor
        syncProgressLayer.anchorPoint = .zero
        syncProgressLayer.zPosition = 50
        syncProgressLayer.isHidden = true
        layer?.addSublayer(syncProgressLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        updateProgressFrame(animated: false)
    }

    func setSyncProgress(active: Bool, fraction: Double) {
        if !active {
            currentFraction = 0
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            syncProgressLayer.isHidden = true
            syncProgressLayer.frame = CGRect(x: 0, y: 0, width: 0, height: 2.5)
            CATransaction.commit()
            return
        }
        let target: CGFloat = fraction < 0 ? 0.25 : max(0.04, min(1.0, CGFloat(fraction)))
        currentFraction = target
        if syncProgressLayer.isHidden {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            syncProgressLayer.isHidden = false
            syncProgressLayer.backgroundColor = DesignTokens.nsAccent.cgColor
            syncProgressLayer.frame = CGRect(x: 0, y: 0, width: bounds.width * target, height: 2.5)
            CATransaction.commit()
        } else {
            updateProgressFrame(animated: true)
        }
    }

    private func updateProgressFrame(animated: Bool) {
        guard !syncProgressLayer.isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.18)
        syncProgressLayer.frame = CGRect(x: 0, y: 0, width: (bounds.width * currentFraction).rounded(), height: 2.5)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = DesignTokens.nsChromeSecondary.cgColor
        syncProgressLayer.backgroundColor = DesignTokens.nsAccent.cgColor
    }
}

/// Tactile hover-aware Studio Craft tab pill (100% pure AppKit CALayer, zero idle timers).
private final class MacTabPillView: NSView {
    let isActiveTab: Bool
    private let accentUnderline = NSView()
    private var isHovered = false
    private var tracking: NSTrackingArea?

    init(isActive: Bool) {
        self.isActiveTab = isActive
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = isActive ? 0.9 : 0.5

        accentUnderline.translatesAutoresizingMaskIntoConstraints = false
        accentUnderline.wantsLayer = true
        accentUnderline.layer?.cornerRadius = 1.0
        accentUnderline.layer?.backgroundColor = DesignTokens.nsAccent.cgColor
        accentUnderline.isHidden = !isActive
        addSubview(accentUnderline)
        NSLayoutConstraint.activate([
            accentUnderline.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            accentUnderline.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            accentUnderline.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            accentUnderline.heightAnchor.constraint(equalToConstant: 2)
        ])
        refreshColors(animated: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isActiveTab else { return }
        isHovered = true
        refreshColors(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        guard !isActiveTab else { return }
        isHovered = false
        refreshColors(animated: true)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors(animated: false)
    }

    private func refreshColors(animated: Bool) {
        let bg: CGColor
        let border: CGColor
        if isActiveTab {
            bg = DesignTokens.nsChromePrimary.cgColor
            border = DesignTokens.nsAccent.withAlphaComponent(0.38).cgColor
        } else if isHovered {
            bg = NSColor.labelColor.withAlphaComponent(0.08).cgColor
            border = DesignTokens.nsHairline.cgColor
        } else {
            bg = NSColor.labelColor.withAlphaComponent(0.035).cgColor
            border = NSColor.clear.cgColor
        }
        let apply = {
            self.layer?.backgroundColor = bg
            self.layer?.borderColor = border
            self.accentUnderline.layer?.backgroundColor = DesignTokens.nsAccent.cgColor
        }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                apply()
            }
        } else {
            apply()
        }
    }
}

@MainActor
final class MacWorkspaceWindowController: NSWindowController,
    NSWindowDelegate, NSToolbarDelegate,
    MacZeroScrollCanvasDelegate, MacSidebarDelegate {

    let vault: VaultManager
    let syncManager: DriveSyncManager
    var onRequestOpenSyncSettings: (() -> Void)?
    var onRequestOpenDiagnostics: (() -> Void)?

    private var tabs: [MacTabSession] = []
    private var activeTabID: String = "library"

    // Layout chrome
    private let rootView = NSView()
    private let tabStripContainer = MacTabStripContainerView()
    private let tabScroll = NSScrollView()
    private let tabStack = NSStackView()
    private let contentHost = NSView()

    // Pinned Library tab VC
    private let libraryVC: MacLibraryViewController

    // Reusable Reader Workspace (Sidebar + Options Bar + Zero-Scroll Canvas)
    private let readerSplitVC = NSSplitViewController()
    private let sidebarVC = MacSidebarViewController()
    private let optionsBar = MacToolOptionsBar()
    private var optionsBarHeightConstraint: NSLayoutConstraint?
    let canvasView = MacZeroScrollCanvasView()

    // Toolbar controls
    private let sidebarToggleBtn = NSButton()
    private let modeSegment = NSSegmentedControl()
    private let bookmarkButton = NSButton()
    private let pageField = NSTextField()
    private let zoomSegment = NSSegmentedControl()
    private let paperModeButton = NSButton()
    private let syncButton = NSButton(title: "", target: nil, action: nil)

    // Static cached SF Symbols (ZERO per-scroll NSImage lookups!)
    private static let iconBookmark = NSImage(systemSymbolName: "bookmark", accessibilityDescription: "Bookmark")
    private static let iconBookmarkFilled = NSImage(systemSymbolName: "bookmark.fill", accessibilityDescription: "Bookmarked")
    private static let iconSyncOK = NSImage(systemSymbolName: "checkmark.icloud", accessibilityDescription: "Synced")
    private static let iconSyncing = NSImage(systemSymbolName: "arrow.triangle.2.circlepath.icloud", accessibilityDescription: "Syncing")
    private static let iconSyncError = NSImage(systemSymbolName: "exclamationmark.icloud", accessibilityDescription: "Sync Error")
    private static let iconSyncOff = NSImage(systemSymbolName: "icloud.slash", accessibilityDescription: "Disconnected")

    // Active-tab interaction & timer state (0 timers at idle!)
    private var activeHighlightSlot: PageSlot?
    private var activeHighlightOverlay: MacPageOverlayView?
    private var activeHighlightStart: CGPoint?
    private var activeHighlightPoints: [InkPoint] = []
    private var activeTextEditor: MacInlineTextBoxView?

    private var saveWorkItem: DispatchWorkItem?
    private var idleCheckTimer: DispatchSourceTimer?
    private var lastResignedAt: Date?
    private var lastDisplayedPage: Int = -1
    private var lastDisplayedTotal: Int = -1
    private var lastDisplayedBookmarked: Bool? = nil
    private var lastSyncVisualState: SyncVisualState? = nil
    private var cancellables = Set<AnyCancellable>()

    var activeReaderSession: MacTabSession? {
        tabs.first(where: { $0.id == activeTabID && !$0.isLibrary })
    }

    var canUndoDocument: Bool { !(activeReaderSession?.undoStack.isEmpty ?? true) }
    var canRedoDocument: Bool { !(activeReaderSession?.redoStack.isEmpty ?? true) }
    var hasTextSelection: Bool {
        guard activeReaderSession != nil, let s = canvasView.currentSelection?.string else { return false }
        return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var openTabCount: Int { tabs.count }

    init(vault: VaultManager, syncManager: DriveSyncManager) {
        self.vault = vault
        self.syncManager = syncManager
        self.libraryVC = MacLibraryViewController(vault: vault, syncManager: syncManager)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Pencil Ink"
        win.minSize = NSSize(width: 760, height: 520)
        win.tabbingMode = .disallowed
        win.isReleasedWhenClosed = false
        win.center()
        super.init(window: win)
        win.delegate = self

        tabs = [MacTabSession(id: "library", isLibrary: true, title: "Library")]

        setupToolbar()
        setupWorkspaceHierarchy()
        setupObservers()
        wireLibraryCallbacks()
        switchToTab(id: "library")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        saveWorkItem?.cancel()
        idleCheckTimer?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Toolbar & Single-Window Layout

    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: NSToolbar.Identifier("PencilInkMacWorkspaceToolbarV4"))
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
        // Opaque non-overlapping expanded toolbar (ZERO macOS 26 scroll-edge Liquid Glass blur!)
        window?.toolbarStyle = .expanded
    }

    private func setupWorkspaceHierarchy() {
        guard let contentView = window?.contentView else { return }

        rootView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rootView)

        // In-app Tab Strip (Pinned Library + Open PDF Tabs)
        tabStripContainer.translatesAutoresizingMaskIntoConstraints = false
        tabStripContainer.wantsLayer = true
        tabStripContainer.layer?.backgroundColor = DesignTokens.nsChromeSecondary.cgColor

        let tabBottomLine = NSBox()
        tabBottomLine.boxType = .separator
        tabBottomLine.translatesAutoresizingMaskIntoConstraints = false

        tabStack.orientation = .horizontal
        tabStack.alignment = .centerY
        tabStack.spacing = 4
        tabStack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        tabStack.translatesAutoresizingMaskIntoConstraints = false

        tabScroll.translatesAutoresizingMaskIntoConstraints = false
        tabScroll.drawsBackground = false
        tabScroll.borderType = .noBorder
        tabScroll.hasHorizontalScroller = false
        tabScroll.hasVerticalScroller = false
        tabScroll.documentView = tabStack

        tabStripContainer.addSubview(tabScroll)
        tabStripContainer.addSubview(tabBottomLine)

        contentHost.translatesAutoresizingMaskIntoConstraints = false

        rootView.addSubview(tabStripContainer)
        rootView.addSubview(contentHost)

        NSLayoutConstraint.activate([
            rootView.topAnchor.constraint(equalTo: contentView.topAnchor),
            rootView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rootView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rootView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            tabStripContainer.topAnchor.constraint(equalTo: rootView.topAnchor),
            tabStripContainer.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            tabStripContainer.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            tabStripContainer.heightAnchor.constraint(equalToConstant: 38),

            tabScroll.topAnchor.constraint(equalTo: tabStripContainer.topAnchor),
            tabScroll.leadingAnchor.constraint(equalTo: tabStripContainer.leadingAnchor),
            tabScroll.trailingAnchor.constraint(equalTo: tabStripContainer.trailingAnchor),
            tabScroll.bottomAnchor.constraint(equalTo: tabBottomLine.topAnchor),

            tabBottomLine.leadingAnchor.constraint(equalTo: tabStripContainer.leadingAnchor),
            tabBottomLine.trailingAnchor.constraint(equalTo: tabStripContainer.trailingAnchor),
            tabBottomLine.bottomAnchor.constraint(equalTo: tabStripContainer.bottomAnchor),

            contentHost.topAnchor.constraint(equalTo: tabStripContainer.bottomAnchor),
            contentHost.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            contentHost.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])

        // Build Reusable Reader Split View (Sidebar + Options Bar + MacZeroScrollCanvasView)
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 360
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = true
        sidebarVC.delegate = self

        let canvasHostVC = NSViewController()
        let canvasHostView = NSView(frame: NSRect(x: 0, y: 0, width: 920, height: 740))

        optionsBar.translatesAutoresizingMaskIntoConstraints = false
        optionsBar.isHidden = true
        optionsBar.alphaValue = 0.0
        optionsBar.onStyleChanged = { [weak self] in self?.updateActiveTextBoxStyle() }
        optionsBar.onDuplicateTextBox = { [weak self] in self?.duplicateActiveTextBox() }
        optionsBar.onDeleteTextBox = { [weak self] in self?.deleteActiveTextBox() }
        optionsBar.onCommitTextBox = { [weak self] in self?.commitActiveTextBox() }
        canvasHostView.addSubview(optionsBar)

        canvasView.translatesAutoresizingMaskIntoConstraints = false
        canvasView.canvasDelegate = self
        canvasHostView.addSubview(canvasView)

        let barH = optionsBar.heightAnchor.constraint(equalToConstant: 0)
        optionsBarHeightConstraint = barH

        NSLayoutConstraint.activate([
            optionsBar.topAnchor.constraint(equalTo: canvasHostView.topAnchor),
            optionsBar.leadingAnchor.constraint(equalTo: canvasHostView.leadingAnchor),
            optionsBar.trailingAnchor.constraint(equalTo: canvasHostView.trailingAnchor),
            barH,

            canvasView.topAnchor.constraint(equalTo: optionsBar.bottomAnchor),
            canvasView.leadingAnchor.constraint(equalTo: canvasHostView.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: canvasHostView.trailingAnchor),
            canvasView.bottomAnchor.constraint(equalTo: canvasHostView.bottomAnchor)
        ])

        canvasHostVC.view = canvasHostView
        let mainItem = NSSplitViewItem(viewController: canvasHostVC)
        readerSplitVC.addSplitViewItem(sidebarItem)
        readerSplitVC.addSplitViewItem(mainItem)
    }

    private func wireLibraryCallbacks() {
        libraryVC.onOpenPDF = { [weak self] item in
            self?.openPDFTab(at: item.url, relativePath: item.relativePath)
        }
        libraryVC.onOpenSyncSettings = { [weak self] in
            self?.onRequestOpenSyncSettings?()
        }
        libraryVC.onWillDeletePaths = { [weak self] relPaths in
            self?.closeTabsMatchingRelativePaths(relPaths)
        }
        syncManager.onRemoteDeletedPath = { [weak self] relPath, isFolder in
            self?.closeTabsForRemoteDelete(relativePath: relPath, isFolder: isFolder)
        }
    }

    private func setupObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleToolPrefsChanged),
            name: .macToolPrefsDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRenderQualityChanged),
            name: .macRenderQualityDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePaperModeChanged),
            name: .macPaperModeDidChange,
            object: nil
        )
        syncManager.$statusText
            .combineLatest(
                syncManager.$isTransferActive,
                syncManager.$syncProgressFraction,
                syncManager.$syncPhaseLabel
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text, active, frac, phase in
                guard let self else { return }
                let speed = self.syncManager.syncSpeedText
                let tipBase = phase.isEmpty ? "Google Drive: \(text)" : phase
                self.syncButton.toolTip = speed.isEmpty ? tipBase : "\(tipBase) (\(speed)) — Click to pause/manage"

                self.tabStripContainer.setSyncProgress(active: active, fraction: frac)

                if active {
                    let pctText: String
                    if frac >= 0 {
                        let pct = Int((frac * 100.0).rounded())
                        pctText = speed.isEmpty ? " \(pct)%" : " \(pct)% · \(speed)"
                    } else {
                        pctText = " Syncing…"
                    }
                    self.syncButton.imagePosition = .imageLeading
                    self.syncButton.title = pctText
                    self.syncButton.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
                    self.syncButton.sizeToFit()
                } else {
                    if !self.syncButton.title.isEmpty {
                        self.syncButton.title = ""
                        self.syncButton.imagePosition = .imageOnly
                        self.syncButton.sizeToFit()
                    }
                }

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

    @objc private func handleRenderQualityChanged() {
        if activeReaderSession != nil {
            canvasView.applyRenderQuality(highQualityImages: MacPreferences.shared.highQualityImages)
        }
    }

    @objc private func handlePaperModeChanged() {
        let mode = MacPreferences.shared.paperMode
        updatePaperModeButtonIcon()
        if activeReaderSession != nil {
            canvasView.applyPaperMode(mode)
        }
    }

    private func updatePaperModeButtonIcon() {
        let mode = MacPreferences.shared.paperMode
        paperModeButton.image = NSImage(systemSymbolName: mode.symbolName, accessibilityDescription: mode.title)
        paperModeButton.contentTintColor = (mode == .original) ? nil : DesignTokens.nsWarmGold
        paperModeButton.toolTip = "Paper Mode: \(mode.title)"
    }

    func setLibraryDisplayMode(_ mode: MacLibraryDisplayMode) {
        showLibraryTab(focusSearch: false)
        libraryVC.setDisplayMode(mode)
    }

    // MARK: - In-App Tab Lifecycle & Zero-VRAM Hibernation

    func showLibraryTab(focusSearch: Bool = false) {
        switchToTab(id: "library")
        if focusSearch {
            libraryVC.focusSearchField()
        }
    }

    func chooseVaultFolder() {
        showLibraryTab(focusSearch: false)
        libraryVC.chooseVaultFolder()
    }

    func openPDFTab(at url: URL, relativePath: String) {
        let tabID = url.standardizedFileURL.path
        if tabs.contains(where: { $0.id == tabID }) {
            switchToTab(id: tabID)
            return
        }

        let title = url.deletingPathExtension().lastPathComponent
        let session = MacTabSession(
            id: tabID,
            isLibrary: false,
            title: title,
            pdfURL: url,
            relativePath: relativePath
        )
        tabs.append(session)
        vault.recordRecentlyOpened(relativePath)
        switchToTab(id: tabID)
    }

    func switchToTabAtIndex(_ index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        switchToTab(id: tabs[index].id)
    }

    func cycleTab(delta: Int) {
        guard tabs.count > 1, let curIdx = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        let nextIdx = (curIdx + delta + tabs.count) % tabs.count
        switchToTab(id: tabs[nextIdx].id)
    }

    func closeTab(id: String) {
        guard id != "library", let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closing = tabs[idx]
        let wasActive = (closing.id == activeTabID)

        if wasActive {
            hibernateActiveReaderSession(flushDriveImmediately: true)
        } else {
            saveSessionNow(closing, flushDriveImmediately: true)
        }

        closing.virtualResult = nil
        closing.undoStack.removeAll(keepingCapacity: false)
        closing.redoStack.removeAll(keepingCapacity: false)
        tabs.remove(at: idx)
        if wasActive {
            let fallbackIdx = max(0, idx - 1)
            switchToTab(id: tabs[fallbackIdx].id)
        } else {
            rebuildTabStrip()
        }
    }

    func closeActiveTabOrWindow() {
        if activeTabID != "library" {
            closeTab(id: activeTabID)
        } else {
            window?.performClose(nil)
        }
    }

    func closeTabsMatchingRelativePaths(_ relativePaths: [String]) {
        let lowerSet = Set(relativePaths.map { $0.lowercased() })
        let matchingIDs = tabs.filter { !$0.isLibrary && lowerSet.contains($0.relativePath.lowercased()) }.map { $0.id }
        for tid in matchingIDs {
            if let s = tabs.first(where: { $0.id == tid }) { s.isDirty = false }
            closeTab(id: tid)
        }
    }

    func closeTabsForRemoteDelete(relativePath: String, isFolder: Bool) {
        let low = relativePath.lowercased()
        let prefix = low + "/"
        let matchingIDs = tabs.filter { tab in
            guard !tab.isLibrary else { return false }
            let tl = tab.relativePath.lowercased()
            return isFolder ? (tl.hasPrefix(prefix) || tl == low) : (tl == low)
        }.map { $0.id }
        for tid in matchingIDs {
            if let s = tabs.first(where: { $0.id == tid }) { s.isDirty = false }
            closeTab(id: tid)
        }
    }

    func switchToTab(id: String) {
        guard let target = tabs.first(where: { $0.id == id }) else { return }

        // 1. Hibernate previously active reader tab (frees 100% of IOSurfaces & stops timers!)
        if let prev = activeReaderSession, prev.id != target.id {
            hibernateActiveReaderSession(flushDriveImmediately: false)
        }

        activeTabID = target.id

        // 2. Swap contentHost view cleanly
        for sub in contentHost.subviews {
            sub.removeFromSuperview()
        }

        if target.isLibrary {
            libraryVC.setTabActive(true)
            let libView = libraryVC.view
            libView.translatesAutoresizingMaskIntoConstraints = false
            contentHost.addSubview(libView)
            NSLayoutConstraint.activate([
                libView.topAnchor.constraint(equalTo: contentHost.topAnchor),
                libView.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
                libView.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
                libView.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor)
            ])
            window?.title = "Pencil Ink — Library"
            updateReaderToolbarState(isReader: false)
            scheduleNextIdleCheck(stage: 0)
        } else {
            libraryVC.setTabActive(false)
            let splitView = readerSplitVC.view
            splitView.translatesAutoresizingMaskIntoConstraints = false
            contentHost.addSubview(splitView)
            NSLayoutConstraint.activate([
                splitView.topAnchor.constraint(equalTo: contentHost.topAnchor),
                splitView.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
                splitView.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
                splitView.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor)
            ])

            window?.title = target.title
            updateReaderToolbarState(isReader: true)
            activateReaderSession(target)
        }

        rebuildTabStrip()
    }

    private func hibernateActiveReaderSession(flushDriveImmediately: Bool) {
        guard let session = activeReaderSession else { return }
        cancelIdleCheckTimer()
        commitActiveTextBox()

        session.savedPageIndex = canvasView.currentPageIndex
        session.savedScrollX = canvasView.scrollX
        session.savedScrollY = canvasView.scrollY
        session.savedScaleFactor = canvasView.scaleFactor
        session.savedAutoScales = canvasView.autoScales
        session.savedTwoUp = canvasView.twoUpMode

        if session.savedPageIndex >= 0, !session.lastPageStorageKey.isEmpty {
            UserDefaults.standard.set(session.savedPageIndex + 1, forKey: session.lastPageStorageKey)
        }

        saveSessionNow(session, flushDriveImmediately: flushDriveImmediately)
        canvasView.hibernate()
    }

    private func activateReaderSession(_ session: MacTabSession) {
        lastDisplayedPage = -1
        lastDisplayedTotal = -1
        lastDisplayedBookmarked = nil
        updateOptionsBarVisibility()

        if let res = session.virtualResult, let url = session.pdfURL {
            // Wake hibernated tab cleanly from saved viewport state!
            canvasView.twoUpMode = session.savedTwoUp
            canvasView.configure(
                pdfURL: url,
                document: res.document,
                slots: res.slots,
                isHobonichi: res.isHobonichi,
                initialScale: session.savedScaleFactor,
                initialAutoScales: session.savedAutoScales,
                docSnapshotProvider: { [weak session] in session?.inkDoc ?? InkDocument.empty(name: "") }
            )
            canvasView.restoreViewport(
                scrollX: session.savedScrollX,
                scrollY: session.savedScrollY,
                pageIndex: session.savedPageIndex
            )
            sidebarVC.configure(document: res.document, bookmarks: currentBookmarkItems(for: session))
            updatePageIndicatorAndBookmarkUI()
            startSmartDriveSync(for: session)
            window?.makeFirstResponder(canvasView)
            return
        }

        loadDocumentAndInk(for: session)
    }

    private func rebuildTabStrip() {
        for v in tabStack.arrangedSubviews {
            tabStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        for (idx, tab) in tabs.enumerated() {
            let pill = makeTabPill(for: tab, index: idx, isActive: tab.id == activeTabID)
            tabStack.addArrangedSubview(pill)
        }
        tabStack.layoutSubtreeIfNeeded()
        tabStack.frame = NSRect(origin: .zero, size: NSSize(width: max(tabScroll.bounds.width, tabStack.fittingSize.width), height: 35))
    }

    private func makeTabPill(for tab: MacTabSession, index: Int, isActive: Bool) -> NSView {
        let container = MacTabPillView(isActive: isActive)
        container.translatesAutoresizingMaskIntoConstraints = false

        let displayTitle = tab.isLibrary ? "Library" : String(tab.title.prefix(28))
        let selectBtn = NSButton(title: displayTitle, target: self, action: #selector(didClickTabPill(_:)))
        selectBtn.isBordered = false
        selectBtn.font = NSFont.systemFont(ofSize: 12, weight: isActive ? .semibold : .regular)
        selectBtn.contentTintColor = isActive ? DesignTokens.nsAccent : .labelColor
        selectBtn.tag = index
        selectBtn.toolTip = tab.isLibrary ? "Library (⌘1)" : "\(tab.title) (⌘\(min(9, index + 1)))"
        selectBtn.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(selectBtn)

        if tab.isLibrary {
            selectBtn.image = NSImage(systemSymbolName: isActive ? "books.vertical.fill" : "books.vertical", accessibilityDescription: "Library")
            selectBtn.imagePosition = .imageLeading
            NSLayoutConstraint.activate([
                container.heightAnchor.constraint(equalToConstant: 28),
                selectBtn.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
                selectBtn.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
                selectBtn.centerYAnchor.constraint(equalTo: container.centerYAnchor)
            ])
        } else {
            let closeBtn = NSButton(
                image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab") ?? NSImage(),
                target: self,
                action: #selector(didClickCloseTabPill(_:))
            )
            closeBtn.isBordered = false
            closeBtn.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8.5, weight: .bold)
            closeBtn.contentTintColor = .secondaryLabelColor
            closeBtn.tag = index
            closeBtn.toolTip = "Close Tab (⌘W)"
            closeBtn.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(closeBtn)

            NSLayoutConstraint.activate([
                container.heightAnchor.constraint(equalToConstant: 28),
                selectBtn.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
                selectBtn.centerYAnchor.constraint(equalTo: container.centerYAnchor),

                closeBtn.leadingAnchor.constraint(equalTo: selectBtn.trailingAnchor, constant: 6),
                closeBtn.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -7),
                closeBtn.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                closeBtn.widthAnchor.constraint(equalToConstant: 15),
                closeBtn.heightAnchor.constraint(equalToConstant: 15)
            ])
        }

        return container
    }

    @objc private func didClickTabPill(_ sender: NSButton) {
        switchToTabAtIndex(sender.tag)
    }

    @objc private func didClickCloseTabPill(_ sender: NSButton) {
        guard sender.tag >= 0 && sender.tag < tabs.count else { return }
        closeTab(id: tabs[sender.tag].id)
    }

    private func updateReaderToolbarState(isReader: Bool) {
        sidebarToggleBtn.isEnabled = isReader
        bookmarkButton.isEnabled = isReader
        modeSegment.isEnabled = isReader
        pageField.isEnabled = isReader
        zoomSegment.isEnabled = isReader
        paperModeButton.isEnabled = isReader
        if !isReader {
            pageField.stringValue = "—"
            bookmarkButton.image = Self.iconBookmark
            bookmarkButton.contentTintColor = nil
        }
    }

    private func updateOptionsBarVisibility() {
        let hasActiveBox = (activeTextEditor != nil)
        let shouldShow = (activeReaderSession != nil) && ((canvasView.toolMode != .read) || hasActiveBox)
        let targetH: CGFloat = shouldShow ? 40 : 0
        if shouldShow {
            optionsBar.isHidden = false
            optionsBar.update(for: canvasView.toolMode, hasActiveTextBox: hasActiveBox)
        }
        guard optionsBarHeightConstraint?.constant != targetH else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = DesignTokens.motionQuick
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            optionsBarHeightConstraint?.animator().constant = targetH
            optionsBar.animator().alphaValue = shouldShow ? 1.0 : 0.0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.optionsBarHeightConstraint?.constant == 0 {
                    self.optionsBar.isHidden = true
                }
            }
        })
    }

    // MARK: - Document Loading (Single-Pass PDFDocument + Memory-Mapped CGPDFDocument)

    private func loadDocumentAndInk(for session: MacTabSession) {
        guard let pdfURL = session.pdfURL else { return }
        let sidecar = InkDocument.sidecarURL(for: pdfURL)
        let sidecarSize: Int64 = {
            guard FileManager.default.fileExists(atPath: sidecar.path),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: sidecar.path),
                  let sz = attrs[.size] as? NSNumber else { return 0 }
            return sz.int64Value
        }()

        if sidecarSize < 2 * 1024 * 1024 {
            var loaded = InkDocument.load(for: pdfURL)
            if loaded.name.isEmpty { loaded.name = session.relativePath }
            session.isInitialInkLoaded = true
            if let built = MacVirtualPDFBuilder.build(from: pdfURL, inkDoc: &loaded) {
                session.inkDoc = loaded
                applyVirtualResult(built, to: session, preservePageIndex: nil)
                restoreSavedPageIfPossible(for: session)
            }
            startSmartDriveSync(for: session)
            return
        }

        var emptyDoc = session.inkDoc
        if let built = MacVirtualPDFBuilder.build(from: pdfURL, inkDoc: &emptyDoc) {
            session.inkDoc = emptyDoc
            applyVirtualResult(built, to: session, preservePageIndex: nil)
            restoreSavedPageIfPossible(for: session)
        }

        let rel = session.relativePath
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak session] in
            var loaded = InkDocument.load(for: pdfURL)
            if loaded.name.isEmpty { loaded.name = rel }
            DispatchQueue.main.async {
                guard let self, let session else { return }
                session.isInitialInkLoaded = true
                let hasContent = !loaded.pages.isEmpty
                    || !loaded.blanks.isEmpty
                    || !loaded.bookmarks.isEmpty
                    || !loaded.removed.isEmpty
                    || !loaded.texts.isEmpty
                    || !loaded.deleted.isEmpty
                if hasContent {
                    self.applyLoadedOrRemoteInkDoc(loaded, to: session)
                }
                if let pendingPage = session.pendingSavedPageRestore,
                   let res = session.virtualResult,
                   pendingPage > 1 && pendingPage <= res.slots.count {
                    session.pendingSavedPageRestore = nil
                    session.savedPageIndex = pendingPage - 1
                    if self.activeTabID == session.id {
                        self.canvasView.goToPage(at: pendingPage - 1, triggerSettle: true)
                        self.updatePageIndicatorAndBookmarkUI()
                    }
                }
                if session.pendingSaveAfterLoad {
                    session.pendingSaveAfterLoad = false
                    self.saveSessionNow(session, flushDriveImmediately: false)
                }
                self.startSmartDriveSync(for: session)
            }
        }
    }

    private func applyVirtualResult(_ res: MacVirtualPDFResult, to session: MacTabSession, preservePageIndex: Int?) {
        session.virtualResult = res
        guard activeTabID == session.id, let url = session.pdfURL else { return }
        commitActiveTextBox()
        canvasView.twoUpMode = session.savedTwoUp
        canvasView.configure(
            pdfURL: url,
            document: res.document,
            slots: res.slots,
            isHobonichi: res.isHobonichi,
            initialScale: session.savedScaleFactor,
            initialAutoScales: session.savedAutoScales,
            docSnapshotProvider: { [weak session] in session?.inkDoc ?? InkDocument.empty(name: "") }
        )
        if let idx = preservePageIndex, idx >= 0, idx < res.slots.count {
            canvasView.goToPage(at: idx, triggerSettle: true)
        }
        sidebarVC.configure(document: res.document, bookmarks: currentBookmarkItems(for: session))
        lastDisplayedPage = -1
        updatePageIndicatorAndBookmarkUI()
        window?.makeFirstResponder(canvasView)
    }

    private func restoreSavedPageIfPossible(for session: MacTabSession) {
        guard let res = session.virtualResult else { return }
        let saved = UserDefaults.standard.integer(forKey: session.lastPageStorageKey)
        guard saved > 1 else { return }
        if saved <= res.slots.count {
            session.savedPageIndex = saved - 1
            session.pendingSavedPageRestore = nil
            if activeTabID == session.id {
                canvasView.goToPage(at: saved - 1, triggerSettle: true)
                updatePageIndicatorAndBookmarkUI()
            }
        } else if !session.isInitialInkLoaded {
            session.pendingSavedPageRestore = saved
        }
    }

    private func applyLoadedOrRemoteInkDoc(_ remoteMerged: InkDocument, to session: MacTabSession) {
        var combined = remoteMerged
        for (pageKey, localList) in session.inkDoc.pages {
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
        for (pageKey, localBoxes) in session.inkDoc.texts {
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

        let structureChanged = (session.inkDoc.blanks != combined.blanks || session.inkDoc.removed != combined.removed)
        let curIdx = (activeTabID == session.id) ? canvasView.currentPageIndex : session.savedPageIndex
        session.inkDoc = combined

        if structureChanged, let url = session.pdfURL {
            var docCopy = session.inkDoc
            if let rebuilt = MacVirtualPDFBuilder.build(from: url, inkDoc: &docCopy) {
                session.inkDoc = docCopy
                applyVirtualResult(rebuilt, to: session, preservePageIndex: min(curIdx, max(0, rebuilt.slots.count - 1)))
            }
        } else if activeTabID == session.id {
            canvasView.refreshAllMountedOverlays()
            sidebarVC.updateBookmarks(currentBookmarkItems(for: session))
            updatePageIndicatorAndBookmarkUI()
        }
    }

    private func currentSlot() -> PageSlot? {
        guard let session = activeReaderSession, let res = session.virtualResult else { return nil }
        let idx = canvasView.currentPageIndex
        guard idx >= 0 && idx < res.slots.count else { return nil }
        return res.slots[idx]
    }

    private func currentBookmarkItems(for session: MacTabSession) -> [MacBookmarkItem] {
        guard let res = session.virtualResult else { return [] }
        var out: [MacBookmarkItem] = []
        for (idx, slot) in res.slots.enumerated() where session.inkDoc.isBookmarked(slot.key) {
            let custom = session.inkDoc.bookmarks[slot.key]?.title ?? ""
            let label = custom.isEmpty ? "Page \(idx + 1)" : custom
            out.append(MacBookmarkItem(key: slot.key, pageIndex: idx, label: label))
        }
        return out
    }

    // MARK: - MacZeroScrollCanvasDelegate

    func zeroCanvas(_ view: MacZeroScrollCanvasView, hasAnnotationsForPageKey key: String) -> Bool {
        guard let doc = activeReaderSession?.inkDoc else { return false }
        if let s = doc.pages[key], !s.isEmpty { return true }
        if let t = doc.texts[key], !t.isEmpty { return true }
        return activeTextEditor?.pageKey == key
    }

    func zeroCanvas(_ view: MacZeroScrollCanvasView, strokesForPageKey key: String) -> [InkStroke] {
        activeReaderSession?.inkDoc.pages[key] ?? []
    }

    func zeroCanvas(_ view: MacZeroScrollCanvasView, textBoxesForPageKey key: String) -> [InkTextBox] {
        activeReaderSession?.inkDoc.texts[key] ?? []
    }

    func zeroCanvas(_ view: MacZeroScrollCanvasView, activeHiddenTextBoxIDForPageKey key: String) -> String? {
        (activeTextEditor?.pageKey == key) ? activeTextEditor?.originalBox?.id : nil
    }

    func zeroCanvas(_ view: MacZeroScrollCanvasView, willUnmountOverlay overlay: MacPageOverlayView) {
        if activeTextEditor?.hostOverlay === overlay {
            commitActiveTextBox()
        }
    }

    func zeroCanvasDidClickOutsideTextBox(_ view: MacZeroScrollCanvasView) {
        if activeTextEditor != nil {
            commitActiveTextBox()
        }
    }

    func zeroCanvas(_ view: MacZeroScrollCanvasView, didChangeCurrentPageIndex index: Int) {
        activeReaderSession?.savedPageIndex = index
        updatePageIndicatorAndBookmarkUI()
    }

    func zeroCanvas(_ view: MacZeroScrollCanvasView, didRequestPersistPageIndex index: Int) {
        guard let session = activeReaderSession, !session.lastPageStorageKey.isEmpty else { return }
        session.savedPageIndex = index
        UserDefaults.standard.set(index + 1, forKey: session.lastPageStorageKey)
    }

    func zeroCanvas(_ view: MacZeroScrollCanvasView, didHighlightSelection selection: PDFSelection, pageIndex: Int) {
        guard let session = activeReaderSession, let res = session.virtualResult,
              pageIndex >= 0, pageIndex < res.slots.count,
              let page = res.document.page(at: pageIndex) else { return }
        let slot = res.slots[pageIndex]
        let lines = selection.selectionsByLine()
        guard !lines.isEmpty else { return }

        let crop = page.bounds(for: .cropBox)
        let colorHex = MacPreferences.shared.activeHlColorHex
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        var added: [InkStroke] = []

        for lineSel in lines {
            let pdfRect = lineSel.bounds(for: page)
            guard pdfRect.width > 1, pdfRect.height > 1 else { continue }
            let sx = slot.size.width / max(1.0, crop.width)
            let sy = slot.size.height / max(1.0, crop.height)
            let topLeftRect = CGRect(
                x: (pdfRect.minX - crop.minX) * sx,
                y: (crop.maxY - pdfRect.maxY) * sy,
                width: pdfRect.width * sx,
                height: pdfRect.height * sy
            )
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
            var list = session.inkDoc.pages[slot.key] ?? []
            list.append(stroke)
            session.inkDoc.pages[slot.key] = list
            canvasView.appendStroke(stroke, forPageKey: slot.key)
            added.append(stroke)
        }

        if !added.isEmpty {
            pushUndo(.strokes(entries: [(pageKey: slot.key, added: added, removed: [])]), on: session)
            scheduleSave(for: session)
        }
    }

    func zeroCanvas(_ view: MacZeroScrollCanvasView, didBeginHighlightAt pagePoint: CGPoint, pageIndex: Int, overlay: MacPageOverlayView) {
        guard let session = activeReaderSession, let res = session.virtualResult,
              pageIndex >= 0, pageIndex < res.slots.count else { return }
        cancelIdleCheckTimer()
        syncManager.cancelScheduledSync(for: session.relativePath)
        activeHighlightSlot = res.slots[pageIndex]
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

    func zeroCanvas(_ view: MacZeroScrollCanvasView, didDragHighlightTo pagePoint: CGPoint, pageIndex: Int, shiftHeld: Bool) {
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

    func zeroCanvas(_ view: MacZeroScrollCanvasView, didEndHighlightOn pageIndex: Int) {
        defer {
            activeHighlightOverlay?.clearLiveHighlight()
            activeHighlightOverlay = nil
            activeHighlightSlot = nil
            activeHighlightStart = nil
            activeHighlightPoints.removeAll(keepingCapacity: true)
        }
        guard let session = activeReaderSession, let slot = activeHighlightSlot, !activeHighlightPoints.isEmpty else { return }
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
        var list = session.inkDoc.pages[slot.key] ?? []
        list.append(stroke)
        session.inkDoc.pages[slot.key] = list
        activeHighlightOverlay?.appendStroke(stroke)
        pushUndo(.strokes(entries: [(pageKey: slot.key, added: [stroke], removed: [])]), on: session)
        scheduleSave(for: session)
    }

    func zeroCanvas(_ view: MacZeroScrollCanvasView, didEraseHighlightAt pagePoint: CGPoint, pageIndex: Int) {
        guard let session = activeReaderSession, let res = session.virtualResult,
              pageIndex >= 0, pageIndex < res.slots.count else { return }
        let slot = res.slots[pageIndex]
        guard let list = session.inkDoc.pages[slot.key], !list.isEmpty else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        var dirty = CGRect.null
        var removed: [InkStroke] = []
        var kept: [InkStroke] = []
        for s in list {
            if s.tool == "highlighter" && StrokeGeometry.strokeHits(s, point: pagePoint, radius: 10.0) {
                let pad = CGFloat(s.size) * 2.0 + 8.0
                dirty = dirty.union(s.boundingBox().insetBy(dx: -pad, dy: -pad))
                session.inkDoc.deleted[s.id] = nowMs
                removed.append(s)
            } else {
                kept.append(s)
            }
        }
        if !removed.isEmpty {
            if kept.isEmpty { session.inkDoc.pages.removeValue(forKey: slot.key) }
            else { session.inkDoc.pages[slot.key] = kept }
            canvasView.refreshOverlay(
                forPageKey: slot.key,
                strokes: kept,
                textBoxes: session.inkDoc.texts[slot.key] ?? [],
                dirtyPageRect: dirty
            )
            pushUndo(.strokes(entries: [(pageKey: slot.key, added: [], removed: removed)]), on: session)
            scheduleSave(for: session)
        }
    }

    func zeroCanvas(_ view: MacZeroScrollCanvasView, didDoubleClickInReadModeAt pagePoint: CGPoint, pageIndex: Int, overlay: MacPageOverlayView) -> Bool {
        guard let session = activeReaderSession, let res = session.virtualResult,
              pageIndex >= 0, pageIndex < res.slots.count else { return false }
        let slot = res.slots[pageIndex]
        let existing = session.inkDoc.texts[slot.key] ?? []
        for tb in existing.reversed() {
            if tb.measuredRect().insetBy(dx: -6, dy: -6).contains(pagePoint) {
                openTextBoxEditor(for: tb, original: tb, on: overlay)
                return true
            }
        }
        return false
    }

    func zeroCanvas(_ view: MacZeroScrollCanvasView, didClickTextBoxAt pagePoint: CGPoint, pageIndex: Int, overlay: MacPageOverlayView) {
        guard let session = activeReaderSession, let res = session.virtualResult,
              pageIndex >= 0, pageIndex < res.slots.count else { return }
        let slot = res.slots[pageIndex]
        let existing = session.inkDoc.texts[slot.key] ?? []
        for tb in existing.reversed() {
            if tb.measuredRect().insetBy(dx: -6, dy: -6).contains(pagePoint) {
                openTextBoxEditor(for: tb, original: tb, on: overlay)
                return
            }
        }

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

    // MARK: - Inline Text Box Lifecycle

    private func openTextBoxEditor(for box: InkTextBox, original: InkTextBox?, on overlay: MacPageOverlayView) {
        guard let session = activeReaderSession else { return }
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
            guard let self, let rel = self.activeReaderSession?.relativePath else { return }
            self.cancelIdleCheckTimer()
            self.syncManager.cancelScheduledSync(for: rel)
        }
        editor.onCommitRequested = { [weak self] in
            self?.commitActiveTextBox()
        }

        cancelIdleCheckTimer()
        syncManager.cancelScheduledSync(for: session.relativePath)
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

        guard let session = activeReaderSession else { return }
        let key = ed.pageKey
        let original = ed.originalBox
        var finalBox = ed.box
        let cleaned = finalBox.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var list = session.inkDoc.texts[key] ?? []
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        if cleaned.isEmpty {
            if let orig = original {
                list.removeAll { $0.id == orig.id }
                session.inkDoc.deleted[orig.id] = nowMs
                if list.isEmpty { session.inkDoc.texts.removeValue(forKey: key) }
                else { session.inkDoc.texts[key] = list }
                canvasView.refreshOverlay(forPageKey: key, strokes: session.inkDoc.pages[key] ?? [], textBoxes: list, hiddenTextBoxID: nil)
                pushUndo(.texts(pageKey: key, added: [], removed: [orig]), on: session)
                scheduleSave(for: session)
            } else {
                overlay?.setHiddenTextBoxID(nil)
            }
            window?.makeFirstResponder(canvasView)
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
                session.inkDoc.texts[key] = list
                canvasView.refreshOverlay(forPageKey: key, strokes: session.inkDoc.pages[key] ?? [], textBoxes: list, hiddenTextBoxID: nil)
                pushUndo(.texts(pageKey: key, added: [finalBox], removed: [orig]), on: session)
                scheduleSave(for: session)
            } else {
                overlay?.setHiddenTextBoxID(nil)
            }
        } else {
            list.append(finalBox)
            session.inkDoc.texts[key] = list
            canvasView.refreshOverlay(forPageKey: key, strokes: session.inkDoc.pages[key] ?? [], textBoxes: list, hiddenTextBoxID: nil)
            pushUndo(.texts(pageKey: key, added: [finalBox], removed: []), on: session)
            scheduleSave(for: session)
        }
        window?.makeFirstResponder(canvasView)
    }

    func duplicateActiveTextBox() {
        guard let session = activeReaderSession, let ed = activeTextEditor, let overlay = ed.hostOverlay else { return }
        var copy = ed.box
        let key = ed.pageKey
        commitActiveTextBox()
        guard !copy.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        copy.id = InkStroke.newID()
        copy.t = Int64(Date().timeIntervalSince1970 * 1000)
        copy.x = min(Double(overlay.slot.size.width) - copy.w - 6, copy.x + 16)
        copy.y = min(Double(overlay.slot.size.height) - 32, copy.y + 16)
        var list = session.inkDoc.texts[key] ?? []
        list.append(copy)
        session.inkDoc.texts[key] = list
        overlay.setContent(strokes: session.inkDoc.pages[key] ?? [], textBoxes: list)
        pushUndo(.texts(pageKey: key, added: [copy], removed: []), on: session)
        scheduleSave(for: session)
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

        if let session = activeReaderSession, let orig = orig {
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            var list = session.inkDoc.texts[key] ?? []
            list.removeAll { $0.id == orig.id }
            session.inkDoc.deleted[orig.id] = nowMs
            if list.isEmpty { session.inkDoc.texts.removeValue(forKey: key) }
            else { session.inkDoc.texts[key] = list }
            canvasView.refreshOverlay(forPageKey: key, strokes: session.inkDoc.pages[key] ?? [], textBoxes: list, hiddenTextBoxID: nil)
            pushUndo(.texts(pageKey: key, added: [], removed: [orig]), on: session)
            scheduleSave(for: session)
        } else {
            overlay?.setHiddenTextBoxID(nil)
        }
        window?.makeFirstResponder(canvasView)
    }

    // MARK: - Unified Document Undo / Redo

    private func pushUndo(_ action: MacWorkspaceUndoAction, on session: MacTabSession) {
        session.undoStack.append(action)
        if session.undoStack.count > 100 { session.undoStack.removeFirst() }
        session.redoStack.removeAll()
    }

    func performDocumentUndo() {
        guard let session = activeReaderSession else { return }
        commitActiveTextBox()
        guard let action = session.undoStack.popLast() else { return }
        applyUndo(action, isRedo: false, on: session)
        session.redoStack.append(action)
        scheduleSave(for: session)
    }

    func performDocumentRedo() {
        guard let session = activeReaderSession else { return }
        commitActiveTextBox()
        guard let action = session.redoStack.popLast() else { return }
        applyUndo(action, isRedo: true, on: session)
        session.undoStack.append(action)
        scheduleSave(for: session)
    }

    private func applyUndo(_ action: MacWorkspaceUndoAction, isRedo: Bool, on session: MacTabSession) {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        switch action {
        case let .strokes(entries):
            for entry in entries {
                let toRemove = isRedo ? entry.removed : entry.added
                let toAdd = isRedo ? entry.added : entry.removed
                var list = session.inkDoc.pages[entry.pageKey] ?? []
                let remIDs = Set(toRemove.map { $0.id })
                if !remIDs.isEmpty {
                    list.removeAll { remIDs.contains($0.id) }
                    for id in remIDs { session.inkDoc.deleted[id] = nowMs }
                }
                for s in toAdd {
                    session.inkDoc.deleted.removeValue(forKey: s.id)
                    list.append(s)
                }
                list.sort { $0.t < $1.t }
                if list.isEmpty { session.inkDoc.pages.removeValue(forKey: entry.pageKey) }
                else { session.inkDoc.pages[entry.pageKey] = list }
                canvasView.refreshOverlay(
                    forPageKey: entry.pageKey,
                    strokes: list,
                    textBoxes: session.inkDoc.texts[entry.pageKey] ?? []
                )
            }

        case let .texts(pageKey, added, removed):
            let toRemove = isRedo ? removed : added
            let toAdd = isRedo ? added : removed
            var list = session.inkDoc.texts[pageKey] ?? []
            let remIDs = Set(toRemove.map { $0.id })
            if !remIDs.isEmpty {
                list.removeAll { remIDs.contains($0.id) }
                for id in remIDs { session.inkDoc.deleted[id] = nowMs }
            }
            for tb in toAdd {
                session.inkDoc.deleted.removeValue(forKey: tb.id)
                list.removeAll { $0.id == tb.id }
                list.append(tb)
            }
            list.sort { $0.t < $1.t }
            if list.isEmpty { session.inkDoc.texts.removeValue(forKey: pageKey) }
            else { session.inkDoc.texts[pageKey] = list }
            canvasView.refreshOverlay(
                forPageKey: pageKey,
                strokes: session.inkDoc.pages[pageKey] ?? [],
                textBoxes: list
            )
        }
    }

    // MARK: - Export Annotated PDF (Edge-to-Edge CoreGraphics on Background Queue)

    func exportAnnotatedPDFAction() {
        guard let session = activeReaderSession, let res = session.virtualResult, let srcURL = session.pdfURL, !res.slots.isEmpty else { return }
        commitActiveTextBox()
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.pdf]
        savePanel.nameFieldStringValue = "\(srcURL.deletingPathExtension().lastPathComponent) (Annotated).pdf"
        guard let win = window else { return }
        savePanel.beginSheetModal(for: win) { response in
            guard response == .OK, let outURL = savePanel.url else { return }
            let slots = res.slots
            let isHobo = res.isHobonichi
            let docCopy = session.inkDoc
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
                                MacProgressivePDFRenderer.drawPDFPageEdgeToEdge(
                                    cgPage,
                                    in: ctx,
                                    pixelW: max(1, Int(slot.size.width.rounded())),
                                    pixelH: max(1, Int(slot.size.height.rounded()))
                                )
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

    // MARK: - Automated v4.0 Self-Test Diagnostics Hooks

    func diagnosticsEnvironmentSummary() -> String {
        guard let session = activeReaderSession else { return "Library Tab (No active PDF)" }
        let count = session.virtualResult?.slots.count ?? 0
        let strokeTotal = session.inkDoc.pages.values.reduce(0) { $0 + $1.count }
        let textTotal = session.inkDoc.texts.values.reduce(0) { $0 + $1.count }
        let fileName = session.pdfURL?.lastPathComponent ?? session.title
        let cal = MacEnergyImpactCalibrator.shared.weights.sourceDescription
        return "\(fileName) (\(count) pages, \(strokeTotal) strokes, \(textTotal) text boxes, Engine=IOSurface-LZ4-Sub5-v5.1, Cal=\(cal))"
    }

    func diagnosticsPageCount() -> Int { activeReaderSession?.virtualResult?.slots.count ?? 0 }
    func diagnosticsCurrentPageIndex() -> Int { canvasView.currentPageIndex }
    func diagnosticsToolMode() -> MacToolMode { canvasView.toolMode }
    func diagnosticsScaleFactor() -> CGFloat { canvasView.scaleFactor }

    func diagnosticsGoToPage(_ idx: Int) {
        canvasView.goToPage(at: idx, triggerSettle: true)
    }

    func diagnosticsScrollBy(deltaY: CGFloat, gestureEnded: Bool = false) -> Bool {
        canvasView.applyScrollDelta(dx: 0, dy: deltaY, gestureEnded: gestureEnded)
    }

    func diagnosticsPreviewZoom(_ factor: CGFloat) {
        canvasView.previewLiveZoom(to: factor)
    }

    func diagnosticsCommitZoom() {
        canvasView.commitLiveZoom()
    }

    func diagnosticsRestore(pageIndex: Int) {
        canvasView.autoScales = true
        canvasView.goToPage(at: pageIndex, triggerSettle: true)
        updatePageIndicatorAndBookmarkUI()
    }

    // MARK: - MacSidebarDelegate

    func sidebarDidSelectPage(at index: Int) {
        canvasView.goToPage(at: index, triggerSettle: true)
        updatePageIndicatorAndBookmarkUI()
    }

    func sidebarDidSelectSearchResult(_ item: MacSearchResultItem) {
        canvasView.revealSelection(item.selection)
        updatePageIndicatorAndBookmarkUI()
    }

    // MARK: - Toolbar & Menu Actions

    @objc func toggleSidebarAction() {
        guard activeReaderSession != nil else { return }
        readerSplitVC.toggleSidebar(nil)
        let isOpen = !(readerSplitVC.splitViewItems.first?.isCollapsed ?? true)
        sidebarVC.setSidebarVisible(isOpen)
    }

    @objc func focusSearchAction() {
        if activeReaderSession == nil {
            libraryVC.focusSearchField()
            return
        }
        commitActiveTextBox()
        if let first = readerSplitVC.splitViewItems.first, first.isCollapsed {
            readerSplitVC.toggleSidebar(nil)
        }
        sidebarVC.setSidebarVisible(true)
        sidebarVC.focusSearch()
    }

    @objc func highlightSelectionAction() {
        guard let sel = canvasView.currentSelection,
              let idx = canvasView.currentSelectionPageIndex,
              !(sel.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        zeroCanvas(canvasView, didHighlightSelection: sel, pageIndex: idx)
        canvasView.clearSelection()
    }

    func setToolMode(_ mode: MacToolMode) {
        if mode != .textBox {
            commitActiveTextBox()
        }
        canvasView.toolMode = mode
        modeSegment.selectedSegment = mode.rawValue
        updateOptionsBarVisibility()
    }

    @objc private func modeSegmentChanged() {
        setToolMode(MacToolMode(rawValue: modeSegment.selectedSegment) ?? .read)
    }

    @objc func toggleBookmarkAction() {
        guard let session = activeReaderSession, let slot = currentSlot() else { return }
        let nowOn = !session.inkDoc.isBookmarked(slot.key)
        let prev = session.inkDoc.bookmarks[slot.key]
        session.inkDoc.bookmarks[slot.key] = PageMark(
            on: nowOn,
            t: Int64(Date().timeIntervalSince1970 * 1000),
            title: prev?.title,
            tag: prev?.tag
        )
        sidebarVC.updateBookmarks(currentBookmarkItems(for: session))
        updatePageIndicatorAndBookmarkUI()
        scheduleSave(for: session)
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
        guard activeReaderSession != nil else { return }
        canvasView.setScaleFactor(canvasView.scaleFactor * 1.2)
    }

    @objc func zoomOutAction() {
        guard activeReaderSession != nil else { return }
        canvasView.setScaleFactor(canvasView.scaleFactor / 1.2)
    }

    @objc func zoomToFitAction() {
        guard activeReaderSession != nil else { return }
        canvasView.autoScales = true
    }

    @objc func toggleTwoUpAction() {
        guard activeReaderSession != nil else { return }
        canvasView.twoUpMode.toggle()
    }

    @objc private func pageFieldSubmitted() {
        guard let session = activeReaderSession, let res = session.virtualResult else { return }
        let digits = pageField.stringValue.split(separator: "/").first.map(String.init) ?? pageField.stringValue
        if let num = Int(digits.trimmingCharacters(in: .whitespacesAndNewlines)),
           num >= 1, num <= res.slots.count {
            canvasView.goToPage(at: num - 1, triggerSettle: true)
        }
        updatePageIndicatorAndBookmarkUI()
        window?.makeFirstResponder(canvasView)
    }

    @objc func syncNowAction() {
        commitActiveTextBox()
        if !syncManager.config.isConnected {
            onRequestOpenSyncSettings?()
            return
        }
        if syncManager.isTransferActive {
            let m = NSMenu()
            let phase = syncManager.syncPhaseLabel.isEmpty ? "Sync in progress…" : syncManager.syncPhaseLabel
            let infoItem = NSMenuItem(title: phase, action: nil, keyEquivalent: "")
            infoItem.isEnabled = false
            m.addItem(infoItem)
            m.addItem(.separator())
            let pauseItem = NSMenuItem(title: "Pause Transfer (Resumes at 8 MB Chunk)", action: #selector(pauseTransferAction), keyEquivalent: "")
            pauseItem.target = self
            m.addItem(pauseItem)
            let settingsItem = NSMenuItem(title: "Google Drive Settings…", action: #selector(openSyncSettingsFromMenu), keyEquivalent: "")
            settingsItem.target = self
            m.addItem(settingsItem)
            m.popUp(positioning: nil, at: NSPoint(x: 0, y: syncButton.bounds.height + 4), in: syncButton)
            return
        }
        if let session = activeReaderSession {
            saveSessionNow(session, flushDriveImmediately: false)
            triggerDriveSync(for: session, forceFolderScan: true)
        } else if vault.vaultURL != nil {
            Task { _ = await syncManager.syncVault(vault: vault, force: true) }
        }
    }

    @objc private func pauseTransferAction() {
        syncManager.cancelActiveTransfer()
    }

    @objc private func openSyncSettingsFromMenu() {
        onRequestOpenSyncSettings?()
    }

    @objc private func openDiagnosticsAction() {
        onRequestOpenDiagnostics?()
    }

    @objc private func showPaperModeMenu(_ sender: NSButton) {
        let m = NSMenu()
        let cur = MacPreferences.shared.paperMode
        for (idx, mode) in MacPaperMode.allCases.enumerated() {
            let item = NSMenuItem(title: mode.title, action: #selector(selectPaperModeFromMenu(_:)), keyEquivalent: "")
            item.tag = idx
            item.target = self
            item.state = (mode == cur) ? .on : .off
            item.image = NSImage(systemSymbolName: mode.symbolName, accessibilityDescription: mode.title)
            m.addItem(item)
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func selectPaperModeFromMenu(_ sender: NSMenuItem) {
        let all = MacPaperMode.allCases
        guard sender.tag >= 0 && sender.tag < all.count else { return }
        MacPreferences.shared.paperMode = all[sender.tag]
    }

    private func updatePageIndicatorAndBookmarkUI() {
        guard let session = activeReaderSession else { return }
        let total = max(1, session.virtualResult?.slots.count ?? 1)
        let cur = min(total, canvasView.currentPageIndex + 1)
        if cur != lastDisplayedPage || total != lastDisplayedTotal {
            lastDisplayedPage = cur
            lastDisplayedTotal = total
            pageField.stringValue = "\(cur) / \(total)"
        }
        let marked = currentSlot().map { session.inkDoc.isBookmarked($0.key) } ?? false
        if marked != lastDisplayedBookmarked {
            lastDisplayedBookmarked = marked
            bookmarkButton.image = marked ? Self.iconBookmarkFilled : Self.iconBookmark
            bookmarkButton.contentTintColor = marked ? .systemOrange : nil
        }
    }

    // MARK: - Save & Smart Idle Google Drive Sync

    private func scheduleSave(for session: MacTabSession) {
        session.isDirty = true
        saveWorkItem?.cancel()
        cancelIdleCheckTimer()
        syncManager.cancelScheduledSync(for: session.relativePath)
        let item = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session else { return }
            self.saveSessionNow(session, flushDriveImmediately: false)
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.50, execute: item)
    }

    func saveAllDirtySessionsBeforeTerminate() {
        commitActiveTextBox()
        if let active = activeReaderSession {
            active.savedPageIndex = canvasView.currentPageIndex
            if !active.lastPageStorageKey.isEmpty {
                UserDefaults.standard.set(active.savedPageIndex + 1, forKey: active.lastPageStorageKey)
            }
        }
        for session in tabs where !session.isLibrary {
            saveSessionNow(session, flushDriveImmediately: false)
        }
        canvasView.hibernate()
    }

    private func saveSessionNow(_ session: MacTabSession, flushDriveImmediately: Bool) {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        guard session.isDirty, let targetURL = session.pdfURL else { return }
        if !session.isInitialInkLoaded {
            session.pendingSaveAfterLoad = true
            return
        }
        session.isDirty = false
        var snapshot = session.inkDoc
        snapshot.name = session.relativePath
        let rel = session.relativePath
        DispatchQueue.global(qos: .utility).async { [weak self, weak session] in
            try? snapshot.save(for: targetURL)
            Task { @MainActor [weak self, weak session] in
                guard let self, let session else { return }
                guard self.syncManager.config.isConnected,
                      self.syncManager.config.autoSync,
                      MacPreferences.shared.syncMode == .smart else { return }
                if flushDriveImmediately {
                    self.syncManager.cancelScheduledSync(for: rel)
                    self.triggerDriveSync(for: session, forceFolderScan: false)
                } else if self.activeTextEditor == nil {
                    self.syncManager.scheduleBookSync(
                        pdfURL: targetURL,
                        relativePath: rel,
                        delaySeconds: 1.6,
                        localDocProvider: { [weak session] in session?.inkDoc ?? snapshot },
                        onMerged: { [weak self, weak session] merged in
                            guard let self, let session else { return }
                            self.applyLoadedOrRemoteInkDoc(merged, to: session)
                        }
                    )
                    if self.activeTabID == session.id {
                        self.scheduleNextIdleCheck(stage: 0)
                    }
                }
            }
        }
    }

    private func startSmartDriveSync(for session: MacTabSession) {
        guard syncManager.config.isConnected,
              syncManager.config.autoSync,
              MacPreferences.shared.syncMode == .smart else { return }
        let recentlyChecked = session.lastDriveCheckAt.map { Date().timeIntervalSince($0) < 60.0 } ?? false
        if !recentlyChecked {
            triggerDriveSync(for: session, forceFolderScan: true)
        }
        scheduleNextIdleCheck(stage: 0)
    }

    private func triggerDriveSync(for session: MacTabSession, forceFolderScan: Bool, onComplete: ((Bool) -> Void)? = nil) {
        guard session.isInitialInkLoaded, syncManager.config.isConnected, let url = session.pdfURL else {
            onComplete?(false)
            return
        }
        let snap = session.inkDoc
        let rel = session.relativePath
        session.lastDriveCheckAt = Date()
        Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            if let (merged, changed) = await self.syncManager.syncBook(
                pdfURL: url,
                relativePath: rel,
                localDoc: snap,
                forceFolderScan: forceFolderScan
            ) {
                if changed {
                    self.applyLoadedOrRemoteInkDoc(merged, to: session)
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

    /// Foreground-only Adaptive Changes-API Pulse (~300 B when idle, 0 folder scans when unchanged!):
    /// - Active collaboration (stages 0..4): every 6s -> iPad strokes appear on MacBook in <10 seconds!
    /// - Calm (stages 5..8): every 15s
    /// - Idle (stages 9..12): every 45s
    /// - Deep idle (stage 13+): every 180s (pauses completely when window is occluded/minimized!)
    private func scheduleNextIdleCheck(stage: Int) {
        cancelIdleCheckTimer()
        guard syncManager.config.isConnected,
              syncManager.config.autoSync,
              MacPreferences.shared.syncMode == .smart else { return }
        if let win = window, !win.occlusionState.contains(.visible) { return }

        let baseDelay: Int
        if stage < 5 { baseDelay = 6 }
        else if stage < 9 { baseDelay = 15 }
        else if stage < 13 { baseDelay = 45 }
        else { baseDelay = 180 }
        let delaySec = ProcessInfo.processInfo.isLowPowerModeEnabled ? (baseDelay * 2) : baseDelay
        let leewaySec = max(1, min(10, delaySec / 3))

        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .seconds(delaySec), leeway: .seconds(leewaySec))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.cancelIdleCheckTimer()
            Task { @MainActor in
                guard self.window?.occlusionState.contains(.visible) == true,
                      self.syncManager.config.isConnected,
                      self.syncManager.config.autoSync,
                      MacPreferences.shared.syncMode == .smart else {
                    return
                }
                if self.activeTextEditor != nil || (self.activeReaderSession?.isDirty == true) {
                    self.scheduleNextIdleCheck(stage: 0)
                    return
                }
                let activeRel = self.activeReaderSession?.relativePath
                let check = await self.syncManager.checkDriveChangesLightly(forBookRelativePath: activeRel)
                switch check {
                case .bookChanged:
                    if let session = self.activeReaderSession {
                        self.triggerDriveSync(for: session, forceFolderScan: false) { [weak self] _ in
                            self?.scheduleNextIdleCheck(stage: 0)
                        }
                    } else {
                        self.scheduleNextIdleCheck(stage: 0)
                    }
                case .vaultStructureChanged:
                    if self.vault.vaultURL != nil {
                        _ = await self.syncManager.syncVault(vault: self.vault, force: true)
                    }
                    self.scheduleNextIdleCheck(stage: 0)
                case .noChanges, .failed:
                    self.scheduleNextIdleCheck(stage: min(stage + 1, 14))
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
        } else if idleCheckTimer == nil {
            scheduleNextIdleCheck(stage: 0)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard activeTextEditor == nil,
              syncManager.config.isConnected,
              syncManager.config.autoSync,
              MacPreferences.shared.syncMode == .smart else { return }
        let now = Date()
        let awaySec = lastResignedAt.map { now.timeIntervalSince($0) } ?? 0
        if awaySec >= 6.0 {
            let activeRel = activeReaderSession?.relativePath
            Task { @MainActor [weak self] in
                guard let self else { return }
                let res = await self.syncManager.checkDriveChangesLightly(forBookRelativePath: activeRel)
                switch res {
                case .bookChanged:
                    if let s = self.activeReaderSession, s.isInitialInkLoaded {
                        self.triggerDriveSync(for: s, forceFolderScan: false)
                    }
                case .vaultStructureChanged:
                    if self.vault.vaultURL != nil {
                        _ = await self.syncManager.syncVault(vault: self.vault, force: true)
                    }
                case .noChanges, .failed:
                    break
                }
                self.scheduleNextIdleCheck(stage: 0)
            }
        } else if idleCheckTimer == nil {
            scheduleNextIdleCheck(stage: 0)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        lastResignedAt = Date()
    }

    func windowWillClose(_ notification: Notification) {
        cancelIdleCheckTimer()
        if activeReaderSession != nil {
            hibernateActiveReaderSession(flushDriveImmediately: true)
        }
        for session in tabs where !session.isLibrary {
            saveSessionNow(session, flushDriveImmediately: true)
        }
    }

    // MARK: - NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarToggle, .bookmark, .flexibleSpace, .toolMode, .flexibleSpace, .pageIndicator, .zoomControls, .paperMode, .syncStatus, .diagnostics]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarToggle, .bookmark, .flexibleSpace, .toolMode, .flexibleSpace, .pageIndicator, .zoomControls, .paperMode, .syncStatus, .diagnostics]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier {
        case .sidebarToggle:
            sidebarToggleBtn.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Sidebar") ?? NSImage()
            sidebarToggleBtn.bezelStyle = .texturedRounded
            sidebarToggleBtn.target = self
            sidebarToggleBtn.action = #selector(toggleSidebarAction)
            sidebarToggleBtn.toolTip = "Toggle Outline / Search Sidebar (⌘⌥S)"
            item.view = sidebarToggleBtn
            item.label = "Sidebar"

        case .toolMode:
            modeSegment.segmentCount = 3
            modeSegment.trackingMode = .selectOne
            modeSegment.setLabel("Read", forSegment: 0)
            modeSegment.setLabel("Highlight", forSegment: 1)
            modeSegment.setLabel("Text", forSegment: 2)
            modeSegment.setImage(NSImage(systemSymbolName: "book", accessibilityDescription: "Read"), forSegment: 0)
            modeSegment.setImage(NSImage(systemSymbolName: "highlighter", accessibilityDescription: "Highlight"), forSegment: 1)
            modeSegment.setImage(NSImage(systemSymbolName: "textbox", accessibilityDescription: "Text"), forSegment: 2)
            modeSegment.setWidth(76, forSegment: 0)
            modeSegment.setWidth(94, forSegment: 1)
            modeSegment.setWidth(72, forSegment: 2)
            modeSegment.selectedSegment = canvasView.toolMode.rawValue
            modeSegment.target = self
            modeSegment.action = #selector(modeSegmentChanged)
            item.view = modeSegment
            item.label = "Mode"

        case .bookmark:
            bookmarkButton.bezelStyle = .texturedRounded
            bookmarkButton.image = Self.iconBookmark
            bookmarkButton.toolTip = "Toggle Bookmark (⌘D)"
            bookmarkButton.target = self
            bookmarkButton.action = #selector(toggleBookmarkAction)
            item.view = bookmarkButton
            item.label = "Bookmark"

        case .zoomControls:
            zoomSegment.segmentCount = 3
            zoomSegment.trackingMode = .momentary
            zoomSegment.setImage(NSImage(systemSymbolName: "minus.magnifyingglass", accessibilityDescription: "Zoom Out"), forSegment: 0)
            zoomSegment.setImage(NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Fit"), forSegment: 1)
            zoomSegment.setImage(NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: "Zoom In"), forSegment: 2)
            zoomSegment.target = self
            zoomSegment.action = #selector(zoomSegmentClicked(_:))
            item.view = zoomSegment
            item.label = "Zoom"

        case .paperMode:
            paperModeButton.bezelStyle = .texturedRounded
            paperModeButton.target = self
            paperModeButton.action = #selector(showPaperModeMenu(_:))
            updatePaperModeButtonIcon()
            item.view = paperModeButton
            item.label = "Paper"

        case .pageIndicator:
            pageField.alignment = .center
            pageField.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            pageField.bezelStyle = .roundedBezel
            pageField.frame = NSRect(x: 0, y: 0, width: 106, height: 24)
            pageField.target = self
            pageField.action = #selector(pageFieldSubmitted)
            item.view = pageField
            item.label = "Page"

        case .syncStatus:
            syncButton.bezelStyle = .texturedRounded
            syncButton.image = Self.iconSyncOff
            syncButton.imagePosition = .imageOnly
            syncButton.target = self
            syncButton.action = #selector(syncNowAction)
            item.view = syncButton
            item.label = "Sync"

        case .diagnostics:
            let img = NSImage(systemSymbolName: "gauge.with.dots.needle.bottom.50percent", accessibilityDescription: "Self-Test") ?? NSImage()
            let btn = NSButton(image: img, target: self, action: #selector(openDiagnosticsAction))
            btn.bezelStyle = .texturedRounded
            btn.toolTip = "Performance & Battery Self-Test (⌘⌥B)"
            item.view = btn
            item.label = "Self-Test"

        default:
            return nil
        }
        return item
    }
}
