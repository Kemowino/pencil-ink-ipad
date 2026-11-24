import AppKit
import UniformTypeIdentifiers

@main
@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let vault = VaultManager()
    let syncManager = DriveSyncManager()

    private var libraryController: MacLibraryWindowController?
    private var syncWindowController: MacDriveSyncWindowController?
    private var diagnosticsController: MacDiagnosticsWindowController?
    private var startupSyncTimer: DispatchSourceTimer?
    private var openDocControllers: [String: MacPDFWindowController] = [:]

    static func main() {
        let app = NSApplication.shared
        let delegate = MacAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent macOS VisionKit Live Text background OCR/GPU scans on every PDF page jump!
        UserDefaults.standard.register(defaults: [
            "AppleLiveTextEnabled": false
        ])
        UserDefaults.standard.set(false, forKey: "AppleLiveTextEnabled")
        NSWindow.allowsAutomaticWindowTabbing = true
        syncManager.isSmartSyncEnabled = { MacPreferences.shared.syncMode == .smart }
        buildMainMenu()
        showLibraryWindow()

        // Delay initial background vault sync by 6 seconds so launch stays cool & instant!
        if syncManager.config.isConnected && vault.vaultURL != nil && MacPreferences.shared.syncMode == .smart {
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now() + .seconds(6), leeway: .seconds(2))
            t.setEventHandler { [weak self] in
                guard let self else { return }
                self.startupSyncTimer?.cancel()
                self.startupSyncTimer = nil
                guard self.syncManager.config.isConnected, self.vault.vaultURL != nil else { return }
                Task { _ = await self.syncManager.syncVault(vault: self.vault, force: false) }
            }
            startupSyncTimer = t
            t.resume()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showLibraryWindow()
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension.lowercased() == "pdf" {
            openPDF(at: url, relativePath: vault.relativePath(for: url))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        for wc in openDocControllers.values {
            wc.commitActiveTextBox()
            wc.saveNow(flushDriveImmediately: false)
        }
    }

    // MARK: - Window & Tab Orchestration

    @objc func showLibraryWindow() {
        if let existing = libraryController {
            existing.refreshIfPendingOnShow()
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let lib = MacLibraryWindowController(vault: vault, syncManager: syncManager)
        lib.onOpenPDF = { [weak self] item in
            self?.openPDF(at: item.url, relativePath: item.relativePath)
        }
        lib.onOpenSyncSettings = { [weak self] in
            self?.showDriveSyncSettings()
        }
        lib.onOpenDiagnostics = { [weak self] in
            self?.showDiagnosticsWindow()
        }
        libraryController = lib
        lib.showWindow(nil)
        lib.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openPDF(at url: URL, relativePath: String, tabHost: MacPDFWindowController? = nil) {
        let key = url.standardizedFileURL.path
        if let existing = openDocControllers[key] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let wc = MacPDFWindowController(pdfURL: url, relativePath: relativePath, syncManager: syncManager)
        wc.onRequestNewTab = { [weak self] _ in
            self?.showLibraryWindow()
        }
        wc.onRequestOpenSyncSettings = { [weak self] in
            self?.showDriveSyncSettings()
        }
        wc.onRequestOpenDiagnostics = { [weak self] in
            self?.showDiagnosticsWindow()
        }
        wc.onWindowClosed = { [weak self] closed in
            self?.openDocControllers.removeValue(forKey: closed.pdfURL.standardizedFileURL.path)
        }
        openDocControllers[key] = wc

        // Native macOS window tabbing: attach cleanly as a tab on the frontmost reader window!
        let hostWindow = tabHost?.window ?? activeReaderController()?.window
        if let host = hostWindow, let newWin = wc.window {
            host.addTabbedWindow(newWin, ordered: .above)
            newWin.makeKeyAndOrderFront(nil)
        } else {
            wc.window?.center()
            wc.showWindow(nil)
            wc.window?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func activeReaderController() -> MacPDFWindowController? {
        if let keyWin = NSApp.keyWindow, let wc = keyWin.windowController as? MacPDFWindowController {
            return wc
        }
        return openDocControllers.values.first
    }

    @objc func openPDFPanelAction() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            for url in panel.urls {
                openPDF(at: url, relativePath: vault.relativePath(for: url))
            }
        }
    }

    @objc func chooseVaultAction() {
        showLibraryWindow()
        libraryController?.chooseVaultFolder()
    }

    @objc func showDriveSyncSettings() {
        if let existing = syncWindowController {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let wc = MacDriveSyncWindowController(syncManager: syncManager, vault: vault)
        wc.onWindowClosed = { [weak self] in
            self?.syncWindowController = nil
        }
        syncWindowController = wc
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showDiagnosticsWindow() {
        if let existing = diagnosticsController {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let dc = MacDiagnosticsWindowController()
        dc.activeReaderProvider = { [weak self] in
            self?.activeReaderController()
        }
        dc.onWindowClosed = { [weak self] in
            self?.diagnosticsController = nil
        }
        diagnosticsController = dc
        dc.showWindow(nil)
        dc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Menu Bar Actions Forwarded to Active Reader Window

    @objc private func menuUndo() {
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView {
            tv.undoManager?.undo()
            return
        }
        activeReaderController()?.performDocumentUndo()
    }

    @objc private func menuRedo() {
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView {
            tv.undoManager?.redo()
            return
        }
        activeReaderController()?.performDocumentRedo()
    }

    @objc private func menuExportAnnotatedPDF() {
        activeReaderController()?.exportAnnotatedPDFAction()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let reader = activeReaderController()
        switch menuItem.action {
        case #selector(menuUndo):
            if let tv = NSApp.keyWindow?.firstResponder as? NSTextView {
                return tv.undoManager?.canUndo ?? false
            }
            return reader?.canUndoDocument ?? false
        case #selector(menuRedo):
            if let tv = NSApp.keyWindow?.firstResponder as? NSTextView {
                return tv.undoManager?.canRedo ?? false
            }
            return reader?.canRedoDocument ?? false
        case #selector(menuHighlightSelection):
            return reader?.hasTextSelection ?? false
        case #selector(menuExportAnnotatedPDF), #selector(menuToggleSidebar), #selector(menuFind),
             #selector(menuModeRead), #selector(menuModeHighlight), #selector(menuModeTextBox),
             #selector(menuToggleBookmark), #selector(menuZoomIn), #selector(menuZoomOut), #selector(menuZoomFit), #selector(menuToggleTwoUp):
            return reader != nil
        case #selector(menuToggleHighQualityImages):
            menuItem.state = MacPreferences.shared.highQualityImages ? .on : .off
            return true
        default:
            return true
        }
    }

    @objc private func menuToggleSidebar() { activeReaderController()?.toggleSidebarAction() }
    @objc private func menuFind() { activeReaderController()?.focusSearchAction() }
    @objc private func menuHighlightSelection() { activeReaderController()?.highlightSelectionAction() }
    @objc private func menuModeRead() { activeReaderController()?.setToolMode(.read) }
    @objc private func menuModeHighlight() { activeReaderController()?.setToolMode(.highlighter) }
    @objc private func menuModeTextBox() { activeReaderController()?.setToolMode(.textBox) }
    @objc private func menuToggleBookmark() { activeReaderController()?.toggleBookmarkAction() }
    @objc private func menuZoomIn() { activeReaderController()?.zoomInAction() }
    @objc private func menuZoomOut() { activeReaderController()?.zoomOutAction() }
    @objc private func menuZoomFit() { activeReaderController()?.zoomToFitAction() }
    @objc private func menuToggleTwoUp() { activeReaderController()?.toggleTwoUpAction() }
    @objc private func menuToggleHighQualityImages() {
        MacPreferences.shared.highQualityImages.toggle()
    }
    @objc private func menuSyncNow() {
        if let active = activeReaderController() {
            active.syncNowAction()
        } else if syncManager.config.isConnected {
            Task { _ = await syncManager.syncVault(vault: vault, force: true) }
        } else {
            showDriveSyncSettings()
        }
    }

    // MARK: - Pure AppKit Main Menu Bar

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        // App Menu
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Pencil Ink", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Google Drive Sync & Device Key…", action: #selector(showDriveSyncSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Pencil Ink", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Pencil Ink", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // File Menu
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Tab (Library)", action: #selector(showLibraryWindow), keyEquivalent: "t")
        fileMenu.addItem(withTitle: "Library Window", action: #selector(showLibraryWindow), keyEquivalent: "l")
        fileMenu.addItem(withTitle: "Choose Vault Folder…", action: #selector(chooseVaultAction), keyEquivalent: "O")
        fileMenu.addItem(withTitle: "Open PDF…", action: #selector(openPDFPanelAction), keyEquivalent: "o")
        let expItem = NSMenuItem(title: "Export Annotated PDF…", action: #selector(menuExportAnnotatedPDF), keyEquivalent: "E")
        expItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(expItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Tab / Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        // Edit Menu
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: #selector(menuUndo), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: #selector(menuRedo), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Find in PDF…", action: #selector(menuFind), keyEquivalent: "f")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        // Tools Menu
        let toolsItem = NSMenuItem()
        let toolsMenu = NSMenu(title: "Tools")
        toolsMenu.addItem(withTitle: "Read Mode", action: #selector(menuModeRead), keyEquivalent: "1")
        toolsMenu.addItem(withTitle: "Highlighter Mode", action: #selector(menuModeHighlight), keyEquivalent: "2")
        toolsMenu.addItem(withTitle: "Text Box Mode", action: #selector(menuModeTextBox), keyEquivalent: "3")
        toolsMenu.addItem(.separator())
        let hlSel = NSMenuItem(title: "Highlight Selected Text", action: #selector(menuHighlightSelection), keyEquivalent: "H")
        hlSel.keyEquivalentModifierMask = [.command, .shift]
        toolsMenu.addItem(hlSel)
        toolsMenu.addItem(withTitle: "Toggle Page Bookmark", action: #selector(menuToggleBookmark), keyEquivalent: "d")
        toolsMenu.addItem(.separator())
        let diagItem = NSMenuItem(title: "Performance & Battery Self-Test…", action: #selector(showDiagnosticsWindow), keyEquivalent: "b")
        diagItem.keyEquivalentModifierMask = [.command, .option]
        toolsMenu.addItem(diagItem)
        toolsItem.submenu = toolsMenu
        mainMenu.addItem(toolsItem)

        // View Menu
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let sideItem = NSMenuItem(title: "Toggle Sidebar", action: #selector(menuToggleSidebar), keyEquivalent: "s")
        sideItem.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(sideItem)
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(menuZoomIn), keyEquivalent: "=")
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(menuZoomOut), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Fit to Window", action: #selector(menuZoomFit), keyEquivalent: "0")
        let twoUpItem = NSMenuItem(title: "Toggle Two-Page Spread", action: #selector(menuToggleTwoUp), keyEquivalent: "2")
        twoUpItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(twoUpItem)

        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "High-Quality Image Resampling", action: #selector(menuToggleHighQualityImages), keyEquivalent: "")
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        // Sync Menu
        let syncItem = NSMenuItem()
        let syncMenu = NSMenu(title: "Sync")
        let syncNow = NSMenuItem(title: "Sync Now", action: #selector(menuSyncNow), keyEquivalent: "S")
        syncNow.keyEquivalentModifierMask = [.command, .shift]
        syncMenu.addItem(syncNow)
        syncMenu.addItem(withTitle: "Google Drive Settings…", action: #selector(showDriveSyncSettings), keyEquivalent: "")
        syncItem.submenu = syncMenu
        mainMenu.addItem(syncItem)

        // Window Menu (Enables Native macOS Tab Bar & Window Management!)
        let winItem = NSMenuItem()
        let winMenu = NSMenu(title: "Window")
        winMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        winMenu.addItem(.separator())
        winMenu.addItem(withTitle: "Show Tab Bar", action: #selector(NSWindow.toggleTabBar(_:)), keyEquivalent: "")
        winMenu.addItem(withTitle: "Merge All Windows", action: #selector(NSWindow.mergeAllWindows(_:)), keyEquivalent: "")
        winItem.submenu = winMenu
        mainMenu.addItem(winItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = winMenu
    }
}
