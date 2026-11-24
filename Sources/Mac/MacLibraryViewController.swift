import AppKit
import Combine
import QuartzCore
import UniformTypeIdentifiers

private enum MacLibrarySidebarEntry {
    case header(String)
    case allPDFs
    case recent
    case favorites
    case annotated
    case journals
    case folder(FolderItem)
}

/// Interactive Studio Craft Grid Cover Card (`NSCollectionViewItem`) with hover lift,
/// aspect-fitted PDF page-1 previews, Hobonichi fabric spine covers, & Ink/Favorite badges.
private final class MacDocumentGridItem: NSCollectionViewItem {
    static let reuseID = NSUserInterfaceItemIdentifier("MacDocumentGridItem")

    private let cardRoot = NSView()
    private let coverStage = NSView()
    private let coverFrameView = NSView()
    private let coverImageView = NSImageView()
    private let spineStripe = NSView()
    private let hoboCard = NSView()
    private let hoboTagLabel = NSTextField(labelWithString: "HOBONICHI")
    private let hoboTitleLabel = NSTextField(wrappingLabelWithString: "")
    private let inkDot = NSView()
    private let starIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    private var coverWConstraint: NSLayoutConstraint?
    private var coverHConstraint: NSLayoutConstraint?
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    var representedItem: PDFItem?
    var representedItemID: String = ""
    var onOpen: ((PDFItem) -> Void)?
    var contextMenuProvider: ((PDFItem) -> NSMenu)?

