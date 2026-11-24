import AppKit
import Combine

private extension NSToolbarItem.Identifier {
    static let libChooseVault = NSToolbarItem.Identifier("pencilink.lib.chooseVault")
    static let libSync = NSToolbarItem.Identifier("pencilink.lib.sync")
    static let libDiagnostics = NSToolbarItem.Identifier("pencilink.lib.diagnostics")
    static let libSearch = NSToolbarItem.Identifier("pencilink.lib.search")
}

private enum MacLibrarySidebarEntry {
    case header(String)
    case allPDFs
    case recent
    case favorites
    case annotated
    case folder(FolderItem)
}

/// Spacious native macOS document row with cached PDF cover preview thumbnail, title, folder/date subtitle, & Ink badge.
private final class MacDocumentRowCell: NSTableCellView {
    let thumbBox = NSView()
    let thumbImageView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let subtitleLabel = NSTextField(labelWithString: "")
    let inkBadge = NSTextField(labelWithString: "Annotated")
    let starImageView = NSImageView()
    var representedItemID: String = ""

    private static let titleFont = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
    private static let subFont = NSFont.systemFont(ofSize: 11.5, weight: .regular)
    private static let badgeFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
    private static let starIcon = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Favorite")
    private static let docPlaceholder = NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: "PDF")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        thumbBox.translatesAutoresizingMaskIntoConstraints = false
        thumbBox.wantsLayer = true
        thumbBox.layer?.cornerRadius = 4
        thumbBox.layer?.masksToBounds = true
        thumbBox.layer?.borderWidth = 0.6
        thumbBox.layer?.borderColor = NSColor.separatorColor.cgColor
        thumbBox.layer?.backgroundColor = NSColor.white.cgColor
        addSubview(thumbBox)

        thumbImageView.translatesAutoresizingMaskIntoConstraints = false
        thumbImageView.imageScaling = .scaleProportionallyUpOrDown
        thumbBox.addSubview(thumbImageView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = Self.titleFont
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = Self.subFont
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        addSubview(subtitleLabel)

        inkBadge.translatesAutoresizingMaskIntoConstraints = false
        inkBadge.font = Self.badgeFont
        inkBadge.textColor = .controlAccentColor
        inkBadge.alignment = .center
        inkBadge.wantsLayer = true
        inkBadge.layer?.cornerRadius = 8
        inkBadge.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.13).cgColor
        addSubview(inkBadge)

        starImageView.translatesAutoresizingMaskIntoConstraints = false
        starImageView.image = Self.starIcon
        starImageView.contentTintColor = .systemOrange
        addSubview(starImageView)

        NSLayoutConstraint.activate([
            thumbBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            thumbBox.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbBox.widthAnchor.constraint(equalToConstant: 34),
            thumbBox.heightAnchor.constraint(equalToConstant: 44),

            thumbImageView.topAnchor.constraint(equalTo: thumbBox.topAnchor),
            thumbImageView.bottomAnchor.constraint(equalTo: thumbBox.bottomAnchor),
            thumbImageView.leadingAnchor.constraint(equalTo: thumbBox.leadingAnchor),
            thumbImageView.trailingAnchor.constraint(equalTo: thumbBox.trailingAnchor),

            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: thumbBox.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: starImageView.leadingAnchor, constant: -8),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: inkBadge.leadingAnchor, constant: -10),

            inkBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            inkBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            inkBadge.widthAnchor.constraint(equalToConstant: 68),
            inkBadge.heightAnchor.constraint(equalToConstant: 18),

            starImageView.trailingAnchor.constraint(equalTo: inkBadge.leadingAnchor, constant: -8),
            starImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            starImageView.widthAnchor.constraint(equalToConstant: 13),
            starImageView.heightAnchor.constraint(equalToConstant: 13)
        ])
    }

    func configure(item: PDFItem, isFavorite: Bool, dateString: String, vault: VaultManager) {
        representedItemID = item.id
        titleLabel.stringValue = item.name
        let folderText = item.relativeFolder.isEmpty ? "Vault Root" : item.relativeFolder
        subtitleLabel.stringValue = "\(folderText)  ·  \(dateString)"
        inkBadge.isHidden = !item.hasInk
        starImageView.isHidden = !isFavorite

        if item.isHobonichi {
            let pal = HobonichiEngine.palette(for: item.name, customID: vault.coverColors[item.relativePath])
            thumbBox.layer?.backgroundColor = pal.bgColor.cgColor
            thumbImageView.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Journal")
            thumbImageView.contentTintColor = .white
            thumbImageView.imageScaling = .scaleNone
            return
        }

        thumbBox.layer?.backgroundColor = NSColor.white.cgColor
        thumbImageView.contentTintColor = .tertiaryLabelColor
        if let cached = vault.cachedCoverThumb(for: item) {
            thumbImageView.imageScaling = .scaleProportionallyUpOrDown
            thumbImageView.image = cached
        } else {
            thumbImageView.imageScaling = .scaleNone
            thumbImageView.image = Self.docPlaceholder
            let expectedID = item.id
            vault.loadCoverThumb(for: item) { [weak self] img in
                guard let self, self.representedItemID == expectedID, let img else { return }
                self.thumbImageView.imageScaling = .scaleProportionallyUpOrDown
                self.thumbImageView.image = img
            }
        }
    }
}

