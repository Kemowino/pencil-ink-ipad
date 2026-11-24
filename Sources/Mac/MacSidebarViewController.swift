import AppKit
import PDFKit

final class MacOutlineNode: NSObject {
    let title: String
    let pageIndex: Int
    let children: [MacOutlineNode]

    init(title: String, pageIndex: Int, children: [MacOutlineNode]) {
        self.title = title
        self.pageIndex = pageIndex
        self.children = children
    }
}

struct MacBookmarkItem {
    let key: String
    let pageIndex: Int
    let label: String
}

struct MacSearchResultItem {
    let pageIndex: Int
    let snippet: String
    let selection: PDFSelection
}

@MainActor
protocol MacSidebarDelegate: AnyObject {
    func sidebarDidSelectPage(at index: Int)
    func sidebarDidSelectSearchResult(_ item: MacSearchResultItem)
}

/// Pure AppKit collapsible Sidebar (Outline | Bookmarks | Search) — 0% CPU when collapsed!
final class MacSidebarViewController: NSViewController,
    NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSTableViewDataSource, NSTableViewDelegate,
    NSSearchFieldDelegate {

    weak var delegate: MacSidebarDelegate?

    private weak var pdfDocument: PDFDocument?
    private var outlineRoots: [MacOutlineNode] = []
    private var outlineLoaded = false
    private var isSidebarExpanded = false
    private var bookmarks: [MacBookmarkItem] = []
    private var searchResults: [MacSearchResultItem] = []

    private static let outlineFont = NSFont.systemFont(ofSize: 12.5)
    private static let pageNumFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private static let rowTitleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let rowSubFont = NSFont.systemFont(ofSize: 11)

    private let tabControl = NSSegmentedControl(labels: ["Outline", "Bookmarks", "Search"], trackingMode: .selectOne, target: nil, action: nil)
    private let searchField = NSSearchField()
    private let searchStatusLabel = NSTextField(labelWithString: "")

    private let outlineScroll = NSScrollView()
    private let outlineView = NSOutlineView()

    private let tableScroll = NSScrollView()
    private let tableView = NSTableView()

    private let emptyLabel = NSTextField(labelWithString: "")
    private var searchDebounce: DispatchWorkItem?
    private var searchGeneration: Int = 0
    private let searchQueue = DispatchQueue(label: "com.pencilink.mac.search", qos: .userInitiated)

    private enum Mode: Int { case outline = 0, bookmarks = 1, search = 2 }
    private var mode: Mode = .outline

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 600))
        root.wantsLayer = true
        self.view = root
        setupUI()
    }

    private func setupUI() {
        tabControl.translatesAutoresizingMaskIntoConstraints = false
        tabControl.selectedSegment = 0
        tabControl.target = self
        tabControl.action = #selector(tabChanged)
        view.addSubview(tabControl)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search PDF text…"
        searchField.delegate = self
        searchField.isHidden = true
        view.addSubview(searchField)

        searchStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        searchStatusLabel.font = NSFont.systemFont(ofSize: 11)
        searchStatusLabel.textColor = .secondaryLabelColor
        searchStatusLabel.isHidden = true
        view.addSubview(searchStatusLabel)

        // Outline View (Hierarchical PDF Table of Contents)
        let outCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("outline"))
        outCol.resizingMask = .autoresizingMask
        outlineView.addTableColumn(outCol)
        outlineView.outlineTableColumn = outCol
        outlineView.headerView = nil
        outlineView.rowHeight = 24
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(outlineClicked)
        outlineScroll.translatesAutoresizingMaskIntoConstraints = false
        outlineScroll.documentView = outlineView
        outlineScroll.hasVerticalScroller = true
        outlineScroll.drawsBackground = false
        view.addSubview(outlineScroll)

        // Table View (Bookmarks & Search Results)
        let tblCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        tblCol.resizingMask = .autoresizingMask
        tableView.addTableColumn(tblCol)
        tableView.headerView = nil
        tableView.rowHeight = 42
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(tableClicked)
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.drawsBackground = false
        tableScroll.isHidden = true
        view.addSubview(tableScroll)

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = NSFont.systemFont(ofSize: 12.5)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 3
        emptyLabel.isHidden = true
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            tabControl.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            tabControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            tabControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),

            searchField.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),

            searchStatusLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 4),
            searchStatusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            searchStatusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            outlineScroll.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 8),
            outlineScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            outlineScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            outlineScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            tableScroll.topAnchor.constraint(equalTo: searchStatusLabel.bottomAnchor, constant: 4),
            tableScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])
    }

    func configure(document: PDFDocument?, bookmarks: [MacBookmarkItem]) {
        self.pdfDocument = document
        self.bookmarks = bookmarks
        self.outlineRoots = []
        self.outlineLoaded = false
        self.searchResults = []
        searchDebounce?.cancel()
        searchGeneration &+= 1
        if isSidebarExpanded {
            ensureOutlineLoadedIfNeeded()
            tableView.reloadData()
            updateVisibility()
        }
    }

    func setSidebarVisible(_ visible: Bool) {
        isSidebarExpanded = visible
        if visible {
            ensureOutlineLoadedIfNeeded()
            tableView.reloadData()
            updateVisibility()
        } else {
            // Cancel any active search & release PDFSelection memory when sidebar collapses!
            searchDebounce?.cancel()
            searchDebounce = nil
            searchGeneration &+= 1
            if !searchResults.isEmpty {
                searchResults.removeAll()
                tableView.reloadData()
            }
        }
    }

    private func ensureOutlineLoadedIfNeeded() {
        guard !outlineLoaded else { return }
        outlineLoaded = true
        outlineRoots = Self.extractOutline(from: pdfDocument)
        outlineView.reloadData()
    }

    func updateBookmarks(_ items: [MacBookmarkItem]) {
        self.bookmarks = items
        if isSidebarExpanded && mode == .bookmarks {
            tableView.reloadData()
            updateVisibility()
        }
    }

    func focusSearch() {
        isSidebarExpanded = true
        mode = .search
        tabControl.selectedSegment = Mode.search.rawValue
        updateVisibility()
        view.window?.makeFirstResponder(searchField)
    }

    @objc private func tabChanged() {
        mode = Mode(rawValue: tabControl.selectedSegment) ?? .outline
        if mode == .outline { ensureOutlineLoadedIfNeeded() }
        updateVisibility()
        tableView.reloadData()
        if mode == .search {
            view.window?.makeFirstResponder(searchField)
        }
    }

    private func updateVisibility() {
        let isSearch = (mode == .search)
        let isOutline = (mode == .outline)
        searchField.isHidden = !isSearch
        searchStatusLabel.isHidden = !isSearch
        outlineScroll.isHidden = !isOutline
        tableScroll.isHidden = isOutline

        if isOutline {
            emptyLabel.stringValue = "No Table of Contents in this PDF."
            emptyLabel.isHidden = !outlineRoots.isEmpty
        } else if mode == .bookmarks {
            emptyLabel.stringValue = "No bookmarked pages yet.\nClick the bookmark button in the toolbar."
            emptyLabel.isHidden = !bookmarks.isEmpty
            tableView.rowHeight = 32
        } else {
            emptyLabel.stringValue = searchField.stringValue.count < 2
                ? "Type at least 2 characters to search."
                : (searchResults.isEmpty ? "No matches found." : "")
            emptyLabel.isHidden = !searchResults.isEmpty
            tableView.rowHeight = 46
        }
    }

    private static func extractOutline(from doc: PDFDocument?) -> [MacOutlineNode] {
        guard let doc, let root = doc.outlineRoot else { return [] }
        var totalNodes = 0
        func walk(_ node: PDFOutline) -> [MacOutlineNode] {
            var list: [MacOutlineNode] = []
            for i in 0..<node.numberOfChildren {
                if totalNodes >= 1000 { break }
                guard let child = node.child(at: i) else { continue }
                let label = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let destPage = child.destination?.page ?? (child.action as? PDFActionGoTo)?.destination.page
                let idx = destPage.map { doc.index(for: $0) } ?? NSNotFound
                let kids = walk(child)
                if !label.isEmpty && (idx != NSNotFound || !kids.isEmpty) {
                    totalNodes += 1
                    list.append(MacOutlineNode(title: label, pageIndex: idx == NSNotFound ? -1 : idx, children: kids))
                }
            }
            return list
        }
        return walk(root)
    }

    // MARK: - Debounced Background Search

    func controlTextDidChange(_ obj: Notification) {
        guard mode == .search else { return }
        searchDebounce?.cancel()
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2, let doc = pdfDocument else {
            searchResults = []
            searchStatusLabel.stringValue = ""
            tableView.reloadData()
            updateVisibility()
            return
        }
        searchGeneration &+= 1
        let gen = searchGeneration
        searchStatusLabel.stringValue = "Searching…"
        let work = DispatchWorkItem { [weak self] in
            self?.searchQueue.async {
                let matches = doc.findString(query, withOptions: [.caseInsensitive])
                var items: [MacSearchResultItem] = []
                items.reserveCapacity(min(matches.count, 120))
                for sel in matches.prefix(120) {
                    guard let page = sel.pages.first else { continue }
                    let idx = doc.index(for: page)
                    guard idx != NSNotFound else { continue }
                    let snippet: String
                    if let ext = sel.copy() as? PDFSelection {
                        ext.extend(atStart: 24)
                        ext.extend(atEnd: 44)
                        snippet = (ext.string ?? query).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    } else {
                        snippet = sel.string ?? query
                    }
                    items.append(MacSearchResultItem(pageIndex: idx, snippet: snippet, selection: sel))
                }
                DispatchQueue.main.async {
                    guard let self, self.searchGeneration == gen else { return }
                    self.searchResults = items
                    self.searchStatusLabel.stringValue = items.isEmpty ? "0 matches" : "\(items.count)\(matches.count > 120 ? "+" : "") matches"
                    self.tableView.reloadData()
                    self.updateVisibility()
                }
            }
        }
        searchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    // MARK: - NSOutlineViewDataSource & Delegate

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? MacOutlineNode { return node.children.count }
        return outlineRoots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? MacOutlineNode { return node.children[index] }
        return outlineRoots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? MacOutlineNode)?.children.isEmpty == false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? MacOutlineNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("OutlineCell")
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = id
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingTail
            tf.font = Self.outlineFont
            c.addSubview(tf)
            c.textField = tf
            let pg = NSTextField(labelWithString: "")
            pg.translatesAutoresizingMaskIntoConstraints = false
            pg.font = Self.pageNumFont
            pg.textColor = .secondaryLabelColor
            pg.alignment = .right
            pg.tag = 99
            c.addSubview(pg)
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                tf.trailingAnchor.constraint(lessThanOrEqualTo: pg.leadingAnchor, constant: -6),
                pg.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -6),
                pg.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                pg.widthAnchor.constraint(greaterThanOrEqualToConstant: 26)
            ])
            return c
        }()
        cell.textField?.stringValue = node.title
        if let pg = cell.viewWithTag(99) as? NSTextField {
            pg.stringValue = node.pageIndex >= 0 ? "\(node.pageIndex + 1)" : ""
        }
        return cell
    }

    @objc private func outlineClicked() {
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? MacOutlineNode, node.pageIndex >= 0 else { return }
        delegate?.sidebarDidSelectPage(at: node.pageIndex)
    }

    // MARK: - NSTableViewDataSource & Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        mode == .bookmarks ? bookmarks.count : searchResults.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("SidebarRowCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = id
            let title = NSTextField(labelWithString: "")
            title.translatesAutoresizingMaskIntoConstraints = false
            title.font = Self.rowTitleFont
            title.lineBreakMode = .byTruncatingTail
            c.addSubview(title)
            c.textField = title

            let sub = NSTextField(labelWithString: "")
            sub.translatesAutoresizingMaskIntoConstraints = false
            sub.font = Self.rowSubFont
            sub.textColor = .secondaryLabelColor
            sub.lineBreakMode = .byTruncatingTail
            sub.tag = 88
            c.addSubview(sub)

            NSLayoutConstraint.activate([
                title.topAnchor.constraint(equalTo: c.topAnchor, constant: 4),
                title.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 8),
                title.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -8),
                sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
                sub.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 8),
                sub.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -8),
            ])
            return c
        }()
        let sub = cell.viewWithTag(88) as? NSTextField
        if mode == .bookmarks, row < bookmarks.count {
            let b = bookmarks[row]
            cell.textField?.stringValue = b.label
            sub?.stringValue = "Page \(b.pageIndex + 1)"
        } else if mode == .search, row < searchResults.count {
            let s = searchResults[row]
            cell.textField?.stringValue = "Page \(s.pageIndex + 1)"
            sub?.stringValue = s.snippet
        }
        return cell
    }

    @objc private func tableClicked() {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        if mode == .bookmarks, row < bookmarks.count {
            delegate?.sidebarDidSelectPage(at: bookmarks[row].pageIndex)
        } else if mode == .search, row < searchResults.count {
            delegate?.sidebarDidSelectSearchResult(searchResults[row])
        }
    }
}
