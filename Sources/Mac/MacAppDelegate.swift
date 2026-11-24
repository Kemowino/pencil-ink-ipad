import AppKit
import UniformTypeIdentifiers

@main
@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let vault = VaultManager()
    let syncManager = DriveSyncManager()

    private var workspaceController: MacWorkspaceWindowController?
    private var syncWindowController: MacDriveSyncWindowController?
    private var diagnosticsController: MacDiagnosticsWindowController?
    private var startupSyncTimer: DispatchSourceTimer?

    static func main() {
        let app = NSApplication.shared
        let delegate = MacAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent macOS VisionKit Live Text background OCR/GPU scans
        UserDefaults.standard.register(defaults: [
            "AppleLiveTextEnabled": false
        ])
        UserDefaults.standard.set(false, forKey: "AppleLiveTextEnabled")
        NSWindow.allowsAutomaticWindowTabbing = false
        syncManager.isSmartSyncEnabled = { MacPreferences.shared.syncMode == .smart }

        buildMainMenu()
        showWorkspaceWindow()

        // Delay initial background vault sync by 6 seconds so launch stays cool & instant
        if syncManager.config.isConnected && vault.vaultURL != nil && MacPreferences.shared.syncMode == .smart {
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now() + .seconds(3), leeway: .seconds(2))
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
        showWorkspaceWindow()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        showWorkspaceWindow()
        for url in urls where url.pathExtension.lowercased() == "pdf" {
            workspaceController?.openPDFTab(at: url, relativePath: vault.relativePath(for: url))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        workspaceController?.saveAllDirtySessionsBeforeTerminate()
    }

    // MARK: - Single-Window Workspace Orchestration

    @objc func showWorkspaceWindow() {
        if let existing = workspaceController {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let ws = MacWorkspaceWindowController(vault: vault, syncManager: syncManager)
        ws.onRequestOpenSyncSettings = { [weak self] in
            self?.showDriveSyncSettings()
        }
        ws.onRequestOpenDiagnostics = { [weak self] in
            self?.showDiagnosticsWindow()
        }
        workspaceController = ws
        ws.showWindow(nil)
        ws.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showLibraryTabAction() {
        showWorkspaceWindow()
        workspaceController?.showLibraryTab(focusSearch: false)
    }

    @objc func newTabLibraryAction() {
        showWorkspaceWindow()
        workspaceController?.showLibraryTab(focusSearch: true)
    }

    @objc func openPDFPanelAction() {
        showWorkspaceWindow()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            for url in panel.urls {
                workspaceController?.openPDFTab(at: url, relativePath: vault.relativePath(for: url))
            }
        }
    }

    @objc func chooseVaultAction() {
        showWorkspaceWindow()
        workspaceController?.chooseVaultFolder()
    }

    @objc func closeTabOrWindowAction() {
        if let keyWin = NSApp.keyWindow, keyWin !== workspaceController?.window {
            keyWin.performClose(nil)
            return
        }
        workspaceController?.closeActiveTabOrWindow()
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
        dc.activeWorkspaceProvider = { [weak self] in
            self?.workspaceController
        }
        dc.onWindowClosed = { [weak self] in
            self?.diagnosticsController = nil
        }
        diagnosticsController = dc
        dc.showWindow(nil)
        dc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Menu Bar Actions Forwarded to Active Workspace

    @objc private func menuUndo() {
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView {
            tv.undoManager?.undo()
            return
        }
        workspaceController?.performDocumentUndo()
    }

    @objc private func menuRedo() {
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView {
            tv.undoManager?.redo()
            return
        }
        workspaceController?.performDocumentRedo()
    }

    @objc private func menuExportAnnotatedPDF() {
        workspaceController?.exportAnnotatedPDFAction()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let hasReader = (workspaceController?.activeReaderSession != nil)
        switch menuItem.action {
        case #selector(menuUndo):
            if let tv = NSApp.keyWindow?.firstResponder as? NSTextView {
                return tv.undoManager?.canUndo ?? false
            }
            return workspaceController?.canUndoDocument ?? false
        case #selector(menuRedo):
            if let tv = NSApp.keyWindow?.firstResponder as? NSTextView {
                return tv.undoManager?.canRedo ?? false
            }
            return workspaceController?.canRedoDocument ?? false
        case #selector(menuHighlightSelection):
            return workspaceController?.hasTextSelection ?? false
        case #selector(menuExportAnnotatedPDF), #selector(menuToggleSidebar),
             #selector(menuModeRead), #selector(menuModeHighlight), #selector(menuModeTextBox),
             #selector(menuToggleBookmark), #selector(menuZoomIn), #selector(menuZoomOut),
             #selector(menuZoomFit), #selector(menuToggleTwoUp):
            return hasReader
        case #selector(menuToggleHighQualityImages):
            menuItem.state = MacPreferences.shared.highQualityImages ? .on : .off
            return true
        case #selector(menuPaperOriginal):
            menuItem.state = (MacPreferences.shared.paperMode == .original) ? .on : .off
            return true
        case #selector(menuPaperSepia):
            menuItem.state = (MacPreferences.shared.paperMode == .sepia) ? .on : .off
            return true
        case #selector(menuPaperDark):
            menuItem.state = (MacPreferences.shared.paperMode == .dark) ? .on : .off
            return true
        case #selector(menuLibraryGrid):
            menuItem.state = (MacPreferences.shared.libraryDisplayMode == .grid) ? .on : .off
            return true
        case #selector(menuLibraryList):
            menuItem.state = (MacPreferences.shared.libraryDisplayMode == .list) ? .on : .off
            return true
        case #selector(menuSwitchTab(_:)):
            return menuItem.tag < (workspaceController?.openTabCount ?? 0)
        case #selector(menuPrevTab), #selector(menuNextTab):
            return (workspaceController?.openTabCount ?? 0) > 1
        default:
            return true
        }
    }

    @objc private func menuToggleSidebar() { workspaceController?.toggleSidebarAction() }
    @objc private func menuFind() { workspaceController?.focusSearchAction() }
    @objc private func menuHighlightSelection() { workspaceController?.highlightSelectionAction() }
    @objc private func menuModeRead() { workspaceController?.setToolMode(.read) }
    @objc private func menuModeHighlight() { workspaceController?.setToolMode(.highlighter) }
    @objc private func menuModeTextBox() { workspaceController?.setToolMode(.textBox) }
    @objc private func menuToggleBookmark() { workspaceController?.toggleBookmarkAction() }
    @objc private func menuZoomIn() { workspaceController?.zoomInAction() }
    @objc private func menuZoomOut() { workspaceController?.zoomOutAction() }
    @objc private func menuZoomFit() { workspaceController?.zoomToFitAction() }
    @objc private func menuToggleTwoUp() { workspaceController?.toggleTwoUpAction() }
    @objc private func menuToggleHighQualityImages() { MacPreferences.shared.highQualityImages.toggle() }
    @objc private func menuPaperOriginal() { MacPreferences.shared.paperMode = .original }
    @objc private func menuPaperSepia() { MacPreferences.shared.paperMode = .sepia }
    @objc private func menuPaperDark() { MacPreferences.shared.paperMode = .dark }
    @objc private func menuLibraryGrid() { workspaceController?.setLibraryDisplayMode(.grid) }
    @objc private func menuLibraryList() { workspaceController?.setLibraryDisplayMode(.list) }
    @objc private func menuSwitchTab(_ sender: NSMenuItem) { workspaceController?.switchToTabAtIndex(sender.tag) }
    @objc private func menuPrevTab() { workspaceController?.cycleTab(delta: -1) }
    @objc private func menuNextTab() { workspaceController?.cycleTab(delta: 1) }

    @objc private func menuSyncNow() {
        workspaceController?.syncNowAction()
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
        fileMenu.addItem(withTitle: "New Tab (Search Library)", action: #selector(newTabLibraryAction), keyEquivalent: "t")
        fileMenu.addItem(withTitle: "Library Tab", action: #selector(showLibraryTabAction), keyEquivalent: "l")
        fileMenu.addItem(withTitle: "Choose Vault Folder…", action: #selector(chooseVaultAction), keyEquivalent: "O")
        fileMenu.addItem(withTitle: "Open PDF…", action: #selector(openPDFPanelAction), keyEquivalent: "o")
        let expItem = NSMenuItem(title: "Export Annotated PDF…", action: #selector(menuExportAnnotatedPDF), keyEquivalent: "E")
        expItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(expItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Tab / Window", action: #selector(closeTabOrWindowAction), keyEquivalent: "w")
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
        editMenu.addItem(withTitle: "Find…", action: #selector(menuFind), keyEquivalent: "f")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        // Tools Menu
        let toolsItem = NSMenuItem()
        let toolsMenu = NSMenu(title: "Tools")
        let rItem = NSMenuItem(title: "Read Mode", action: #selector(menuModeRead), keyEquivalent: "r")
        rItem.keyEquivalentModifierMask = [.command, .option]
        toolsMenu.addItem(rItem)
        let hItem = NSMenuItem(title: "Highlighter Mode", action: #selector(menuModeHighlight), keyEquivalent: "h")
        hItem.keyEquivalentModifierMask = [.command, .option]
        toolsMenu.addItem(hItem)
        let tItem = NSMenuItem(title: "Text Box Mode", action: #selector(menuModeTextBox), keyEquivalent: "t")
        tItem.keyEquivalentModifierMask = [.command, .option]
        toolsMenu.addItem(tItem)
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
        let pOrig = NSMenuItem(title: "Original Paper", action: #selector(menuPaperOriginal), keyEquivalent: "1")
        pOrig.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(pOrig)
        let pSepia = NSMenuItem(title: "Warm Sepia Paper", action: #selector(menuPaperSepia), keyEquivalent: "2")
        pSepia.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(pSepia)
        let pDark = NSMenuItem(title: "Dark Paper", action: #selector(menuPaperDark), keyEquivalent: "3")
        pDark.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(pDark)
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Library Cover Grid", action: #selector(menuLibraryGrid), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Library Compact List", action: #selector(menuLibraryList), keyEquivalent: "")
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

        // Window & In-App Tabs Menu (Cmd+1 Library, Cmd+2..9 PDF Tabs, Cmd+Shift+[ / ])
        let winItem = NSMenuItem()
        let winMenu = NSMenu(title: "Window")
        winMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        winMenu.addItem(.separator())
        let prevTab = NSMenuItem(title: "Previous Tab", action: #selector(menuPrevTab), keyEquivalent: "[")
        prevTab.keyEquivalentModifierMask = [.command, .shift]
        winMenu.addItem(prevTab)
        let nextTab = NSMenuItem(title: "Next Tab", action: #selector(menuNextTab), keyEquivalent: "]")
        nextTab.keyEquivalentModifierMask = [.command, .shift]
        winMenu.addItem(nextTab)
        winMenu.addItem(.separator())
        for i in 0..<9 {
            let title = (i == 0) ? "Library Tab" : "Tab \(i + 1)"
            let item = NSMenuItem(title: title, action: #selector(menuSwitchTab(_:)), keyEquivalent: "\(i + 1)")
            item.tag = i
            winMenu.addItem(item)
        }
        winItem.submenu = winMenu
        mainMenu.addItem(winItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = winMenu
    }
}