/// Pure AppKit native macOS 2-pane Library & Vault Browser window:
/// - Native Unified `NSToolbar` + `NSSearchToolbarItem`
/// - Native macOS Source List sidebar (Smart filters + Vault Folders)
/// - Spacious 56 pt document rows with cached PDF cover thumbnails
@MainActor
final class MacLibraryWindowController: NSWindowController,
    NSToolbarDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {

    let vault: VaultManager
    let syncManager: DriveSyncManager
    var onOpenPDF: ((PDFItem) -> Void)?
    var onOpenSyncSettings: (() -> Void)?
    var onOpenDiagnostics: (() -> Void)?

    private let splitVC = NSSplitViewController()
    private let sidebarScroll = NSScrollView()
    private let sidebarTable = NSTableView()
    private let docScroll = NSScrollView()
    private let docTable = NSTableView()
    private let emptyStack = NSStackView()
    private let emptyTitle = NSTextField(labelWithString: "Connect Your Obsidian Vault")
    private let emptySub = NSTextField(labelWithString: "Choose your vault folder to browse PDFs, view iPad notes, and sync with Google Drive.")
    private let emptyChooseBtn = NSButton(title: "Choose Vault Folder…", target: nil, action: nil)
    private let statusFooter = NSTextField(labelWithString: "")

    private let syncToolbarBtn = NSButton()
    private let searchToolbarItem = NSSearchToolbarItem(itemIdentifier: .libSearch)

    private var sidebarEntries: [MacLibrarySidebarEntry] = []
    private var selectedSidebarIndex: Int = 1 // "All Documents"
    private var filteredItems: [PDFItem] = []
    private var needsReloadWhenShown = false
    private var searchDebounce: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df
    }()

    init(vault: VaultManager, syncManager: DriveSyncManager) {
        self.vault = vault
        self.syncManager = syncManager
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "Pencil Ink"
        win.subtitle = vault.vaultURL?.lastPathComponent ?? "Library"
        win.minSize = NSSize(width: 660, height: 420)
        win.toolbarStyle = .unified
        win.center()
        super.init(window: win)

        setupToolbar()
        setupSplitView()
        bindPublishers()
        rebuildSidebarAndList()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: NSToolbar.Identifier("PencilInkMacLibraryToolbar"))
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
    }

    private func setupSplitView() {
        // Left Pane: Native macOS Source List Sidebar
        let sidebarVC = NSViewController()
        let sidebarContainer = NSView(frame: NSRect(x: 0, y: 0, width: 210, height: 540))

        let sCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        sCol.resizingMask = .autoresizingMask
        sidebarTable.addTableColumn(sCol)
        sidebarTable.headerView = nil
        sidebarTable.style = .sourceList
        sidebarTable.selectionHighlightStyle = .sourceList
        sidebarTable.rowHeight = 26
        sidebarTable.dataSource = self
        sidebarTable.delegate = self

        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        sidebarScroll.documentView = sidebarTable
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.drawsBackground = false
        sidebarContainer.addSubview(sidebarScroll)

        NSLayoutConstraint.activate([
            sidebarScroll.topAnchor.constraint(equalTo: sidebarContainer.topAnchor),
            sidebarScroll.bottomAnchor.constraint(equalTo: sidebarContainer.bottomAnchor),
            sidebarScroll.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor),
            sidebarScroll.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
        ])
        sidebarVC.view = sidebarContainer

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 195
        sidebarItem.maximumThickness = 280
        sidebarItem.canCollapse = false
        sidebarItem.allowsFullHeightLayout = true

        // Right Pane: Rich Document List + Status Footer
        let contentVC = NSViewController()
        let contentRoot = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 540))

        let dCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("doc"))
        dCol.resizingMask = .autoresizingMask
        docTable.addTableColumn(dCol)
        docTable.headerView = nil
        docTable.style = .inset
        docTable.rowHeight = 56
        docTable.usesAlternatingRowBackgroundColors = false
        docTable.gridStyleMask = .solidHorizontalGridLineMask
        docTable.gridColor = NSColor.separatorColor.withAlphaComponent(0.35)
        docTable.dataSource = self
        docTable.delegate = self
        docTable.target = self
        docTable.doubleAction = #selector(tableDoubleClicked)

        let ctxMenu = NSMenu()
        ctxMenu.addItem(withTitle: "Open", action: #selector(ctxOpenPDF), keyEquivalent: "")
        ctxMenu.addItem(withTitle: "Toggle Favorite", action: #selector(ctxToggleFavorite), keyEquivalent: "")
        ctxMenu.addItem(withTitle: "Show in Finder", action: #selector(ctxRevealInFinder), keyEquivalent: "")
        ctxMenu.addItem(.separator())
        ctxMenu.addItem(withTitle: "Rename…", action: #selector(ctxRenamePDF), keyEquivalent: "")
        ctxMenu.addItem(withTitle: "Move to Trash", action: #selector(ctxDeletePDF), keyEquivalent: "")
        for item in ctxMenu.items { item.target = self }
        docTable.menu = ctxMenu

        docScroll.translatesAutoresizingMaskIntoConstraints = false
        docScroll.documentView = docTable
        docScroll.hasVerticalScroller = true
        docScroll.drawsBackground = true
        contentRoot.addSubview(docScroll)

        // Subtle Footer Status Bar
        let footerSep = NSBox()
        footerSep.boxType = .separator
        footerSep.translatesAutoresizingMaskIntoConstraints = false
        contentRoot.addSubview(footerSep)

        statusFooter.translatesAutoresizingMaskIntoConstraints = false
        statusFooter.font = NSFont.systemFont(ofSize: 11.5)
        statusFooter.textColor = .secondaryLabelColor
        statusFooter.lineBreakMode = .byTruncatingTail
        contentRoot.addSubview(statusFooter)

        // Empty State Stack
        emptyStack.orientation = .vertical
        emptyStack.alignment = .centerX
        emptyStack.spacing = 10
        emptyStack.translatesAutoresizingMaskIntoConstraints = false
        emptyTitle.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        emptySub.font = NSFont.systemFont(ofSize: 12.5)
        emptySub.textColor = .secondaryLabelColor
        emptySub.alignment = .center
        emptySub.maximumNumberOfLines = 2
        emptySub.preferredMaxLayoutWidth = 360
        emptyChooseBtn.bezelStyle = .rounded
        emptyChooseBtn.controlSize = .large
        emptyChooseBtn.target = self
        emptyChooseBtn.action = #selector(chooseVaultFolder)
        emptyStack.addArrangedSubview(emptyTitle)
        emptyStack.addArrangedSubview(emptySub)
        emptyStack.addArrangedSubview(emptyChooseBtn)
        contentRoot.addSubview(emptyStack)

        NSLayoutConstraint.activate([
            docScroll.topAnchor.constraint(equalTo: contentRoot.safeAreaLayoutGuide.topAnchor),
            docScroll.leadingAnchor.constraint(equalTo: contentRoot.leadingAnchor),
            docScroll.trailingAnchor.constraint(equalTo: contentRoot.trailingAnchor),
            docScroll.bottomAnchor.constraint(equalTo: footerSep.topAnchor),

            footerSep.leadingAnchor.constraint(equalTo: contentRoot.leadingAnchor),
            footerSep.trailingAnchor.constraint(equalTo: contentRoot.trailingAnchor),
            footerSep.bottomAnchor.constraint(equalTo: statusFooter.topAnchor, constant: -4),

            statusFooter.leadingAnchor.constraint(equalTo: contentRoot.leadingAnchor, constant: 14),
            statusFooter.trailingAnchor.constraint(equalTo: contentRoot.trailingAnchor, constant: -14),
            statusFooter.bottomAnchor.constraint(equalTo: contentRoot.bottomAnchor, constant: -5),

            emptyStack.centerXAnchor.constraint(equalTo: docScroll.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: docScroll.centerYAnchor)
        ])
        contentVC.view = contentRoot

        let mainItem = NSSplitViewItem(viewController: contentVC)
        splitVC.addSplitViewItem(sidebarItem)
        splitVC.addSplitViewItem(mainItem)
        window?.contentViewController = splitVC
    }

    func refreshIfPendingOnShow() {
        if needsReloadWhenShown {
            needsReloadWhenShown = false
            rebuildSidebarAndList()
        }
    }

    private func bindPublishers() {
        vault.$pdfs
            .combineLatest(vault.$allFolders)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                guard let self else { return }
                if self.window?.isVisible == true {
                    self.rebuildSidebarAndList()
                } else {
                    self.needsReloadWhenShown = true
                }
            }
            .store(in: &cancellables)

        vault.$vaultURL
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                self?.window?.subtitle = url?.lastPathComponent ?? "No Vault Selected"
            }
            .store(in: &cancellables)

        syncManager.$statusText
            .combineLatest(syncManager.$syncProgressText)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status, progress in
                guard let self else { return }
                self.updateFooterAndSyncUI(status: status, progress: progress)
            }
            .store(in: &cancellables)
    }

    private func updateFooterAndSyncUI(status: String, progress: String) {
        let countLabel = "\(filteredItems.count) document\(filteredItems.count == 1 ? "" : "s")"
        let syncPart = progress.isEmpty ? "Drive: \(status)" : progress
        statusFooter.stringValue = "\(countLabel)  ·  \(syncPart)"

        let imgName: String
        switch syncManager.visualState {
        case .ok: imgName = "checkmark.icloud"
        case .syncing: imgName = "arrow.triangle.2.circlepath.icloud"
        case .error: imgName = "exclamationmark.icloud"
        case .disconnected: imgName = "icloud.slash"
        }
        syncToolbarBtn.image = NSImage(systemSymbolName: imgName, accessibilityDescription: status)
        syncToolbarBtn.toolTip = syncManager.config.isConnected
            ? "Sync Google Drive (\(status))"
            : "Connect Google Drive…"
    }

    private func rebuildSidebarAndList() {
        var entries: [MacLibrarySidebarEntry] = [
            .header("LIBRARY"),
            .allPDFs,
            .recent,
            .favorites,
            .annotated
        ]
        if !vault.allFolders.isEmpty {
            entries.append(.header("FOLDERS"))
            for folder in vault.allFolders {
                entries.append(.folder(folder))
            }
        }
        sidebarEntries = entries
        if selectedSidebarIndex < 0 || selectedSidebarIndex >= sidebarEntries.count {
            selectedSidebarIndex = 1
        }
        sidebarTable.reloadData()
        sidebarTable.selectRowIndexes(IndexSet(integer: selectedSidebarIndex), byExtendingSelection: false)
        rebuildFilteredList()
    }

    private func rebuildFilteredList() {
        let q = searchToolbarItem.searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base: [PDFItem]
        let entry = (selectedSidebarIndex >= 0 && selectedSidebarIndex < sidebarEntries.count)
            ? sidebarEntries[selectedSidebarIndex]
            : .allPDFs

        switch entry {
        case .recent:
            let byRel = Dictionary(uniqueKeysWithValues: vault.pdfs.map { ($0.relativePath, $0) })
            base = vault.recentPaths.compactMap { byRel[$0] }
        case .favorites:
            base = vault.pdfs.filter { vault.favoritePaths.contains($0.relativePath) }
        case .annotated:
            base = vault.pdfs.filter { $0.hasInk }
        case .folder(let f):
            let prefix = f.relativePath + "/"
            base = vault.pdfs.filter { $0.relativeFolder == f.relativePath || $0.relativeFolder.hasPrefix(prefix) }
        default:
            base = vault.pdfs
        }

        if q.isEmpty {
            filteredItems = base
        } else {
            filteredItems = base.filter {
                $0.name.lowercased().contains(q) || $0.relativeFolder.lowercased().contains(q)
            }
        }

        docTable.reloadData()
        let isEmpty = filteredItems.isEmpty
        emptyStack.isHidden = !isEmpty
        emptyChooseBtn.isHidden = (vault.vaultURL != nil)

        if vault.vaultURL == nil {
            emptyTitle.stringValue = "Connect Your Obsidian Vault"
            emptySub.stringValue = "Choose your vault folder to browse PDFs, view iPad notes, and sync with Google Drive."
        } else if !q.isEmpty {
            emptyTitle.stringValue = "No Results"
            emptySub.stringValue = "No PDFs matching \"\(searchToolbarItem.searchField.stringValue)\"."
        } else {
            emptyTitle.stringValue = "No Documents Here"
            emptySub.stringValue = "Add PDFs to this folder or sync from Google Drive."
        }
        updateFooterAndSyncUI(status: syncManager.statusText, progress: syncManager.syncProgressText)
    }

    // MARK: - Actions

    @objc func chooseVaultFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Vault"
        panel.message = "Select your Obsidian Vault folder (or folder containing your PDFs)."
        if panel.runModal() == .OK, let url = panel.url {
            vault.setVaultFolder(url)
            if syncManager.config.isConnected {
                Task { _ = await syncManager.syncVault(vault: vault, force: false) }
            }
        }
    }

    @objc private func handleSyncButton() {
        if !syncManager.config.isConnected {
            onOpenSyncSettings?()
            return
        }
        Task {
            _ = await syncManager.syncVault(vault: vault, force: true)
        }
    }

    @objc private func handleDiagnosticsButton() {
        onOpenDiagnostics?()
    }

    func controlTextDidChange(_ obj: Notification) {
        searchDebounce?.cancel()
        if vault.pdfs.count < 80 {
            rebuildFilteredList()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.rebuildFilteredList()
        }
        searchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    @objc private func tableDoubleClicked() {
        let row = docTable.selectedRow
        guard row >= 0, row < filteredItems.count else { return }
        let item = filteredItems[row]
        vault.recordRecentlyOpened(item.relativePath)
        onOpenPDF?(item)
    }

    private func contextItem() -> PDFItem? {
        let row = docTable.clickedRow >= 0 ? docTable.clickedRow : docTable.selectedRow
        guard row >= 0, row < filteredItems.count else { return nil }
        return filteredItems[row]
    }

    @objc private func ctxOpenPDF() {
        guard let item = contextItem() else { return }
        vault.recordRecentlyOpened(item.relativePath)
        onOpenPDF?(item)
    }

    @objc private func ctxToggleFavorite() {
        guard let item = contextItem() else { return }
        vault.toggleFavorite(item.relativePath)
        rebuildFilteredList()
    }

    @objc private func ctxRevealInFinder() {
        guard let item = contextItem() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    @objc private func ctxRenamePDF() {
        guard let item = contextItem() else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Document"
        alert.informativeText = "Renames the PDF locally and updates its name on Google Drive."
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        tf.stringValue = item.name
        alert.accessoryView = tf
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let newName = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty, newName != item.name else { return }
            let oldRel = item.relativePath
            if let renamed = try? vault.renamePDF(item, newTitle: newName) {
                let newRel = renamed.relPath
                Task { _ = await syncManager.renameBookOnDrive(oldRelativePath: oldRel, newRelativePath: newRel) }
            }
        }
    }

    @objc private func ctxDeletePDF() {
        guard let item = contextItem() else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \"\(item.name)\"?"
        alert.informativeText = "This removes the PDF and its local annotation sidecar from your vault folder."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            try? vault.deletePDF(item)
        }
    }

    // MARK: - NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.libChooseVault, .libSync, .libDiagnostics, .flexibleSpace, .libSearch]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.libChooseVault, .libSync, .libDiagnostics, .flexibleSpace, .libSearch]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .libChooseVault:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let btn = NSButton(
                image: NSImage(systemSymbolName: "folder.badge.gearshape", accessibilityDescription: "Choose Vault") ?? NSImage(),
                target: self,
                action: #selector(chooseVaultFolder)
            )
            btn.bezelStyle = .texturedRounded
            btn.toolTip = "Choose Vault Folder…"
            item.view = btn
            item.label = "Vault"
            return item

        case .libSync:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            syncToolbarBtn.bezelStyle = .texturedRounded
            syncToolbarBtn.image = NSImage(systemSymbolName: "icloud", accessibilityDescription: "Sync")
            syncToolbarBtn.imagePosition = .imageOnly
            syncToolbarBtn.target = self
            syncToolbarBtn.action = #selector(handleSyncButton)
            item.view = syncToolbarBtn
            item.label = "Sync"
            return item

        case .libDiagnostics:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let btn = NSButton(
                image: NSImage(systemSymbolName: "gauge.with.dots.needle.bottom.50percent", accessibilityDescription: "Self-Test") ?? NSImage(),
                target: self,
                action: #selector(handleDiagnosticsButton)
            )
            btn.bezelStyle = .texturedRounded
            btn.toolTip = "Performance & Battery Self-Test (⌘⌥B)"
            item.view = btn
            item.label = "Self-Test"
            return item

        case .libSearch:
            searchToolbarItem.searchField.placeholderString = "Search PDFs…"
            searchToolbarItem.searchField.delegate = self
            return searchToolbarItem

        default:
            return nil
        }
    }

    // MARK: - NSTableViewDataSource & Delegate (Sidebar + Document List)

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === sidebarTable { return sidebarEntries.count }
        return filteredItems.count
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard tableView === sidebarTable, row < sidebarEntries.count else { return false }
        if case .header = sidebarEntries[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if tableView === sidebarTable {
            if case .header = sidebarEntries[row] { return false }
        }
        return true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTableView, tv === sidebarTable else { return }
        let row = sidebarTable.selectedRow
        if row >= 0 && row < sidebarEntries.count {
            if case .header = sidebarEntries[row] { return }
            selectedSidebarIndex = row
            rebuildFilteredList()
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === sidebarTable {
            guard row < sidebarEntries.count else { return nil }
            let entry = sidebarEntries[row]
            if case .header(let title) = entry {
                let id = NSUserInterfaceItemIdentifier("SidebarHeader")
                let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
                    let c = NSTableCellView()
                    c.identifier = id
                    let tf = NSTextField(labelWithString: "")
                    tf.translatesAutoresizingMaskIntoConstraints = false
                    tf.font = NSFont.systemFont(ofSize: 10.5, weight: .bold)
                    tf.textColor = .tertiaryLabelColor
                    c.addSubview(tf)
                    c.textField = tf
                    NSLayoutConstraint.activate([
                        tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 6),
                        tf.centerYAnchor.constraint(equalTo: c.centerYAnchor)
                    ])
                    return c
                }()
                cell.textField?.stringValue = title
                return cell
            }

            let id = NSUserInterfaceItemIdentifier("SidebarNav")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
                let c = NSTableCellView()
                c.identifier = id
                let iv = NSImageView()
                iv.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(iv)
                c.imageView = iv
                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.font = NSFont.systemFont(ofSize: 13, weight: .regular)
                tf.lineBreakMode = .byTruncatingTail
                c.addSubview(tf)
                c.textField = tf
                let cnt = NSTextField(labelWithString: "")
                cnt.translatesAutoresizingMaskIntoConstraints = false
                cnt.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
                cnt.textColor = .tertiaryLabelColor
                cnt.alignment = .right
                cnt.tag = 77
                c.addSubview(cnt)
                NSLayoutConstraint.activate([
                    iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 6),
                    iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                    iv.widthAnchor.constraint(equalToConstant: 16),
                    iv.heightAnchor.constraint(equalToConstant: 16),
                    tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 7),
                    tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                    tf.trailingAnchor.constraint(lessThanOrEqualTo: cnt.leadingAnchor, constant: -6),
                    cnt.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -8),
                    cnt.centerYAnchor.constraint(equalTo: c.centerYAnchor)
                ])
                return c
            }()

            let cntLabel = cell.viewWithTag(77) as? NSTextField
            switch entry {
            case .allPDFs:
                cell.imageView?.image = NSImage(systemSymbolName: "books.vertical", accessibilityDescription: nil)
                cell.imageView?.contentTintColor = .controlAccentColor
                cell.textField?.stringValue = "All Documents"
                cntLabel?.stringValue = "\(vault.pdfs.count)"
            case .recent:
                cell.imageView?.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
                cell.imageView?.contentTintColor = .systemBlue
                cell.textField?.stringValue = "Recent"
                cntLabel?.stringValue = "\(vault.recentPaths.count)"
            case .favorites:
                cell.imageView?.image = NSImage(systemSymbolName: "star", accessibilityDescription: nil)
                cell.imageView?.contentTintColor = .systemOrange
                cell.textField?.stringValue = "Favorites"
                cntLabel?.stringValue = "\(vault.favoritePaths.count)"
            case .annotated:
                cell.imageView?.image = NSImage(systemSymbolName: "highlighter", accessibilityDescription: nil)
                cell.imageView?.contentTintColor = .systemPurple
                cell.textField?.stringValue = "Annotated"
                cntLabel?.stringValue = "\(vault.pdfs.filter { $0.hasInk }.count)"
            case .folder(let f):
                cell.imageView?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                cell.imageView?.contentTintColor = .secondaryLabelColor
                cell.textField?.stringValue = f.name
                cntLabel?.stringValue = f.pdfCount > 0 ? "\(f.pdfCount)" : ""
            case .header:
                break
            }
            return cell
        }

        // Right Pane: Rich 56 pt Document Row
        guard row < filteredItems.count else { return nil }
        let item = filteredItems[row]
        let id = NSUserInterfaceItemIdentifier("DocRowCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? MacDocumentRowCell) ?? {
            let c = MacDocumentRowCell()
            c.identifier = id
            return c
        }()
        cell.configure(
            item: item,
            isFavorite: vault.isFavorite(item.relativePath),
            dateString: dateFormatter.string(from: item.modifiedAt),
            vault: vault
        )
        return cell
    }
}