    private static let titleFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    private static let subFont = NSFont.systemFont(ofSize: 10.5, weight: .regular)
    private static let starSymbol = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Favorite")
    private static let docSymbol = NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: "PDF")

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 176, height: 224))
        self.view = root
        setupUI()
    }

    private func setupUI() {
        cardRoot.translatesAutoresizingMaskIntoConstraints = false
        cardRoot.wantsLayer = true
        cardRoot.layer?.cornerRadius = DesignTokens.radiusMedium
        cardRoot.layer?.backgroundColor = NSColor.clear.cgColor
        cardRoot.layer?.borderWidth = 1.0
        cardRoot.layer?.borderColor = NSColor.clear.cgColor
        view.addSubview(cardRoot)

        coverStage.translatesAutoresizingMaskIntoConstraints = false
        cardRoot.addSubview(coverStage)

        coverFrameView.translatesAutoresizingMaskIntoConstraints = false
        coverFrameView.wantsLayer = true
        coverFrameView.layer?.cornerRadius = 8
        coverFrameView.layer?.masksToBounds = true
        coverFrameView.layer?.borderWidth = 0.8
        coverFrameView.layer?.borderColor = DesignTokens.nsPageBorder.cgColor
        coverFrameView.layer?.backgroundColor = NSColor.white.cgColor
        coverStage.addSubview(coverFrameView)

        coverImageView.translatesAutoresizingMaskIntoConstraints = false
        coverImageView.imageScaling = .scaleProportionallyUpOrDown
        coverFrameView.addSubview(coverImageView)

        spineStripe.translatesAutoresizingMaskIntoConstraints = false
        spineStripe.wantsLayer = true
        spineStripe.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.24).cgColor
        spineStripe.isHidden = true
        coverFrameView.addSubview(spineStripe)

        hoboCard.translatesAutoresizingMaskIntoConstraints = false
        hoboCard.wantsLayer = true
        hoboCard.layer?.cornerRadius = 5
        hoboCard.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.94).cgColor
        hoboCard.isHidden = true
        coverFrameView.addSubview(hoboCard)

        hoboTagLabel.translatesAutoresizingMaskIntoConstraints = false
        hoboTagLabel.font = NSFont.systemFont(ofSize: 7.5, weight: .heavy)
        hoboTagLabel.textColor = NSColor(red: 0.61, green: 0.49, blue: 0.33, alpha: 1.0)
        hoboTagLabel.alignment = .center
        hoboCard.addSubview(hoboTagLabel)

        hoboTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        hoboTitleLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        hoboTitleLabel.textColor = NSColor(white: 0.14, alpha: 1.0)
        hoboTitleLabel.alignment = .center
        hoboTitleLabel.maximumNumberOfLines = 3
        hoboTitleLabel.lineBreakMode = .byTruncatingTail
        hoboCard.addSubview(hoboTitleLabel)

        inkDot.translatesAutoresizingMaskIntoConstraints = false
        inkDot.wantsLayer = true
        inkDot.layer?.cornerRadius = 4.5
        inkDot.layer?.backgroundColor = DesignTokens.nsAccent.cgColor
        inkDot.layer?.borderWidth = 1.5
        inkDot.layer?.borderColor = NSColor.white.cgColor
        inkDot.isHidden = true
        coverFrameView.addSubview(inkDot)

        starIcon.translatesAutoresizingMaskIntoConstraints = false
        starIcon.image = Self.starSymbol
        starIcon.contentTintColor = DesignTokens.nsWarmGold
        starIcon.isHidden = true
        coverFrameView.addSubview(starIcon)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = Self.titleFont
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.usesSingleLineMode = false
        titleLabel.cell?.wraps = true
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 2
        cardRoot.addSubview(titleLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = Self.subFont
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.lineBreakMode = .byTruncatingTail
        cardRoot.addSubview(subtitleLabel)

        let cw = coverFrameView.widthAnchor.constraint(equalToConstant: 112)
        let ch = coverFrameView.heightAnchor.constraint(equalToConstant: 150)
        coverWConstraint = cw
        coverHConstraint = ch

        NSLayoutConstraint.activate([
            cardRoot.topAnchor.constraint(equalTo: view.topAnchor, constant: 2),
            cardRoot.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -2),
            cardRoot.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            cardRoot.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),

            coverStage.topAnchor.constraint(equalTo: cardRoot.topAnchor, constant: 8),
            coverStage.leadingAnchor.constraint(equalTo: cardRoot.leadingAnchor, constant: 10),
            coverStage.trailingAnchor.constraint(equalTo: cardRoot.trailingAnchor, constant: -10),
            coverStage.heightAnchor.constraint(equalToConstant: 154),

            coverFrameView.centerXAnchor.constraint(equalTo: coverStage.centerXAnchor),
            coverFrameView.bottomAnchor.constraint(equalTo: coverStage.bottomAnchor, constant: -2),
            cw, ch,

            coverImageView.topAnchor.constraint(equalTo: coverFrameView.topAnchor),
            coverImageView.bottomAnchor.constraint(equalTo: coverFrameView.bottomAnchor),
            coverImageView.leadingAnchor.constraint(equalTo: coverFrameView.leadingAnchor),
            coverImageView.trailingAnchor.constraint(equalTo: coverFrameView.trailingAnchor),

            spineStripe.topAnchor.constraint(equalTo: coverFrameView.topAnchor),
            spineStripe.bottomAnchor.constraint(equalTo: coverFrameView.bottomAnchor),
            spineStripe.leadingAnchor.constraint(equalTo: coverFrameView.leadingAnchor),
            spineStripe.widthAnchor.constraint(equalToConstant: 11),

            hoboCard.topAnchor.constraint(equalTo: coverFrameView.topAnchor, constant: 18),
            hoboCard.leadingAnchor.constraint(equalTo: coverFrameView.leadingAnchor, constant: 18),
            hoboCard.trailingAnchor.constraint(equalTo: coverFrameView.trailingAnchor, constant: -10),

            hoboTagLabel.topAnchor.constraint(equalTo: hoboCard.topAnchor, constant: 6),
            hoboTagLabel.leadingAnchor.constraint(equalTo: hoboCard.leadingAnchor, constant: 5),
            hoboTagLabel.trailingAnchor.constraint(equalTo: hoboCard.trailingAnchor, constant: -5),

            hoboTitleLabel.topAnchor.constraint(equalTo: hoboTagLabel.bottomAnchor, constant: 3),
            hoboTitleLabel.leadingAnchor.constraint(equalTo: hoboCard.leadingAnchor, constant: 5),
            hoboTitleLabel.trailingAnchor.constraint(equalTo: hoboCard.trailingAnchor, constant: -5),
            hoboTitleLabel.bottomAnchor.constraint(equalTo: hoboCard.bottomAnchor, constant: -7),

            inkDot.topAnchor.constraint(equalTo: coverFrameView.topAnchor, constant: 6),
            inkDot.trailingAnchor.constraint(equalTo: coverFrameView.trailingAnchor, constant: -6),
            inkDot.widthAnchor.constraint(equalToConstant: 9),
            inkDot.heightAnchor.constraint(equalToConstant: 9),

            starIcon.topAnchor.constraint(equalTo: coverFrameView.topAnchor, constant: 5),
            starIcon.leadingAnchor.constraint(equalTo: coverFrameView.leadingAnchor, constant: 6),
            starIcon.widthAnchor.constraint(equalToConstant: 12),
            starIcon.heightAnchor.constraint(equalToConstant: 12),

            titleLabel.topAnchor.constraint(equalTo: coverStage.bottomAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: cardRoot.leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: cardRoot.trailingAnchor, constant: -8),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: cardRoot.leadingAnchor, constant: 8),
            subtitleLabel.trailingAnchor.constraint(equalTo: cardRoot.trailingAnchor, constant: -8)
        ])

        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        view.addTrackingArea(area)
        trackingArea = area
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
        representedItem = nil
        representedItemID = ""
        coverImageView.image = nil
        inkDot.isHidden = true
        starIcon.isHidden = true
        updateCardHighlight(animated: false)
    }

    override var isSelected: Bool {
        didSet { updateCardHighlight(animated: true) }
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateCardHighlight(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateCardHighlight(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, let item = representedItem {
            onOpen?(item)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        super.rightMouseDown(with: event)
        if let item = representedItem, let menu = contextMenuProvider?(item) {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }
    }

    private func updateCardHighlight(animated: Bool) {
        let active = isSelected || isHovered
        let bg = isSelected
            ? DesignTokens.nsAccent.withAlphaComponent(0.14).cgColor
            : (isHovered ? NSColor.labelColor.withAlphaComponent(0.05).cgColor : NSColor.clear.cgColor)
        let border = isSelected
            ? DesignTokens.nsAccent.withAlphaComponent(0.55).cgColor
            : (isHovered ? DesignTokens.nsHairline.cgColor : NSColor.clear.cgColor)
        let coverBorder = active
            ? DesignTokens.nsAccent.withAlphaComponent(0.65).cgColor
            : DesignTokens.nsPageBorder.cgColor

        let apply = {
            self.cardRoot.layer?.backgroundColor = bg
            self.cardRoot.layer?.borderColor = border
            self.coverFrameView.layer?.borderColor = coverBorder
        }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.13
                apply()
            }
        } else {
            apply()
        }
    }

    private func applyAspectFit(for size: NSSize) {
        let maxW: CGFloat = 148
        let maxH: CGFloat = 150
        let ratio = max(0.58, min(1.75, size.width / max(1, size.height)))
        var w = maxW
        var h = w / ratio
        if h > maxH {
            h = maxH
            w = h * ratio
        }
        coverWConstraint?.constant = max(72, w.rounded())
        coverHConstraint?.constant = max(72, h.rounded())
    }

    func configure(item: PDFItem, isFavorite: Bool, dateString: String, vault: VaultManager) {
        representedItem = item
        representedItemID = item.id
        titleLabel.stringValue = item.name
        subtitleLabel.stringValue = dateString
        inkDot.isHidden = !item.hasInk
        starIcon.isHidden = !isFavorite
        isHovered = false
        updateCardHighlight(animated: false)

        if item.isHobonichi {
            let pal = HobonichiEngine.palette(for: item.name, customID: vault.coverColors[item.relativePath])
            applyAspectFit(for: NSSize(width: 74, height: 100))
            coverFrameView.layer?.backgroundColor = pal.bgColor.cgColor
            coverImageView.image = nil
            spineStripe.isHidden = false
            hoboCard.isHidden = false
            hoboTagLabel.isHidden = false
            hoboTitleLabel.stringValue = item.name
            return
        }

        spineStripe.isHidden = true
        hoboCard.isHidden = true
        coverFrameView.layer?.backgroundColor = NSColor.white.cgColor

        if let cached = vault.cachedCoverThumb(for: item) {
            applyAspectFit(for: cached.size)
            coverImageView.imageScaling = .scaleProportionallyUpOrDown
            coverImageView.image = cached
        } else {
            applyAspectFit(for: NSSize(width: 74, height: 100))
            coverImageView.imageScaling = .scaleNone
            coverImageView.contentTintColor = .tertiaryLabelColor
            coverImageView.image = Self.docSymbol
            let expectedID = item.id
            vault.loadCoverThumb(for: item) { [weak self] img in
                guard let self, self.representedItemID == expectedID, let img else { return }
                self.applyAspectFit(for: img.size)
                self.coverImageView.imageScaling = .scaleProportionallyUpOrDown
                self.coverImageView.image = img
            }
        }
    }
}

