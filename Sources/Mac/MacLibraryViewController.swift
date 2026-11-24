import AppKit
import Combine

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

/// Pure AppKit embeddable 2-pane Library view controller mounted inside Tab 0 of `MacWorkspaceWindowController`.
@MainActor
final class MacLibraryViewController: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {

    let vault: VaultManager
    let syncManager: DriveSyncManager
    var onOpenPDF: ((PDFItem) -> Void)?
    var onOpenSyncSettings: (() -> Void)?

    private let splitView = NSSplitView()
    private let sidebarScroll = NSScrollView()
    private let sidebarTable = NSTableView()

    private let headerBar = NSView()
    private let vaultNameLabel = NSTextField(labelWithString: "No Vault Selected")
    private let chooseVaultBtn = NSButton(title: "Choose Vault…", target: nil, action: nil)
    private let syncNowBtn = NSButton(title: "Sync Drive", target: nil, action: nil)
    private let searchField = NSSearchField()

    private let docScroll = NSScrollView()
    private let docTable = NSTableView()
    private let emptyStack = NSStackView()
    private let emptyTitle = NSTextField(labelWithString: "Connect Your Obsidian Vault")
    private let emptySub = NSTextField(labelWithString: "Choose your vault folder to browse PDFs, view iPad notes, and sync with Google Drive.")
    private let emptyChooseBtn = NSButton(title: "Choose Vault Folder…", target: nil, action: nil)
    private let statusFooter = NSTextField(labelWithString: "")

