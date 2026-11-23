import AppKit
import Combine

/// Pure AppKit Library & Vault Browser window (zero SwiftUI, instant search, native NSOpenPanel vault picker).
@MainActor
final class MacLibraryWindowController: NSWindowController,
    NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {

    let vault: VaultManager
    let syncManager: DriveSyncManager
    var onOpenPDF: ((PDFItem) -> Void)?
    var onOpenSyncSettings: (() -> Void)?

    private let filterControl = NSSegmentedControl(labels: ["All PDFs", "Recent", "Favorites", "Annotated"], trackingMode: .selectOne, target: nil, action: nil)
    private let searchField = NSSearchField()
    private let folderLabel = NSTextField(labelWithString: "No Vault Selected")
    private let chooseVaultBtn = NSButton(title: "Choose Vault…", target: nil, action: nil)
    private let syncBtn = NSButton(title: "Sync Drive", target: nil, action: nil)
    private let syncStatusLabel = NSTextField(labelWithString: "")

    private let tableScroll = NSScrollView()
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "Choose your Obsidian Vault folder to browse & read PDFs.")

    private var filteredItems: [PDFItem] = []
    private var needsReloadWhenShown = false
    private var searchDebounce: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private static let cellNameFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    private static let cellFolderFont = NSFont.systemFont(ofSize: 12)
    private static let cellInkFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    private static let cellDateFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
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
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Pencil Ink — Library"
        win.minSize = NSSize(width: 580, height: 380)
        win.center()
        super.init(window: win)
        setupUI()
        bindPublishers()
        rebuildFilteredList()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let root = window?.contentView else { return }

        // Top Bar: Vault Info + Choose Vault + Drive Sync
        folderLabel.translatesAutoresizingMaskIntoConstraints = false
        folderLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        folderLabel.lineBreakMode = .byTruncatingMiddle
        root.addSubview(folderLabel)

        chooseVaultBtn.translatesAutoresizingMaskIntoConstraints = false
        chooseVaultBtn.bezelStyle = .rounded
        chooseVaultBtn.target = self
        chooseVaultBtn.action = #selector(chooseVaultFolder)
        root.addSubview(chooseVaultBtn)

        syncBtn.translatesAutoresizingMaskIntoConstraints = false
        syncBtn.bezelStyle = .rounded
        syncBtn.target = self
        syncBtn.action = #selector(handleSyncButton)
        root.addSubview(syncBtn)

        syncStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        syncStatusLabel.font = NSFont.systemFont(ofSize: 11.5)
        syncStatusLabel.textColor = .secondaryLabelColor
        syncStatusLabel.alignment = .right
        syncStatusLabel.lineBreakMode = .byTruncatingTail
        root.addSubview(syncStatusLabel)

        // Second Bar: Filter Segments + Instant Search
        filterControl.translatesAutoresizingMaskIntoConstraints = false
        filterControl.selectedSegment = 0
        filterControl.target = self
        filterControl.action = #selector(filterChanged)
        root.addSubview(filterControl)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Filter PDFs or folders…"
        searchField.delegate = self
        root.addSubview(searchField)

        // Main Table
        let colName = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        colName.title = "Document"
        colName.width = 360
        colName.resizingMask = .autoresizingMask

        let colFolder = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
        colFolder.title = "Folder"
        colFolder.width = 180

        let colInk = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ink"))
        colInk.title = "Notes"
        colInk.width = 64

        let colDate = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        colDate.title = "Modified"
        colDate.width = 140

        tableView.addTableColumn(colName)
        tableView.addTableColumn(colFolder)
        tableView.addTableColumn(colInk)
        tableView.addTableColumn(colDate)
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 26
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(tableDoubleClicked)
        let ctxMenu = NSMenu()
        ctxMenu.addItem(withTitle: "Open", action: #selector(ctxOpenPDF), keyEquivalent: "")
        ctxMenu.addItem(withTitle: "Toggle Favorite", action: #selector(ctxToggleFavorite), keyEquivalent: "")
        ctxMenu.addItem(withTitle: "Show in Finder", action: #selector(ctxRevealInFinder), keyEquivalent: "")
        ctxMenu.addItem(.separator())
        ctxMenu.addItem(withTitle: "Rename…", action: #selector(ctxRenamePDF), keyEquivalent: "")
        ctxMenu.addItem(withTitle: "Move to Trash", action: #selector(ctxDeletePDF), keyEquivalent: "")
        for item in ctxMenu.items { item.target = self }
        tableView.menu = ctxMenu

        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .bezelBorder
        root.addSubview(tableScroll)

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = NSFont.systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        root.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            folderLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            folderLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            folderLabel.trailingAnchor.constraint(lessThanOrEqualTo: syncStatusLabel.leadingAnchor, constant: -10),

            syncStatusLabel.centerYAnchor.constraint(equalTo: folderLabel.centerYAnchor),
            syncStatusLabel.trailingAnchor.constraint(equalTo: syncBtn.leadingAnchor, constant: -10),
            syncStatusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 210),

            syncBtn.centerYAnchor.constraint(equalTo: folderLabel.centerYAnchor),
            syncBtn.trailingAnchor.constraint(equalTo: chooseVaultBtn.leadingAnchor, constant: -8),

            chooseVaultBtn.centerYAnchor.constraint(equalTo: folderLabel.centerYAnchor),
            chooseVaultBtn.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            filterControl.topAnchor.constraint(equalTo: folderLabel.bottomAnchor, constant: 12),
            filterControl.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),

            searchField.centerYAnchor.constraint(equalTo: filterControl.centerYAnchor),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            searchField.widthAnchor.constraint(equalToConstant: 240),

            tableScroll.topAnchor.constraint(equalTo: filterControl.bottomAnchor, constant: 10),
            tableScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            tableScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            tableScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),

            emptyLabel.centerXAnchor.constraint(equalTo: tableScroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: tableScroll.centerYAnchor)
        ])
    }

    func refreshIfPendingOnShow() {
        if needsReloadWhenShown {
            needsReloadWhenShown = false
            rebuildFilteredList()
        }
    }

    private func bindPublishers() {
        vault.$pdfs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.window?.isVisible == true {
                    self.rebuildFilteredList()
                } else {
                    self.needsReloadWhenShown = true
                }
            }
            .store(in: &cancellables)

        vault.$vaultURL
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                self?.folderLabel.stringValue = url.map { "Vault: \($0.lastPathComponent)" } ?? "No Vault Selected"
            }
            .store(in: &cancellables)

        syncManager.$statusText
            .combineLatest(syncManager.$syncProgressText)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status, progress in
                guard let self else { return }
                self.syncStatusLabel.stringValue = progress.isEmpty ? status : progress
                self.syncBtn.title = self.syncManager.config.isConnected ? "Sync Drive" : "Connect Drive…"
            }
            .store(in: &cancellables)
    }

    private func rebuildFilteredList() {
        let q = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base: [PDFItem]
        switch filterControl.selectedSegment {
        case 1: // Recent
            let byRel = Dictionary(uniqueKeysWithValues: vault.pdfs.map { ($0.relativePath, $0) })
            base = vault.recentPaths.compactMap { byRel[$0] }
        case 2: // Favorites
            base = vault.pdfs.filter { vault.favoritePaths.contains($0.relativePath) }
        case 3: // Annotated
            base = vault.pdfs.filter { $0.hasInk }
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
        tableView.reloadData()
        emptyLabel.isHidden = !filteredItems.isEmpty
        if vault.vaultURL == nil {
            emptyLabel.stringValue = "Click \"Choose Vault…\" to select your Obsidian Vault or PDF folder."
        } else if !q.isEmpty {
            emptyLabel.stringValue = "No PDFs matching \"\(searchField.stringValue)\"."
        } else {
            emptyLabel.stringValue = "No PDFs in this view."
        }
    }

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

    @objc private func filterChanged() {
        rebuildFilteredList()
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
        let row = tableView.selectedRow
        guard row >= 0, row < filteredItems.count else { return }
        let item = filteredItems[row]
        vault.recordRecentlyOpened(item.relativePath)
        onOpenPDF?(item)
    }

    private func contextItem() -> PDFItem? {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
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
        filteredItems.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filteredItems.count, let colID = tableColumn?.identifier else { return nil }
        let item = filteredItems[row]
        let cell = (tableView.makeView(withIdentifier: colID, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = colID
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingTail
            c.addSubview(tf)
            c.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor)
            ])
            return c
        }()

        switch colID.rawValue {
        case "name":
            cell.textField?.font = Self.cellNameFont
            cell.textField?.textColor = .labelColor
            cell.textField?.stringValue = item.name
        case "folder":
            cell.textField?.font = Self.cellFolderFont
            cell.textField?.textColor = .secondaryLabelColor
            cell.textField?.stringValue = item.relativeFolder.isEmpty ? "Root" : item.relativeFolder
        case "ink":
            cell.textField?.font = Self.cellInkFont
            cell.textField?.textColor = item.hasInk ? .systemBlue : .tertiaryLabelColor
            cell.textField?.stringValue = item.hasInk ? "Ink" : "—"
        default:
            cell.textField?.font = Self.cellDateFont
            cell.textField?.textColor = .secondaryLabelColor
            cell.textField?.stringValue = dateFormatter.string(from: item.modifiedAt)
        }
        return cell
    }
}