/// Spacious native macOS document row for List View mode.
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
    private static let calendarIcon = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Journal")

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
        thumbBox.layer?.cornerRadius = 5
        thumbBox.layer?.masksToBounds = true
        thumbBox.layer?.borderWidth = 0.6
        thumbBox.layer?.borderColor = DesignTokens.nsPageBorder.cgColor
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
        inkBadge.textColor = DesignTokens.nsAccent
        inkBadge.alignment = .center
        inkBadge.wantsLayer = true
        inkBadge.layer?.cornerRadius = 9
        inkBadge.layer?.backgroundColor = DesignTokens.nsAccent.withAlphaComponent(0.14).cgColor
        addSubview(inkBadge)

        starImageView.translatesAutoresizingMaskIntoConstraints = false
        starImageView.image = Self.starIcon
        starImageView.contentTintColor = DesignTokens.nsWarmGold
        addSubview(starImageView)

        NSLayoutConstraint.activate([
            thumbBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            thumbBox.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbBox.widthAnchor.constraint(equalToConstant: 36),
            thumbBox.heightAnchor.constraint(equalToConstant: 46),

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
            inkBadge.widthAnchor.constraint(equalToConstant: 70),
            inkBadge.heightAnchor.constraint(equalToConstant: 19),

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
            thumbImageView.image = Self.calendarIcon
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

/// Appearance-aware root NSView so switching macOS Dark/Light mode re-tints opaque `DesignTokens` layers immediately.
private final class MacThemeObserverView: NSView {
    var onAppearanceChanged: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChanged?()
    }
}

/// Studio Craft 2-Pane Library view controller mounted inside Tab 0 of `MacWorkspaceWindowController`.
/// Features Grid Cover Shelf (`NSCollectionView`) + Compact List View (`NSTableView`), Sort, + New creation,
/// Hobonichi Journals section, & live Drive sync status — 100% pure AppKit with 0% idle CPU!
@MainActor
final class MacLibraryViewController: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate,
    NSCollectionViewDataSource, NSCollectionViewDelegate,
    NSSearchFieldDelegate {

    let vault: VaultManager
    let syncManager: DriveSyncManager
    var onOpenPDF: ((PDFItem) -> Void)?
    var onOpenSyncSettings: (() -> Void)?

    private let splitView = NSSplitView()
    private let leftPane = NSView()
    private let sidebarScroll = NSScrollView()
    private let sidebarTable = NSTableView()
    private let vaultFooterBar = NSView()
    private let vaultNameLabel = NSTextField(labelWithString: "No Vault Selected")
    private let chooseVaultBtn = NSButton()

    private let rightPane = NSView()
    private let headerBar = NSView()
    private let sectionTitleLabel = NSTextField(labelWithString: "All Documents")
    private let countPillLabel = NSTextField(labelWithString: "0")
    private let newBtn = NSButton()
    private let sortPopup = NSPopUpButton()
    private let viewModeSegment = NSSegmentedControl()
    private let syncDotView = NSView()
    private let syncNowBtn = NSButton(title: "Sync", target: nil, action: nil)
    private let searchField = NSSearchField()

    private let gridScroll = NSScrollView()
    private let gridView = NSCollectionView()
    private let docScroll = NSScrollView()
    private let docTable = NSTableView()

    private let emptyCard = NSView()
    private let emptyIcon = NSImageView()
    private let emptyTitle = NSTextField(labelWithString: "Connect Your Obsidian Vault")
    private let emptySub = NSTextField(labelWithString: "Choose your vault folder to browse PDFs, view iPad notes, and sync with Google Drive.")
    private let emptyChooseBtn = NSButton(title: "Choose Vault Folder…", target: nil, action: nil)
    private let statusFooter = NSTextField(labelWithString: "")

    private var sidebarEntries: [MacLibrarySidebarEntry] = []
    private var selectedSidebarIndex: Int = 1
    private var filteredItems: [PDFItem] = []
    private var cachedAnnotatedCount: Int = 0
    private var cachedJournalCount: Int = 0
    private var isActiveTab = true
    private var needsReloadWhenShown = false
    private var searchDebounce: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    // Static cached SF Symbols (zero per-row allocations on scroll!)
    private static let iconBooks = NSImage(systemSymbolName: "books.vertical", accessibilityDescription: nil)
    private static let iconClock = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
    private static let iconStar = NSImage(systemSymbolName: "star", accessibilityDescription: nil)
    private static let iconHighlighter = NSImage(systemSymbolName: "highlighter", accessibilityDescription: nil)
    private static let iconCalendar = NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)
    private static let iconFolder = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
    private static let folderTint = NSColor(
        red: DesignTokens.skyFolderTopRGB.r,
        green: DesignTokens.skyFolderTopRGB.g,
        blue: DesignTokens.skyFolderTopRGB.b,
        alpha: 1.0
    )

    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        return df
    }()

    private let listDateFormatter: DateFormatter = {
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
        let root = MacThemeObserverView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
        root.wantsLayer = true
        root.onAppearanceChanged = { [weak self] in
            self?.applyThemeColors()
        }
        self.view = root
        setupUI(in: root)
        applyThemeColors()
        bindPublishers()
        rebuildSidebarAndList()
        applyDisplayMode(animated: false)
    }

    private func applyThemeColors() {
        leftPane.layer?.backgroundColor = DesignTokens.nsSidebarBg.cgColor
        rightPane.layer?.backgroundColor = DesignTokens.nsCanvasBackdrop.cgColor
        headerBar.layer?.backgroundColor = DesignTokens.nsChromePrimary.cgColor
        vaultFooterBar.layer?.backgroundColor = DesignTokens.nsSidebarBg.cgColor
        gridScroll.backgroundColor = DesignTokens.nsCanvasBackdrop
        docScroll.backgroundColor = DesignTokens.nsChromePrimary
        docTable.gridColor = DesignTokens.nsHairline
        countPillLabel.layer?.backgroundColor = DesignTokens.nsAccent.withAlphaComponent(0.13).cgColor
        emptyCard.layer?.backgroundColor = DesignTokens.nsCardSurface.cgColor
        emptyCard.layer?.borderColor = DesignTokens.nsHairline.cgColor
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

        // MARK: Left Pane — Studio Sidebar + Vault Footer
        leftPane.frame = NSRect(x: 0, y: 0, width: 224, height: 640)
        leftPane.wantsLayer = true

        let sCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        sCol.resizingMask = .autoresizingMask
        sidebarTable.addTableColumn(sCol)
        sidebarTable.headerView = nil
        sidebarTable.style = .sourceList
        sidebarTable.rowHeight = 28
        sidebarTable.dataSource = self
        sidebarTable.delegate = self

        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        sidebarScroll.documentView = sidebarTable
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.drawsBackground = false
        leftPane.addSubview(sidebarScroll)

        let vaultSep = NSBox()
        vaultSep.boxType = .separator
        vaultSep.translatesAutoresizingMaskIntoConstraints = false
        leftPane.addSubview(vaultSep)

        vaultFooterBar.translatesAutoresizingMaskIntoConstraints = false
        vaultFooterBar.wantsLayer = true
        leftPane.addSubview(vaultFooterBar)

        let folderIcon = NSImageView()
        folderIcon.translatesAutoresizingMaskIntoConstraints = false
        folderIcon.image = Self.iconFolder
        folderIcon.contentTintColor = DesignTokens.nsAccent
        vaultFooterBar.addSubview(folderIcon)

        vaultNameLabel.translatesAutoresizingMaskIntoConstraints = false
        vaultNameLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        vaultNameLabel.textColor = .labelColor
        vaultNameLabel.lineBreakMode = .byTruncatingTail
        vaultNameLabel.stringValue = vault.vaultURL?.lastPathComponent ?? "No Vault Selected"
        vaultFooterBar.addSubview(vaultNameLabel)

        chooseVaultBtn.translatesAutoresizingMaskIntoConstraints = false
        chooseVaultBtn.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Change Vault")
        chooseVaultBtn.bezelStyle = .recessed
        chooseVaultBtn.isBordered = false
        chooseVaultBtn.contentTintColor = .secondaryLabelColor
        chooseVaultBtn.toolTip = "Choose Vault Folder…"
        chooseVaultBtn.target = self
        chooseVaultBtn.action = #selector(chooseVaultFolder)
        vaultFooterBar.addSubview(chooseVaultBtn)

        NSLayoutConstraint.activate([
            leftPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 204),
            leftPane.widthAnchor.constraint(lessThanOrEqualToConstant: 280),

            sidebarScroll.topAnchor.constraint(equalTo: leftPane.topAnchor, constant: 6),
            sidebarScroll.leadingAnchor.constraint(equalTo: leftPane.leadingAnchor),
            sidebarScroll.trailingAnchor.constraint(equalTo: leftPane.trailingAnchor),
            sidebarScroll.bottomAnchor.constraint(equalTo: vaultSep.topAnchor),

            vaultSep.leadingAnchor.constraint(equalTo: leftPane.leadingAnchor),
            vaultSep.trailingAnchor.constraint(equalTo: leftPane.trailingAnchor),
            vaultSep.bottomAnchor.constraint(equalTo: vaultFooterBar.topAnchor),

            vaultFooterBar.leadingAnchor.constraint(equalTo: leftPane.leadingAnchor),
            vaultFooterBar.trailingAnchor.constraint(equalTo: leftPane.trailingAnchor),
            vaultFooterBar.bottomAnchor.constraint(equalTo: leftPane.bottomAnchor),
            vaultFooterBar.heightAnchor.constraint(equalToConstant: 40),

            folderIcon.leadingAnchor.constraint(equalTo: vaultFooterBar.leadingAnchor, constant: 12),
            folderIcon.centerYAnchor.constraint(equalTo: vaultFooterBar.centerYAnchor),
            folderIcon.widthAnchor.constraint(equalToConstant: 15),
            folderIcon.heightAnchor.constraint(equalToConstant: 15),

            vaultNameLabel.leadingAnchor.constraint(equalTo: folderIcon.trailingAnchor, constant: 7),
            vaultNameLabel.centerYAnchor.constraint(equalTo: vaultFooterBar.centerYAnchor),
            vaultNameLabel.trailingAnchor.constraint(lessThanOrEqualTo: chooseVaultBtn.leadingAnchor, constant: -6),

            chooseVaultBtn.trailingAnchor.constraint(equalTo: vaultFooterBar.trailingAnchor, constant: -10),
            chooseVaultBtn.centerYAnchor.constraint(equalTo: vaultFooterBar.centerYAnchor),
            chooseVaultBtn.widthAnchor.constraint(equalToConstant: 24),
            chooseVaultBtn.heightAnchor.constraint(equalToConstant: 24)
        ])

        // MARK: Right Pane — Header Bar + Grid Cover Shelf / List View + Status Footer
        rightPane.frame = NSRect(x: 0, y: 0, width: 736, height: 640)
        rightPane.wantsLayer = true

        headerBar.translatesAutoresizingMaskIntoConstraints = false
        headerBar.wantsLayer = true
        rightPane.addSubview(headerBar)

        sectionTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        sectionTitleLabel.font = NSFont.systemFont(ofSize: 15, weight: .bold)
        sectionTitleLabel.textColor = .labelColor
        sectionTitleLabel.lineBreakMode = .byTruncatingTail

        countPillLabel.translatesAutoresizingMaskIntoConstraints = false
        countPillLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        countPillLabel.textColor = DesignTokens.nsAccent
        countPillLabel.alignment = .center
        countPillLabel.wantsLayer = true
        countPillLabel.layer?.cornerRadius = 9

        newBtn.translatesAutoresizingMaskIntoConstraints = false
        newBtn.title = "New"
        newBtn.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New")
        newBtn.imagePosition = .imageLeading
        newBtn.bezelStyle = .rounded
        newBtn.controlSize = .small
        newBtn.target = self
        newBtn.action = #selector(showNewCreationMenu(_:))

        sortPopup.translatesAutoresizingMaskIntoConstraints = false
        sortPopup.controlSize = .small
        sortPopup.bezelStyle = .rounded
        for m in MacLibrarySortMode.allCases { sortPopup.addItem(withTitle: m.title) }
        if let idx = MacLibrarySortMode.allCases.firstIndex(of: MacPreferences.shared.librarySortMode) {
            sortPopup.selectItem(at: idx)
        }
        sortPopup.target = self
        sortPopup.action = #selector(sortModeChanged)

        viewModeSegment.translatesAutoresizingMaskIntoConstraints = false
        viewModeSegment.segmentCount = 2
        viewModeSegment.trackingMode = .selectOne
        viewModeSegment.controlSize = .small
        viewModeSegment.setImage(NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Grid"), forSegment: 0)
        viewModeSegment.setImage(NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "List"), forSegment: 1)
        viewModeSegment.setWidth(28, forSegment: 0)
        viewModeSegment.setWidth(28, forSegment: 1)
        viewModeSegment.selectedSegment = (MacPreferences.shared.libraryDisplayMode == .grid) ? 0 : 1
        viewModeSegment.target = self
        viewModeSegment.action = #selector(viewModeSegmentChanged)

        syncDotView.translatesAutoresizingMaskIntoConstraints = false
        syncDotView.wantsLayer = true
        syncDotView.layer?.cornerRadius = 4
        syncDotView.layer?.backgroundColor = NSColor.systemGray.cgColor

        syncNowBtn.translatesAutoresizingMaskIntoConstraints = false
        syncNowBtn.bezelStyle = .rounded
        syncNowBtn.controlSize = .small
        syncNowBtn.target = self
        syncNowBtn.action = #selector(handleSyncButton)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search documents…"
        searchField.controlSize = .regular
        searchField.delegate = self

        let headerSep = NSBox()
        headerSep.boxType = .separator
        headerSep.translatesAutoresizingMaskIntoConstraints = false

        headerBar.addSubview(sectionTitleLabel)
        headerBar.addSubview(countPillLabel)
        headerBar.addSubview(newBtn)
        headerBar.addSubview(sortPopup)
        headerBar.addSubview(viewModeSegment)
        headerBar.addSubview(syncDotView)
        headerBar.addSubview(syncNowBtn)
        headerBar.addSubview(searchField)
        headerBar.addSubview(headerSep)

        // Grid Cover Shelf (NSCollectionViewFlowLayout)
        let flow = NSCollectionViewFlowLayout()
        flow.itemSize = NSSize(width: 174, height: 222)
        flow.minimumInteritemSpacing = 14
        flow.minimumLineSpacing = 18
        flow.sectionInset = NSEdgeInsets(top: 18, left: 20, bottom: 26, right: 20)
        gridView.collectionViewLayout = flow
        gridView.isSelectable = true
        gridView.allowsMultipleSelection = false
        gridView.backgroundColors = [.clear]
        gridView.register(MacDocumentGridItem.self, forItemWithIdentifier: MacDocumentGridItem.reuseID)
        gridView.dataSource = self
        gridView.delegate = self

        gridScroll.translatesAutoresizingMaskIntoConstraints = false
        gridScroll.documentView = gridView
        gridScroll.hasVerticalScroller = true
        gridScroll.drawsBackground = true
        gridScroll.borderType = .noBorder
        rightPane.addSubview(gridScroll)

        // List View (NSTableView)
        let dCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("doc"))
        dCol.resizingMask = .autoresizingMask
        docTable.addTableColumn(dCol)
        docTable.headerView = nil
        docTable.style = .inset
        docTable.rowHeight = 58
        docTable.usesAlternatingRowBackgroundColors = false
        docTable.gridStyleMask = .solidHorizontalGridLineMask
        docTable.gridColor = DesignTokens.nsHairline
        docTable.dataSource = self
        docTable.delegate = self
        docTable.target = self
        docTable.doubleAction = #selector(tableDoubleClicked)
        docTable.menu = makeTableContextMenu()

        docScroll.translatesAutoresizingMaskIntoConstraints = false
        docScroll.documentView = docTable
        docScroll.hasVerticalScroller = true
        docScroll.drawsBackground = true
        docScroll.borderType = .noBorder
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

        // Polished Studio Empty Card
        emptyCard.translatesAutoresizingMaskIntoConstraints = false
        emptyCard.wantsLayer = true
        emptyCard.layer?.cornerRadius = DesignTokens.radiusLarge
        emptyCard.layer?.borderWidth = 0.8
        rightPane.addSubview(emptyCard)

        emptyIcon.translatesAutoresizingMaskIntoConstraints = false
        emptyIcon.image = NSImage(systemSymbolName: "books.vertical.fill", accessibilityDescription: nil)
        emptyIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .light)
        emptyIcon.contentTintColor = DesignTokens.nsAccent
        emptyCard.addSubview(emptyIcon)

        emptyTitle.translatesAutoresizingMaskIntoConstraints = false
        emptyTitle.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        emptyTitle.alignment = .center
        emptyCard.addSubview(emptyTitle)

        emptySub.translatesAutoresizingMaskIntoConstraints = false
        emptySub.font = NSFont.systemFont(ofSize: 12.5)
        emptySub.textColor = .secondaryLabelColor
        emptySub.alignment = .center
        emptySub.maximumNumberOfLines = 2
        emptySub.preferredMaxLayoutWidth = 340
        emptyCard.addSubview(emptySub)

        emptyChooseBtn.translatesAutoresizingMaskIntoConstraints = false
        emptyChooseBtn.bezelStyle = .rounded
        emptyChooseBtn.controlSize = .large
        emptyChooseBtn.target = self
        emptyChooseBtn.action = #selector(chooseVaultFolder)
        emptyCard.addSubview(emptyChooseBtn)

        NSLayoutConstraint.activate([
            headerBar.topAnchor.constraint(equalTo: rightPane.topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            headerBar.heightAnchor.constraint(equalToConstant: 48),

            sectionTitleLabel.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 18),
            sectionTitleLabel.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            countPillLabel.leadingAnchor.constraint(equalTo: sectionTitleLabel.trailingAnchor, constant: 8),
            countPillLabel.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            countPillLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 26),
            countPillLabel.heightAnchor.constraint(equalToConstant: 18),

            searchField.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -16),
            searchField.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 200),

            viewModeSegment.trailingAnchor.constraint(equalTo: searchField.leadingAnchor, constant: -8),
            viewModeSegment.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            sortPopup.trailingAnchor.constraint(equalTo: viewModeSegment.leadingAnchor, constant: -8),
            sortPopup.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            newBtn.trailingAnchor.constraint(equalTo: sortPopup.leadingAnchor, constant: -8),
            newBtn.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            syncNowBtn.trailingAnchor.constraint(equalTo: newBtn.leadingAnchor, constant: -8),
            syncNowBtn.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            syncDotView.trailingAnchor.constraint(equalTo: syncNowBtn.leadingAnchor, constant: -5),
            syncDotView.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            syncDotView.widthAnchor.constraint(equalToConstant: 8),
            syncDotView.heightAnchor.constraint(equalToConstant: 8),

            countPillLabel.trailingAnchor.constraint(lessThanOrEqualTo: syncDotView.leadingAnchor, constant: -10),

            headerSep.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor),
            headerSep.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor),
            headerSep.bottomAnchor.constraint(equalTo: headerBar.bottomAnchor),

            gridScroll.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            gridScroll.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            gridScroll.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            gridScroll.bottomAnchor.constraint(equalTo: footerSep.topAnchor),

            docScroll.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            docScroll.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            docScroll.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            docScroll.bottomAnchor.constraint(equalTo: footerSep.topAnchor),

            footerSep.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            footerSep.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            footerSep.bottomAnchor.constraint(equalTo: statusFooter.topAnchor, constant: -4),

            statusFooter.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor, constant: 16),
            statusFooter.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor, constant: -16),
            statusFooter.bottomAnchor.constraint(equalTo: rightPane.bottomAnchor, constant: -5),

            emptyCard.centerXAnchor.constraint(equalTo: gridScroll.centerXAnchor),
            emptyCard.centerYAnchor.constraint(equalTo: gridScroll.centerYAnchor),
            emptyCard.widthAnchor.constraint(equalToConstant: 400),

            emptyIcon.topAnchor.constraint(equalTo: emptyCard.topAnchor, constant: 26),
            emptyIcon.centerXAnchor.constraint(equalTo: emptyCard.centerXAnchor),

            emptyTitle.topAnchor.constraint(equalTo: emptyIcon.bottomAnchor, constant: 12),
            emptyTitle.leadingAnchor.constraint(equalTo: emptyCard.leadingAnchor, constant: 20),
            emptyTitle.trailingAnchor.constraint(equalTo: emptyCard.trailingAnchor, constant: -20),

            emptySub.topAnchor.constraint(equalTo: emptyTitle.bottomAnchor, constant: 6),
            emptySub.leadingAnchor.constraint(equalTo: emptyCard.leadingAnchor, constant: 24),
            emptySub.trailingAnchor.constraint(equalTo: emptyCard.trailingAnchor, constant: -24),

            emptyChooseBtn.topAnchor.constraint(equalTo: emptySub.bottomAnchor, constant: 16),
            emptyChooseBtn.centerXAnchor.constraint(equalTo: emptyCard.centerXAnchor),
            emptyChooseBtn.bottomAnchor.constraint(equalTo: emptyCard.bottomAnchor, constant: -24)
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

    func setDisplayMode(_ mode: MacLibraryDisplayMode) {
        MacPreferences.shared.libraryDisplayMode = mode
        viewModeSegment.selectedSegment = (mode == .grid) ? 0 : 1
        applyDisplayMode(animated: true)
    }

    private func applyDisplayMode(animated: Bool) {
        let isGrid = (MacPreferences.shared.libraryDisplayMode == .grid)
        if animated {
            gridScroll.isHidden = !isGrid
            docScroll.isHidden = isGrid
            let target = isGrid ? gridScroll : docScroll
            target.alphaValue = 0.0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                target.animator().alphaValue = 1.0
            }
        } else {
            gridScroll.isHidden = !isGrid
            docScroll.isHidden = isGrid
            gridScroll.alphaValue = 1.0
            docScroll.alphaValue = 1.0
        }
        if isGrid { gridView.reloadData() } else { docTable.reloadData() }
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
        let syncPart = progress.isEmpty ? "Google Drive: \(status)" : progress
        statusFooter.stringValue = "\(countLabel)  ·  \(syncPart)"
        syncNowBtn.title = syncManager.config.isConnected ? "Sync" : "Connect…"
        switch syncManager.visualState {
        case .ok: syncDotView.layer?.backgroundColor = DesignTokens.nsEmerald.cgColor
        case .syncing: syncDotView.layer?.backgroundColor = DesignTokens.nsAccent.cgColor
        case .error: syncDotView.layer?.backgroundColor = DesignTokens.nsCoralRed.cgColor
        case .disconnected: syncDotView.layer?.backgroundColor = NSColor.systemGray.cgColor
        }
    }

    private func currentFolderPath() -> String {
        guard selectedSidebarIndex >= 0 && selectedSidebarIndex < sidebarEntries.count else { return "" }
        if case .folder(let f) = sidebarEntries[selectedSidebarIndex] { return f.relativePath }
        return ""
    }

    private func rebuildSidebarAndList() {
        var annCount = 0
        var jourCount = 0
        for item in vault.pdfs {
            if item.hasInk { annCount += 1 }
            if item.isHobonichi { jourCount += 1 }
        }
        cachedAnnotatedCount = annCount
        cachedJournalCount = jourCount

        var entries: [MacLibrarySidebarEntry] = [
            .header("LIBRARY"),
            .allPDFs,
            .recent,
            .favorites,
            .annotated,
            .journals
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
            sectionTitleLabel.stringValue = "Recent"
            let byRel = Dictionary(uniqueKeysWithValues: vault.pdfs.map { ($0.relativePath, $0) })
            base = vault.recentPaths.compactMap { byRel[$0] }
        case .favorites:
            sectionTitleLabel.stringValue = "Favorites"
            base = vault.pdfs.filter { vault.favoritePaths.contains($0.relativePath) }
        case .annotated:
            sectionTitleLabel.stringValue = "Annotated"
            base = vault.pdfs.filter { $0.hasInk }
        case .journals:
            sectionTitleLabel.stringValue = "Hobonichi Journals"
            base = vault.pdfs.filter { $0.isHobonichi }
        case .folder(let f):
            sectionTitleLabel.stringValue = f.name
            let prefix = f.relativePath + "/"
            base = vault.pdfs.filter { $0.relativeFolder == f.relativePath || $0.relativeFolder.hasPrefix(prefix) }
        default:
            sectionTitleLabel.stringValue = "All Documents"
            base = vault.pdfs
        }

        let matched: [PDFItem] = q.isEmpty ? base : base.filter {
            $0.name.lowercased().contains(q) || $0.relativeFolder.lowercased().contains(q)
        }

        switch MacPreferences.shared.librarySortMode {
        case .date:
            filteredItems = matched.sorted { $0.modifiedAt > $1.modifiedAt }
        case .name:
            filteredItems = matched.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .annotated:
            filteredItems = matched.sorted {
                if $0.hasInk != $1.hasInk { return $0.hasInk && !$1.hasInk }
                return $0.modifiedAt > $1.modifiedAt
            }
        }

        countPillLabel.stringValue = " \(filteredItems.count) "
        if MacPreferences.shared.libraryDisplayMode == .grid {
            gridView.reloadData()
        } else {
            docTable.reloadData()
        }

        let isEmpty = filteredItems.isEmpty
        emptyCard.isHidden = !isEmpty
        emptyChooseBtn.isHidden = (vault.vaultURL != nil)

        if vault.vaultURL == nil {
            emptyTitle.stringValue = "Connect Your Obsidian Vault"
            emptySub.stringValue = "Choose your vault folder to browse PDFs, view iPad notes, and sync with Google Drive."
        } else if !q.isEmpty {
            emptyTitle.stringValue = "No Matches Found"
            emptySub.stringValue = "No PDFs matching \"\(searchField.stringValue)\"."
        } else {
            emptyTitle.stringValue = "No Documents Here"
            emptySub.stringValue = "Click + New to create a notebook, journal, or import a PDF."
        }
        updateFooterAndSyncUI(status: syncManager.statusText, progress: syncManager.syncProgressText)
    }

    // MARK: - Actions (+ New Creation, Sort, View Mode, Vault, Context Menu)

    @objc private func showNewCreationMenu(_ sender: NSButton) {
        let m = NSMenu()
        m.addItem(withTitle: "New Ruled Notebook…", action: #selector(createNotebookAction), keyEquivalent: "")
        m.addItem(withTitle: "New Hobonichi Journal…", action: #selector(createJournalAction), keyEquivalent: "")
        m.addItem(withTitle: "New Folder…", action: #selector(createFolderAction), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Import PDF into Vault…", action: #selector(importPDFAction), keyEquivalent: "")
        for item in m.items { item.target = self }
        let pt = NSPoint(x: 0, y: sender.bounds.height + 4)
        m.popUp(positioning: nil, at: pt, in: sender)
    }

    @objc private func createNotebookAction() {
        guard vault.vaultURL != nil else { chooseVaultFolder(); return }
        let alert = NSAlert()
        alert.messageText = "New Notebook"
        alert.informativeText = "Creates a fresh ruled PDF notebook in your vault."
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        tf.stringValue = "Untitled Notebook"
        alert.accessoryView = tf
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let title = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let res = try? vault.createNotebook(title: title.isEmpty ? "Untitled Notebook" : title, template: .lined, coverID: 0, inFolder: currentFolderPath()) {
                syncManager.uploadNewBookToDrive(pdfURL: res.url, relativePath: res.relPath)
                let item = PDFItem(id: res.url.standardizedFileURL.path, url: res.url, name: res.url.deletingPathExtension().lastPathComponent, relativeFolder: currentFolderPath(), relativePath: res.relPath, modifiedAt: Date(), hasInk: false, isHobonichi: false)
                onOpenPDF?(item)
            }
        }
    }

    @objc private func createJournalAction() {
        guard vault.vaultURL != nil else { chooseVaultFolder(); return }
        let year = Calendar.current.component(.year, from: Date())
        let alert = NSAlert()
        alert.messageText = "New Hobonichi Techo Weeks"
        alert.informativeText = "Creates a 12-week Hobonichi journal compatible with iPad & Obsidian."
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        tf.stringValue = "\(year) Hobonichi Weeks"
        alert.accessoryView = tf
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let title = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let res = try? vault.createHobonichiJournal(title: title.isEmpty ? "\(year) Hobonichi Weeks" : title, coverID: 100, startMode: "month", initialWeeks: 12, inFolder: "Journals") {
                syncManager.uploadNewBookToDrive(pdfURL: res.url, relativePath: res.relPath)
                let item = PDFItem(id: res.url.standardizedFileURL.path, url: res.url, name: res.url.deletingPathExtension().lastPathComponent, relativeFolder: "Journals", relativePath: res.relPath, modifiedAt: Date(), hasInk: true, isHobonichi: true)
                onOpenPDF?(item)
            }
        }
    }

    @objc private func createFolderAction() {
        guard vault.vaultURL != nil else { chooseVaultFolder(); return }
        let alert = NSAlert()
        alert.messageText = "New Folder"
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        tf.placeholderString = "Folder name"
        alert.accessoryView = tf
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            try? vault.createFolder(name: tf.stringValue, inFolder: currentFolderPath())
        }
    }

    @objc private func importPDFAction() {
        guard vault.vaultURL != nil else { chooseVaultFolder(); return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            for url in panel.urls {
                if let res = try? vault.importPDFCopy(from: url, intoFolder: currentFolderPath()) {
                    syncManager.uploadNewBookToDrive(pdfURL: res.url, relativePath: res.relPath)
                }
            }
        }
    }

    @objc private func sortModeChanged() {
        let idx = max(0, min(MacLibrarySortMode.allCases.count - 1, sortPopup.indexOfSelectedItem))
        MacPreferences.shared.librarySortMode = MacLibrarySortMode.allCases[idx]
        rebuildFilteredList()
    }

    @objc private func viewModeSegmentChanged() {
        let mode: MacLibraryDisplayMode = (viewModeSegment.selectedSegment == 0) ? .grid : .list
        setDisplayMode(mode)
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
        openPDFItem(filteredItems[row])
    }

    private func openPDFItem(_ item: PDFItem) {
        vault.recordRecentlyOpened(item.relativePath)
        onOpenPDF?(item)
    }

    private var activeContextItem: PDFItem?

    private func makeMenu(for item: PDFItem) -> NSMenu {
        activeContextItem = item
        let m = NSMenu()
        m.addItem(withTitle: "Open in Tab", action: #selector(ctxOpenPDF), keyEquivalent: "")
        m.addItem(withTitle: vault.isFavorite(item.relativePath) ? "Remove Favorite" : "Add to Favorites", action: #selector(ctxToggleFavorite), keyEquivalent: "")
        m.addItem(withTitle: "Cycle Cover Color", action: #selector(ctxCycleColor), keyEquivalent: "")
        m.addItem(withTitle: "Show in Finder", action: #selector(ctxRevealInFinder), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Duplicate", action: #selector(ctxDuplicatePDF), keyEquivalent: "")
        m.addItem(withTitle: "Rename…", action: #selector(ctxRenamePDF), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Move to Trash", action: #selector(ctxDeletePDF), keyEquivalent: "")
        for mi in m.items { mi.target = self }
        return m
    }

    private func makeTableContextMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(withTitle: "Open in Tab", action: #selector(ctxOpenPDF), keyEquivalent: "")
        m.addItem(withTitle: "Toggle Favorite", action: #selector(ctxToggleFavorite), keyEquivalent: "")
        m.addItem(withTitle: "Cycle Cover Color", action: #selector(ctxCycleColor), keyEquivalent: "")
        m.addItem(withTitle: "Show in Finder", action: #selector(ctxRevealInFinder), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Duplicate", action: #selector(ctxDuplicatePDF), keyEquivalent: "")
        m.addItem(withTitle: "Rename…", action: #selector(ctxRenamePDF), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Move to Trash", action: #selector(ctxDeletePDF), keyEquivalent: "")
        for mi in m.items { mi.target = self }
        return m
    }

    private func resolveContextItem() -> PDFItem? {
        if MacPreferences.shared.libraryDisplayMode == .grid, let item = activeContextItem {
            return item
        }
        let row = docTable.clickedRow >= 0 ? docTable.clickedRow : docTable.selectedRow
        guard row >= 0, row < filteredItems.count else { return activeContextItem }
        return filteredItems[row]
    }

    @objc private func ctxOpenPDF() {
        guard let item = resolveContextItem() else { return }
        openPDFItem(item)
    }

    @objc private func ctxToggleFavorite() {
        guard let item = resolveContextItem() else { return }
        vault.toggleFavorite(item.relativePath)
        rebuildFilteredList()
    }

    @objc private func ctxCycleColor() {
        guard let item = resolveContextItem() else { return }
        vault.cycleCoverColor(for: item)
        rebuildFilteredList()
    }

    @objc private func ctxDuplicatePDF() {
        guard let item = resolveContextItem() else { return }
        try? vault.duplicatePDF(item)
    }

    @objc private func ctxRevealInFinder() {
        guard let item = resolveContextItem() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    @objc private func ctxRenamePDF() {
        guard let item = resolveContextItem() else { return }
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
        guard let item = resolveContextItem() else { return }
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

    // MARK: - NSCollectionViewDataSource & Delegate (Grid Cover Shelf)

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        filteredItems.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let itemView = collectionView.makeItem(withIdentifier: MacDocumentGridItem.reuseID, for: indexPath)
        guard let card = itemView as? MacDocumentGridItem, indexPath.item < filteredItems.count else {
            return itemView
        }
        let pdf = filteredItems[indexPath.item]
        card.configure(
            item: pdf,
            isFavorite: vault.isFavorite(pdf.relativePath),
            dateString: dateFormatter.string(from: pdf.modifiedAt),
            vault: vault
        )
        card.onOpen = { [weak self] item in
            self?.openPDFItem(item)
        }
        card.contextMenuProvider = { [weak self] item in
            self?.makeMenu(for: item) ?? NSMenu()
        }
        return card
    }

    // MARK: - NSTableViewDataSource & Delegate (Sidebar + List View)

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
                    tf.font = NSFont.systemFont(ofSize: 10, weight: .bold)
                    tf.textColor = .tertiaryLabelColor
                    c.addSubview(tf)
                    c.textField = tf
                    NSLayoutConstraint.activate([
                        tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 8),
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
                tf.font = NSFont.systemFont(ofSize: 13, weight: .medium)
                tf.lineBreakMode = .byTruncatingTail
                c.addSubview(tf)
                c.textField = tf
                let cnt = NSTextField(labelWithString: "")
                cnt.translatesAutoresizingMaskIntoConstraints = false
                cnt.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
                cnt.textColor = .tertiaryLabelColor
                cnt.alignment = .right
                cnt.tag = 77
                c.addSubview(cnt)
                NSLayoutConstraint.activate([
                    iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 6),
                    iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                    iv.widthAnchor.constraint(equalToConstant: 16),
                    iv.heightAnchor.constraint(equalToConstant: 16),
                    tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 8),
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
                cell.imageView?.image = Self.iconBooks
                cell.imageView?.contentTintColor = DesignTokens.nsAccent
                cell.textField?.stringValue = "All Documents"
                cntLabel?.stringValue = "\(vault.pdfs.count)"
            case .recent:
                cell.imageView?.image = Self.iconClock
                cell.imageView?.contentTintColor = .systemBlue
                cell.textField?.stringValue = "Recent"
                cntLabel?.stringValue = "\(vault.recentPaths.count)"
            case .favorites:
                cell.imageView?.image = Self.iconStar
                cell.imageView?.contentTintColor = DesignTokens.nsWarmGold
                cell.textField?.stringValue = "Favorites"
                cntLabel?.stringValue = "\(vault.favoritePaths.count)"
            case .annotated:
                cell.imageView?.image = Self.iconHighlighter
                cell.imageView?.contentTintColor = .systemPurple
                cell.textField?.stringValue = "Annotated"
                cntLabel?.stringValue = "\(cachedAnnotatedCount)"
            case .journals:
                cell.imageView?.image = Self.iconCalendar
                cell.imageView?.contentTintColor = DesignTokens.nsWarmGold
                cell.textField?.stringValue = "Journals"
                cntLabel?.stringValue = "\(cachedJournalCount)"
            case .folder(let f):
                cell.imageView?.image = Self.iconFolder
                cell.imageView?.contentTintColor = Self.folderTint
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
            dateString: listDateFormatter.string(from: item.modifiedAt),
            vault: vault
        )
        return cell
    }
}