    private var sidebarEntries: [MacLibrarySidebarEntry] = []
    private var selectedSidebarIndex: Int = 1
    private var filteredItems: [PDFItem] = []
    private var isActiveTab = true
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
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
        self.view = root
        setupUI(in: root)
        bindPublishers()
        rebuildSidebarAndList()
    }

    private func setupUI(in root: NSView) {
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(splitView)

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: root.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        ])

        // Left Pane: Source List Sidebar
        let leftPane = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 640))
        leftPane.wantsLayer = true
        leftPane.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let sCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        sCol.resizingMask = .autoresizingMask
        sidebarTable.addTableColumn(sCol)
        sidebarTable.headerView = nil
        sidebarTable.style = .sourceList
        sidebarTable.rowHeight = 26
        sidebarTable.dataSource = self
        sidebarTable.delegate = self

        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        sidebarScroll.documentView = sidebarTable
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.drawsBackground = false
        leftPane.addSubview(sidebarScroll)

        NSLayoutConstraint.activate([
            leftPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 195),
            leftPane.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
            sidebarScroll.topAnchor.constraint(equalTo: leftPane.topAnchor, constant: 6),
            sidebarScroll.bottomAnchor.constraint(equalTo: leftPane.bottomAnchor),
            sidebarScroll.leadingAnchor.constraint(equalTo: leftPane.leadingAnchor),
            sidebarScroll.trailingAnchor.constraint(equalTo: leftPane.trailingAnchor)
        ])

        // Right Pane: Header Bar (Vault + Search) + Document List + Status Footer
        let rightPane = NSView(frame: NSRect(x: 0, y: 0, width: 740, height: 640))

        headerBar.translatesAutoresizingMaskIntoConstraints = false
        rightPane.addSubview(headerBar)

        vaultNameLabel.translatesAutoresizingMaskIntoConstraints = false
        vaultNameLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        vaultNameLabel.textColor = .labelColor
        vaultNameLabel.lineBreakMode = .byTruncatingTail
        vaultNameLabel.stringValue = vault.vaultURL?.lastPathComponent ?? "No Vault Selected"

        chooseVaultBtn.translatesAutoresizingMaskIntoConstraints = false
        chooseVaultBtn.bezelStyle = .rounded
        chooseVaultBtn.controlSize = .small
        chooseVaultBtn.target = self
        chooseVaultBtn.action = #selector(chooseVaultFolder)

        syncNowBtn.translatesAutoresizingMaskIntoConstraints = false
        syncNowBtn.bezelStyle = .rounded
        syncNowBtn.controlSize = .small
        syncNowBtn.target = self
        syncNowBtn.action = #selector(handleSyncButton)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search PDFs…"
        searchField.controlSize = .regular
        searchField.delegate = self

        let headerSep = NSBox()
        headerSep.boxType = .separator
        headerSep.translatesAutoresizingMaskIntoConstraints = false

        headerBar.addSubview(vaultNameLabel)
        headerBar.addSubview(chooseVaultBtn)
        headerBar.addSubview(syncNowBtn)
        headerBar.addSubview(searchField)
        headerBar.addSubview(headerSep)

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
        ctxMenu.addItem(withTitle: "Open in Tab", action: #selector(ctxOpenPDF), keyEquivalent: "")
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
        rightPane.addSubview(docScroll)

        let footerSep = NSBox()
        footerSep.boxType = .separator
        footerSep.translatesAutoresizingMaskIntoConstraints = false
        rightPane.addSubview(footerSep)

        statusFooter.translatesAutoresizingMaskIntoConstraints = false
        statusFooter.font = NSFont.systemFont(ofSize: 11.5)
        statusFooter.textColor = .secondaryLabelColor
        statusFooter.lineBreakMode = .byTruncatingTail
        rightPane.addSubview(statusFooter)

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
        rightPane.addSubview(emptyStack)

        NSLayoutConstraint.activate([
            headerBar.topAnchor.constraint(equalTo: rightPane.topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            headerBar.heightAnchor.constraint(equalToConstant: 44),

            vaultNameLabel.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 14),
            vaultNameLabel.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            chooseVaultBtn.leadingAnchor.constraint(equalTo: vaultNameLabel.trailingAnchor, constant: 10),
            chooseVaultBtn.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            syncNowBtn.leadingAnchor.constraint(equalTo: chooseVaultBtn.trailingAnchor, constant: 6),
            syncNowBtn.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            searchField.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -14),
            searchField.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 230),
            searchField.leadingAnchor.constraint(greaterThanOrEqualTo: syncNowBtn.trailingAnchor, constant: 12),

            headerSep.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor),
            headerSep.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor),
            headerSep.bottomAnchor.constraint(equalTo: headerBar.bottomAnchor),

            docScroll.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            docScroll.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            docScroll.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            docScroll.bottomAnchor.constraint(equalTo: footerSep.topAnchor),

            footerSep.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            footerSep.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            footerSep.bottomAnchor.constraint(equalTo: statusFooter.topAnchor, constant: -4),

            statusFooter.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor, constant: 14),
            statusFooter.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor, constant: -14),
            statusFooter.bottomAnchor.constraint(equalTo: rightPane.bottomAnchor, constant: -5),

            emptyStack.centerXAnchor.constraint(equalTo: docScroll.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: docScroll.centerYAnchor)
        ])

        splitView.addArrangedSubview(leftPane)
        splitView.addArrangedSubview(rightPane)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
    }

    func setTabActive(_ active: Bool) {
        isActiveTab = active
        if active && needsReloadWhenShown {
            needsReloadWhenShown = false
            rebuildSidebarAndList()
        }
    }

    func focusSearchField() {
        view.window?.makeFirstResponder(searchField)
    }

    private func bindPublishers() {
        vault.$pdfs
            .combineLatest(vault.$allFolders)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                guard let self else { return }
                if self.isActiveTab {
                    self.rebuildSidebarAndList()
                } else {
                    self.needsReloadWhenShown = true
                }
            }
            .store(in: &cancellables)

        vault.$vaultURL
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                self?.vaultNameLabel.stringValue = url?.lastPathComponent ?? "No Vault Selected"
            }
            .store(in: &cancellables)

        syncManager.$statusText
            .combineLatest(syncManager.$syncProgressText)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status, progress in
                self?.updateFooterAndSyncUI(status: status, progress: progress)
            }
            .store(in: &cancellables)
    }

    private func updateFooterAndSyncUI(status: String, progress: String) {
        let countLabel = "\(filteredItems.count) document\(filteredItems.count == 1 ? "" : "s")"
        let syncPart = progress.isEmpty ? "Drive: \(status)" : progress
        statusFooter.stringValue = "\(countLabel)  ·  \(syncPart)"
        syncNowBtn.title = syncManager.config.isConnected ? "Sync Drive" : "Connect Drive…"
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
        let q = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
            emptySub.stringValue = "No PDFs matching \"\(searchField.stringValue)\"."
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

    // MARK: - NSTableViewDataSource & Delegate

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
