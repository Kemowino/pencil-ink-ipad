import SwiftUI

private enum ToolPopoverKind: Equatable, Identifiable {
    case pen
    case highlighter
    case eraser
    case text
    case laser
    case jumpPage
    case sync
    case editColor(tool: DrawingTool, index: Int)
    case addColor(tool: DrawingTool)
    case editThickness(tool: DrawingTool, index: Int)

    var id: String {
        switch self {
        case .pen: return "pen"
        case .highlighter: return "highlighter"
        case .eraser: return "eraser"
        case .text: return "text"
        case .laser: return "laser"
        case .jumpPage: return "jumpPage"
        case .sync: return "sync"
        case .editColor(let t, let i): return "editColor-\(t.rawValue)-\(i)"
        case .addColor(let t): return "addColor-\(t.rawValue)"
        case .editThickness(let t, let i): return "editThick-\(t.rawValue)-\(i)"
        }
    }
}

struct NotebookScreen: View {
    let tab: OpenDocumentTab
    let isActive: Bool
    let showHomeButtonInBar: Bool

    @EnvironmentObject var vault: VaultManager
    @EnvironmentObject var syncManager: DriveSyncManager
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var palette: ToolPaletteStore
    @ObservedObject private var toolState: NotebookToolState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var activePopover: ToolPopoverKind? = nil
    @State private var showPageOverview = false
    @State private var openOverviewInSearch = false
    @State private var showSyncSettings = false
    @State private var showAppSettings = false
    @State private var jumpPageInput: String = ""
    @State private var showRenameAlert = false
    @State private var renameDraft: String = ""
    @State private var addColorDraft: Color = Color(red: 0.0, green: 0.48, blue: 1.0)

    init(tab: OpenDocumentTab, isActive: Bool, showHomeButtonInBar: Bool) {
        self.tab = tab
        self.isActive = isActive
        self.showHomeButtonInBar = showHomeButtonInBar
        self._toolState = ObservedObject(wrappedValue: tab.toolState)
    }

    private var controllerBox: PDFNotebookRepresentable.ControllerBox {
        tab.controllerBox
    }

    private var primaryBarBg: Color {
        colorScheme == .dark
            ? Color(red: 0.135, green: 0.140, blue: 0.156)
            : Color.white
    }

    private var secondaryBarBg: Color {
        colorScheme == .dark
            ? Color(red: 0.115, green: 0.120, blue: 0.135)
            : Color(red: 0.975, green: 0.978, blue: 0.986)
    }

    private var hairlineColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.10)
    }

    private var floatingPillBg: Color {
        colorScheme == .dark
            ? Color(red: 0.145, green: 0.150, blue: 0.168).opacity(0.96)
            : Color.white.opacity(0.96)
    }

    #if targetEnvironment(macCatalyst)
    private let primaryBarHeight: CGFloat = 54
    private let primaryIconFont: CGFloat = 20
    private let primaryIconFrame: CGFloat = 44
    private let docTitleFont: CGFloat = 17
    private var topToolBarHeight: CGFloat { settings.compactToolbar ? 50 : 58 }
    private var sideRailWidth: CGFloat { settings.compactToolbar ? 58 : 66 }
    private let toolSlotFrame: CGFloat = 44
    private let toolIconCanvas: CGFloat = 26
    private let swatchInnerSize: CGFloat = 26
    private let swatchRingSize: CGFloat = 33
    private let swatchHitFrame: CGFloat = 36
    private let pagePillFont: CGFloat = 13.5
    #else
    private let primaryBarHeight: CGFloat = 44
    private var primaryIconFont: CGFloat { horizontalSizeClass == .compact ? 15.0 : 16.5 }
    private var primaryIconFrame: CGFloat { horizontalSizeClass == .compact ? 30 : 36 }
    private var docTitleFont: CGFloat { horizontalSizeClass == .compact ? 13.0 : 14.0 }
    private var topToolBarHeight: CGFloat { settings.compactToolbar ? 42 : 48 }
    private var sideRailWidth: CGFloat { settings.compactToolbar ? 48 : 54 }
    private let toolSlotFrame: CGFloat = 36
    private let toolIconCanvas: CGFloat = 22
    private let swatchInnerSize: CGFloat = 22
    private let swatchRingSize: CGFloat = 28
    private let swatchHitFrame: CGFloat = 30
    private let pagePillFont: CGFloat = 11.5
    #endif

    var body: some View {
        VStack(spacing: 0) {
            // Row 1: Goodnotes Primary Document Bar
            goodnotesPrimaryBar

            Rectangle()
                .fill(hairlineColor)
                .frame(height: 0.5)

            // Optional Top Drawing Tool Bar (Goodnotes mode)
            if settings.toolbarPosition == .top {
                goodnotesTopToolBar
                Rectangle()
                    .fill(hairlineColor)
                    .frame(height: 0.5)
            }

            // Optional Hobonichi Ribbon Strip (observes isolated HUD state)
            if toolState.isHobonichi {
                HobonichiRibbonBar(
                    hud: toolState.hud,
                    secondaryBarBg: secondaryBarBg,
                    controllerBox: controllerBox
                )
                Rectangle()
                    .fill(hairlineColor)
                    .frame(height: 0.5)
            }

            // Main Workspace: Optional Left/Right Noteshelf-style Vertical Toolbar + PDF Canvas
            HStack(spacing: 0) {
                if settings.toolbarPosition == .left {
                    verticalSideToolBar
                    Rectangle()
                        .fill(hairlineColor)
                        .frame(width: 0.5)
                }

                canvasWorkspace

                if settings.toolbarPosition == .right {
                    Rectangle()
                        .fill(hairlineColor)
                        .frame(width: 0.5)
                    verticalSideToolBar
                }
            }
        }
        .background(
            Button("") {
                if isActive {
                    controllerBox.vc?.commitActiveTextBox()
                    openOverviewInSearch = true
                    showPageOverview = true
                }
            }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
            .allowsHitTesting(false)
        )
        .alert("Rename Document", isPresented: $showRenameAlert) {
            TextField("Document title", text: $renameDraft)
            Button("Rename") {
                performDocumentRename()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Renames the PDF locally and updates its name on Google Drive & synced devices.")
        }
        .sheet(isPresented: $showPageOverview) {
            PageOverviewSheet(
                toolState: toolState,
                controllerBox: controllerBox,
                startInSearch: openOverviewInSearch
            )
            .preferredColorScheme(settings.appTheme.preferredColorScheme)
        }
        .sheet(isPresented: $showSyncSettings) {
            DriveSyncSettingsSheet(syncManager: syncManager, vault: vault)
                .preferredColorScheme(settings.appTheme.preferredColorScheme)
                .onDisappear {
                    controllerBox.vc?.startLiveDriveSync()
                }
        }
        .sheet(isPresented: $showAppSettings) {
            SettingsSheet()
                .preferredColorScheme(settings.appTheme.preferredColorScheme)
        }
        .onChange(of: settings.hiddenTools) { _ in
            if !settings.isToolVisible(toolState.tool),
               let fallback = settings.orderedVisibleTools.first {
                selectTool(fallback)
            }
        }
    }

    private func performDocumentRename() {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != tab.title else { return }
        controllerBox.vc?.saveSynchronouslyBeforeRename()

        let oldRel = tab.relativePath
        do {
            if let renamed = try vault.renamePDF(at: tab.url, oldRelativePath: oldRel, newTitle: trimmed) {
                tabManager.handleRenamedDocument(
                    oldRelativePath: oldRel,
                    newURL: renamed.url,
                    newRelativePath: renamed.relPath,
                    newTitle: renamed.title
                )
                let newRel = renamed.relPath
                Task {
                    let synced = await syncManager.renameBookOnDrive(oldRelativePath: oldRel, newRelativePath: newRel)
                    if synced {
                        tabManager.activeTab?.toolState.showToast("Renamed & synced to Drive")
                    } else {
                        tabManager.activeTab?.toolState.showToast("Renamed to \(renamed.title)")
                    }
                }
            }
        } catch {
            toolState.showToast(error.localizedDescription)
        }
    }

    private var canvasWorkspace: some View {
        ZStack {
            PDFNotebookRepresentable(
                pdfURL: tab.url,
                relativePath: tab.relativePath,
                toolState: toolState,
                syncManager: syncManager,
                isActive: isActive,
                controllerBox: controllerBox
            )
            .ignoresSafeArea(edges: .bottom)

            VStack(spacing: 10) {
                if toolState.hasLassoSelection {
                    lassoActionBar
                        .padding(.top, 10)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if toolState.hasActiveTextBox {
                    textBoxActionBar
                        .padding(.top, toolState.hasLassoSelection ? 0 : 10)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                NotebookFloatingHUD(
                    hud: toolState.hud,
                    isHobonichi: toolState.isHobonichi,
                    hasTopActionBar: toolState.hasLassoSelection || toolState.hasActiveTextBox,
                    pagePillFont: pagePillFont,
                    hairlineColor: hairlineColor,
                    floatingPillBg: floatingPillBg,
                    onTapPagePill: {
                        jumpPageInput = "\(toolState.currentPage)"
                        activePopover = .jumpPage
                        Haptics.selection()
                    },
                    jumpPopoverPresented: Binding(
                        get: { activePopover == .jumpPage },
                        set: { if !$0 { activePopover = nil } }
                    ),
                    jumpPopoverContent: { jumpPagePopover }
                )
            }
            .animation(.easeOut(duration: 0.18), value: toolState.hasLassoSelection)
            .animation(.easeOut(duration: 0.18), value: toolState.hasActiveTextBox)
        }
    }

    private func selectTool(_ t: DrawingTool) {
        if toolState.tool != t {
            toolState.previousTool = toolState.tool
        }
        toolState.tool = t
        controllerBox.vc?.onToolChanged(to: t)
        Haptics.selection()
    }

    // MARK: - Row 1: Goodnotes Primary Navigation & Document Bar

    private var goodnotesPrimaryBar: some View {
        HStack(spacing: 4) {
            HStack(spacing: 2) {
                if showHomeButtonInBar {
                    barIconButton(systemName: "house") {
                        controllerBox.vc?.saveNow(flushDriveImmediately: true)
                        tabManager.showLibrary()
                    }
                }

                barIconButton(systemName: "square.grid.2x2") {
                    controllerBox.vc?.commitActiveTextBox()
                    controllerBox.vc?.clearLassoSelection(commitFirst: true)
                    openOverviewInSearch = false
                    Haptics.light()
                    showPageOverview = true
                }

                barIconButton(systemName: "magnifyingglass") {
                    controllerBox.vc?.commitActiveTextBox()
                    controllerBox.vc?.clearLassoSelection(commitFirst: true)
                    openOverviewInSearch = true
                    Haptics.light()
                    showPageOverview = true
                }

                BookmarkToolbarButton(
                    hud: toolState.hud,
                    iconFont: primaryIconFont,
                    iconFrame: primaryIconFrame
                ) {
                    controllerBox.vc?.toggleBookmarkForCurrentPage()
                    Haptics.light()
                }

                Menu {
                    Button {
                        controllerBox.vc?.exportCurrentPagePNG()
                    } label: {
                        Label("Export This Page (Image)", systemImage: "photo")
                    }
                    Button {
                        controllerBox.vc?.exportAnnotatedPDF()
                    } label: {
                        Label("Export All Pages (PDF)", systemImage: "doc.richtext")
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: primaryIconFont, weight: .regular))
                        .foregroundColor(.primary.opacity(0.84))
                        .frame(width: primaryIconFrame, height: primaryIconFrame)
                }
            }

            Spacer(minLength: 8)

            // Center: Iconic Goodnotes Document Title + Chevron Menu (Rename + Go to Page!)
            Menu {
                Button {
                    renameDraft = tab.title
                    showRenameAlert = true
                } label: {
                    Label("Rename Document…", systemImage: "pencil")
                }

                Button {
                    jumpPageInput = "\(toolState.currentPage)"
                    activePopover = .jumpPage
                } label: {
                    Label("Go to Page…", systemImage: "number.square")
                }
            } label: {
                HStack(spacing: 4) {
                    Text(tab.title)
                        .font(.system(size: docTitleFont, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: docTitleFont * 0.68, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: 280)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                barIconButton(systemName: "arrow.uturn.backward", disabled: !toolState.canUndo) {
                    controllerBox.vc?.performUndo()
                    Haptics.light()
                }

                barIconButton(systemName: "arrow.uturn.forward", disabled: !toolState.canRedo) {
                    controllerBox.vc?.performRedo()
                    Haptics.light()
                }

                Menu {
                    Section("Add Page After Current") {
                        ForEach(PaperTemplate.allCases) { tpl in
                            Button {
                                controllerBox.vc?.insertBlankPage(after: toolState.currentPage - 1, template: tpl)
                                Haptics.light()
                            } label: {
                                Label(tpl.title + " Page", systemImage: "doc.badge.plus")
                            }
                        }
                    }
                    Divider()
                    Button {
                        controllerBox.vc?.duplicatePage(at: toolState.currentPage - 1)
                        Haptics.light()
                    } label: {
                        Label("Duplicate Current Page", systemImage: "doc.on.doc")
                    }
                } label: {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: primaryIconFont, weight: .regular))
                        .foregroundColor(.primary.opacity(0.84))
                        .frame(width: primaryIconFrame, height: primaryIconFrame)
                }

                SyncStatusDotButton(syncManager: syncManager) {
                    activePopover = .sync
                    Haptics.selection()
                }
                .popover(isPresented: Binding(
                    get: { activePopover == .sync },
                    set: { if !$0 { activePopover = nil } }
                )) {
                    SyncStatusPopoverView(
                        syncManager: syncManager,
                        onSyncNow: {
                            controllerBox.vc?.commitActiveTextBox()
                            controllerBox.vc?.saveNow(flushDriveImmediately: false)
                            controllerBox.vc?.syncNowWithDrive(silent: false, forceFolderScan: true)
                        },
                        onOpenSettings: {
                            activePopover = nil
                            showSyncSettings = true
                        }
                    )
                }

                Menu {
                    Menu {
                        ForEach(PDFReadingMode.allCases) { mode in
                            Button {
                                settings.pdfReadingMode = mode
                                Haptics.selection()
                            } label: {
                                if settings.pdfReadingMode == mode {
                                    Label(mode.title, systemImage: "checkmark")
                                } else {
                                    Label(mode.title, systemImage: mode.systemImage)
                                }
                            }
                        }
                    } label: {
                        Label("Paper Mode (\(settings.pdfReadingMode.title))", systemImage: settings.pdfReadingMode.systemImage)
                    }

                    Menu {
                        ForEach(ToolbarPosition.allCases) { pos in
                            Button {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                                    settings.toolbarPosition = pos
                                }
                                Haptics.selection()
                            } label: {
                                if settings.toolbarPosition == pos {
                                    Label(pos.title, systemImage: "checkmark")
                                } else {
                                    Text(pos.title)
                                }
                            }
                        }
                    } label: {
                        Label("Toolbar Position", systemImage: "sidebar.left")
                    }

                    Button {
                        jumpPageInput = "\(toolState.currentPage)"
                        activePopover = .jumpPage
                    } label: {
                        Label("Go to Page…", systemImage: "number.square")
                    }

                    Button {
                        controllerBox.vc?.resetZoom()
                    } label: {
                        Label("Fit Page to Width", systemImage: "arrow.up.left.and.arrow.down.right")
                    }

                    Divider()

                    Button {
                        showAppSettings = true
                    } label: {
                        Label("Customize Toolbar & Settings…", systemImage: "gearshape")
                    }

                    Divider()

                    Button(role: .destructive) {
                        controllerBox.vc?.clearCurrentPageStrokes()
                        Haptics.light()
                    } label: {
                        Label("Clear Page", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: primaryIconFont, weight: .medium))
                        .foregroundColor(.primary.opacity(0.84))
                        .frame(width: primaryIconFrame, height: primaryIconFrame)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: primaryBarHeight)
        .background(primaryBarBg)
    }

    // MARK: - Horizontal Goodnotes Tool Bar (Top Position)

    private var goodnotesTopToolBar: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    HStack(spacing: 7) {
                        enabledToolButtons
                    }

                    if toolState.tool != .hand {
                        Rectangle()
                            .fill(hairlineColor)
                            .frame(width: 1, height: 22)

                        contextualSlotsHorizontal
                    } else {
                        Rectangle()
                            .fill(hairlineColor)
                            .frame(width: 1, height: 22)
                        Text("Scroll & Read Mode")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .frame(minWidth: geo.size.width, minHeight: geo.size.height)
            }
        }
        .frame(height: topToolBarHeight)
        .background(secondaryBarBg)
    }

    // MARK: - Vertical Noteshelf-Style Side Tool Bar (Left / Right Position)

    private var verticalSideToolBar: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 10) {
                VStack(spacing: 6) {
                    enabledToolButtons
                }

                if toolState.tool != .hand {
                    Rectangle()
                        .fill(hairlineColor)
                        .frame(width: 26, height: 1)

                    contextualSlotsVertical
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
        .frame(width: sideRailWidth)
        .background(secondaryBarBg)
    }

    // MARK: - Enabled Tool Buttons (Shared Between Horizontal & Vertical Toolbars)

    @ViewBuilder
    private var enabledToolButtons: some View {
        ForEach(settings.orderedVisibleTools) { tool in
            toolButtonView(for: tool)
        }
    }

    @ViewBuilder
    private func toolButtonView(for tool: DrawingTool) -> some View {
        switch tool {
        case .hand:
            toolSlotButton(active: toolState.tool == .hand, accent: .blue) {
                GoodnotesHandIcon(isActive: toolState.tool == .hand, isDark: colorScheme == .dark)
            } action: {
                selectTool(.hand)
            }

        case .pen:
            toolSlotButton(active: toolState.tool == .pen, accent: .blue) {
                GoodnotesPenIcon(
                    inkColor: Color(UIColor(hex: palette.activePenColorHex)),
                    isActive: toolState.tool == .pen,
                    isDark: colorScheme == .dark
                )
                .frame(width: toolIconCanvas, height: toolIconCanvas)
            } action: {
                if toolState.tool == .pen { activePopover = .pen }
                else { selectTool(.pen) }
            }
            .popover(isPresented: Binding(
                get: { activePopover == .pen },
                set: { if !$0 { activePopover = nil } }
            )) { penSettingsPopover }

        case .eraser:
            toolSlotButton(active: toolState.tool == .eraser, accent: .blue) {
                GoodnotesEraserIcon(isActive: toolState.tool == .eraser, isDark: colorScheme == .dark)
                    .frame(width: toolIconCanvas, height: toolIconCanvas)
            } action: {
                if toolState.tool == .eraser { activePopover = .eraser }
                else { selectTool(.eraser) }
            }
            .popover(isPresented: Binding(
                get: { activePopover == .eraser },
                set: { if !$0 { activePopover = nil } }
            )) { eraserSettingsPopover }

        case .highlighter:
            toolSlotButton(active: toolState.tool == .highlighter, accent: .blue) {
                GoodnotesHighlighterIcon(
                    accentColor: Color(UIColor(hex: palette.activeHlColorHex)),
                    isActive: toolState.tool == .highlighter,
                    isDark: colorScheme == .dark
                )
                .frame(width: toolIconCanvas, height: toolIconCanvas)
            } action: {
                if toolState.tool == .highlighter { activePopover = .highlighter }
                else { selectTool(.highlighter) }
            }
            .popover(isPresented: Binding(
                get: { activePopover == .highlighter },
                set: { if !$0 { activePopover = nil } }
            )) { highlighterSettingsPopover }

        case .lasso:
            toolSlotButton(active: toolState.tool == .lasso, accent: .blue) {
                GoodnotesLassoIcon(isActive: toolState.tool == .lasso, isDark: colorScheme == .dark)
                    .frame(width: toolIconCanvas, height: toolIconCanvas)
            } action: {
                selectTool(.lasso)
            }

        case .text:
            toolSlotButton(active: toolState.tool == .text, accent: .blue) {
                GoodnotesTextIcon(isActive: toolState.tool == .text, isDark: colorScheme == .dark)
                    .frame(width: toolIconCanvas, height: toolIconCanvas)
            } action: {
                if toolState.tool == .text { activePopover = .text }
                else { selectTool(.text) }
            }
            .popover(isPresented: Binding(
                get: { activePopover == .text },
                set: { if !$0 { activePopover = nil } }
            )) { textSettingsPopover }

        case .laser:
            toolSlotButton(active: toolState.tool == .laser, accent: .red) {
                GoodnotesLaserIcon(
                    laserColor: Color(UIColor(hex: palette.activeLaserColorHex)),
                    isActive: toolState.tool == .laser,
                    isDark: colorScheme == .dark
                )
                .frame(width: toolIconCanvas, height: toolIconCanvas)
            } action: {
                if toolState.tool == .laser { activePopover = .laser }
                else { selectTool(.laser) }
            }
            .popover(isPresented: Binding(
                get: { activePopover == .laser },
                set: { if !$0 { activePopover = nil } }
            )) { laserSettingsPopover }
        }
    }

    // MARK: - Contextual Swatches (+ Add Color & Tap-to-Edit) + Goodnotes 3-Circle Thickness Slots

    @ViewBuilder
    private var contextualSlotsHorizontal: some View {
        switch toolState.tool {
        case .hand:
            EmptyView()

        case .pen:
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    penColorSwatches
                    addColorButton(for: .pen)
                }
                Rectangle().fill(hairlineColor).frame(width: 1, height: 20)
                HStack(spacing: 5) {
                    penThicknessCircles
                }
            }

        case .highlighter:
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    hlColorSwatches
                    addColorButton(for: .highlighter)
                }
                Rectangle().fill(hairlineColor).frame(width: 1, height: 20)
                HStack(spacing: 5) {
                    hlThicknessCircles
                }
                Rectangle().fill(hairlineColor).frame(width: 1, height: 20)
                straightHighlighterToggleButton
            }

        case .eraser:
            HStack(spacing: 10) {
                Picker("Mode", selection: $palette.eraserMode) {
                    ForEach(EraserModeOption.allCases) { m in
                        Text(m.title).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 128)
                Rectangle().fill(hairlineColor).frame(width: 1, height: 20)
                HStack(spacing: 5) {
                    eraserThicknessCircles
                }
            }

        case .lasso:
            Text(toolState.hasLassoSelection
                 ? "\(toolState.lassoSelectedCount) selected · drag, scale, or rotate"
                 : (toolState.hasLassoClipboard ? "Circle strokes or tap page to paste" : "Circle handwriting to select"))
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(.secondary)

        case .text:
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    textColorSwatches
                    addColorButton(for: .text)
                }
                Rectangle().fill(hairlineColor).frame(width: 1, height: 20)
                textSizeStepperHorizontal
                Rectangle().fill(hairlineColor).frame(width: 1, height: 20)
                textBoldButton
            }

        case .laser:
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    laserColorSwatches
                    addColorButton(for: .laser)
                }
                Rectangle().fill(hairlineColor).frame(width: 1, height: 20)
                Picker("Laser", selection: $palette.laserTrail) {
                    Text("Dot").tag(false)
                    Text("Trail").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 112)
            }
        }
    }

    @ViewBuilder
    private var contextualSlotsVertical: some View {
        switch toolState.tool {
        case .hand:
            EmptyView()

        case .pen:
            VStack(spacing: 8) {
                VStack(spacing: 6) {
                    penColorSwatches
                    addColorButton(for: .pen)
                }
                Rectangle().fill(hairlineColor).frame(width: 24, height: 1)
                VStack(spacing: 5) {
                    penThicknessCircles
                }
            }

        case .highlighter:
            VStack(spacing: 8) {
                VStack(spacing: 6) {
                    hlColorSwatches
                    addColorButton(for: .highlighter)
                }
                Rectangle().fill(hairlineColor).frame(width: 24, height: 1)
                VStack(spacing: 5) {
                    hlThicknessCircles
                }
                Rectangle().fill(hairlineColor).frame(width: 24, height: 1)
                straightHighlighterToggleButton
            }

        case .eraser:
            VStack(spacing: 8) {
                Button {
                    palette.eraserMode = (palette.eraserMode == .stroke) ? .pixel : .stroke
                    Haptics.selection()
                    toolState.showToast("Eraser: \(palette.eraserMode.title)")
                } label: {
                    Text(palette.eraserMode == .stroke ? "Str" : "Pxl")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.accentColor)
                        .frame(width: 34, height: 26)
                        .background(Color.accentColor.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                Rectangle().fill(hairlineColor).frame(width: 24, height: 1)
                VStack(spacing: 5) {
                    eraserThicknessCircles
                }
            }

        case .lasso:
            Image(systemName: "hand.draw")
                .font(.system(size: 15))
                .foregroundColor(.secondary)

        case .text:
            VStack(spacing: 8) {
                VStack(spacing: 6) {
                    textColorSwatches
                    addColorButton(for: .text)
                }
                Rectangle().fill(hairlineColor).frame(width: 24, height: 1)
                Button {
                    activePopover = .text
                } label: {
                    Text("\(Int(palette.textSize))")
                        .font(.system(size: 12, weight: .bold))
                        .monospacedDigit()
                        .foregroundColor(.primary)
                        .frame(width: 32, height: 26)
                        .background(Color.primary.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                textBoldButton
            }

        case .laser:
            VStack(spacing: 8) {
                VStack(spacing: 6) {
                    laserColorSwatches
                    addColorButton(for: .laser)
                }
                Rectangle().fill(hairlineColor).frame(width: 24, height: 1)
                Button {
                    palette.laserTrail.toggle()
                    Haptics.selection()
                } label: {
                    Text(palette.laserTrail ? "Trl" : "Dot")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(palette.laserTrail ? .white : .primary)
                        .frame(width: 34, height: 26)
                        .background(palette.laserTrail ? Color.red : Color.primary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Dynamic Color Swatch Loops (Tap Unselected -> Pick, Tap Selected -> Edit / Remove)

    private var penColorSwatches: some View {
        ForEach(Array(palette.penColors.enumerated()), id: \.offset) { idx, hex in
            colorSwatch(hex: hex, selected: palette.penColorIndex == idx) {
                if palette.penColorIndex == idx {
                    activePopover = .editColor(tool: .pen, index: idx)
                } else {
                    palette.penColorIndex = idx
                    Haptics.selection()
                }
            }
            .popover(isPresented: Binding(
                get: { activePopover == .editColor(tool: .pen, index: idx) },
                set: { if !$0 { activePopover = nil } }
            )) {
                editColorPopover(tool: .pen, index: idx)
            }
        }
    }

    private var hlColorSwatches: some View {
        ForEach(Array(palette.hlColors.enumerated()), id: \.offset) { idx, hex in
            colorSwatch(hex: hex, selected: palette.hlColorIndex == idx) {
                if palette.hlColorIndex == idx {
                    activePopover = .editColor(tool: .highlighter, index: idx)
                } else {
                    palette.hlColorIndex = idx
                    Haptics.selection()
                }
            }
            .popover(isPresented: Binding(
                get: { activePopover == .editColor(tool: .highlighter, index: idx) },
                set: { if !$0 { activePopover = nil } }
            )) {
                editColorPopover(tool: .highlighter, index: idx)
            }
        }
    }

    private var textColorSwatches: some View {
        ForEach(Array(palette.textColors.enumerated()), id: \.offset) { idx, hex in
            colorSwatch(hex: hex, selected: palette.textColorIndex == idx) {
                if palette.textColorIndex == idx {
                    activePopover = .editColor(tool: .text, index: idx)
                } else {
                    palette.textColorIndex = idx
                    controllerBox.vc?.updateActiveTextBoxStyle()
                    Haptics.selection()
                }
            }
            .popover(isPresented: Binding(
                get: { activePopover == .editColor(tool: .text, index: idx) },
                set: { if !$0 { activePopover = nil } }
            )) {
                editColorPopover(tool: .text, index: idx)
            }
        }
    }

    private var laserColorSwatches: some View {
        ForEach(Array(palette.laserColors.enumerated()), id: \.offset) { idx, hex in
            colorSwatch(hex: hex, selected: palette.laserColorIndex == idx) {
                if palette.laserColorIndex == idx {
                    activePopover = .editColor(tool: .laser, index: idx)
                } else {
                    palette.laserColorIndex = idx
                    Haptics.selection()
                }
            }
            .popover(isPresented: Binding(
                get: { activePopover == .editColor(tool: .laser, index: idx) },
                set: { if !$0 { activePopover = nil } }
            )) {
                editColorPopover(tool: .laser, index: idx)
            }
        }
    }

    private func addColorButton(for tool: DrawingTool) -> some View {
        Button {
            addColorDraft = (tool == .highlighter)
                ? Color(UIColor(hex: "#74c7ff"))
                : Color(UIColor(hex: "#af52de"))
            activePopover = .addColor(tool: tool)
            Haptics.selection()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.primary.opacity(0.72))
                .frame(width: 24, height: 24)
                .background(Color.primary.opacity(0.08))
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.primary.opacity(0.14), lineWidth: 0.7))
        }
        .buttonStyle(.plain)
        .frame(width: 28, height: 28)
        .popover(isPresented: Binding(
            get: { activePopover == .addColor(tool: tool) },
            set: { if !$0 { activePopover = nil } }
        )) {
            addColorPopover(for: tool)
        }
    }

    // MARK: - Goodnotes 3-Circle Thickness Buttons (Tap Selected -> Customize Exact pt!)

    private var penThicknessCircles: some View {
        ForEach(0..<3, id: \.self) { idx in
            let pt = palette.penSizes[idx]
            let diameter = circleDiameter(value: pt, minVal: 0.6, maxVal: 12.0)
            GoodnotesThicknessCircleButton(
                diameter: diameter,
                selected: palette.penSizeIndex == idx,
                fillColor: Color(UIColor(hex: palette.activePenColorHex))
            ) {
                if palette.penSizeIndex == idx {
                    activePopover = .editThickness(tool: .pen, index: idx)
                } else {
                    palette.penSizeIndex = idx
                    Haptics.selection()
                }
            }
            .popover(isPresented: Binding(
                get: { activePopover == .editThickness(tool: .pen, index: idx) },
                set: { if !$0 { activePopover = nil } }
            )) {
                thicknessSlotPopover(tool: .pen, index: idx)
            }
        }
    }

    private var hlThicknessCircles: some View {
        ForEach(0..<3, id: \.self) { idx in
            let pt = palette.hlSizes[idx]
            let diameter = circleDiameter(value: pt, minVal: 6.0, maxVal: 44.0)
            GoodnotesThicknessCircleButton(
                diameter: diameter,
                selected: palette.hlSizeIndex == idx,
                fillColor: Color(UIColor(hex: palette.activeHlColorHex))
            ) {
                if palette.hlSizeIndex == idx {
                    activePopover = .editThickness(tool: .highlighter, index: idx)
                } else {
                    palette.hlSizeIndex = idx
                    Haptics.selection()
                }
            }
            .popover(isPresented: Binding(
                get: { activePopover == .editThickness(tool: .highlighter, index: idx) },
                set: { if !$0 { activePopover = nil } }
            )) {
                thicknessSlotPopover(tool: .highlighter, index: idx)
            }
        }
    }

    private var eraserThicknessCircles: some View {
        ForEach(0..<3, id: \.self) { idx in
            let pt = palette.eraserSizes[idx]
            let diameter = circleDiameter(value: pt, minVal: 6.0, maxVal: 64.0)
            GoodnotesThicknessCircleButton(
                diameter: diameter,
                selected: palette.eraserSizeIndex == idx,
                fillColor: Color.primary.opacity(0.75)
            ) {
                if palette.eraserSizeIndex == idx {
                    activePopover = .editThickness(tool: .eraser, index: idx)
                } else {
                    palette.eraserSizeIndex = idx
                    Haptics.selection()
                }
            }
            .popover(isPresented: Binding(
                get: { activePopover == .editThickness(tool: .eraser, index: idx) },
                set: { if !$0 { activePopover = nil } }
            )) {
                thicknessSlotPopover(tool: .eraser, index: idx)
            }
        }
    }

    private func circleDiameter(value: Double, minVal: Double, maxVal: Double) -> CGFloat {
        let clamped = max(minVal, min(maxVal, value))
        let frac = (clamped - minVal) / max(0.001, maxVal - minVal)
        return CGFloat(5.5 + frac * 12.5)
    }

    private var straightHighlighterToggleButton: some View {
        Button {
            palette.hlStraight.toggle()
            Haptics.selection()
            toolState.showToast(palette.hlStraight ? "Straight Highlighter ON" : "Freehand Highlighter")
        } label: {
            Image(systemName: "ruler")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(palette.hlStraight ? .white : .primary.opacity(0.78))
                .frame(width: 30, height: 30)
                .background(palette.hlStraight ? Color.accentColor : Color.primary.opacity(0.06))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var textSizeStepperHorizontal: some View {
        HStack(spacing: 5) {
            Button {
                palette.textSize = max(8, palette.textSize - 2)
                controllerBox.vc?.updateActiveTextBoxStyle()
                Haptics.selection()
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.8))
                    .frame(width: 24, height: 26)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                activePopover = .text
            } label: {
                Text("\(Int(palette.textSize))pt")
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(.primary)
                    .frame(minWidth: 38)
            }
            .buttonStyle(.plain)

            Button {
                palette.textSize = min(72, palette.textSize + 2)
                controllerBox.vc?.updateActiveTextBoxStyle()
                Haptics.selection()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.8))
                    .frame(width: 24, height: 26)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private var textBoldButton: some View {
        Button {
            palette.textBold.toggle()
            controllerBox.vc?.updateActiveTextBoxStyle()
            Haptics.selection()
        } label: {
            Text("B")
                .font(.system(size: 14, weight: .bold, design: .serif))
                .foregroundColor(palette.textBold ? .white : .primary.opacity(0.8))
                .frame(width: 28, height: 28)
                .background(palette.textBold ? Color.accentColor : Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Edit Color, Add Color, & Thickness Customizer Popovers

    private func colorBinding(for tool: DrawingTool, index: Int) -> Binding<Color> {
        Binding(
            get: {
                let hex: String
                switch tool {
                case .pen: hex = palette.penColors.indices.contains(index) ? palette.penColors[index] : "#1c1c1e"
                case .highlighter: hex = palette.hlColors.indices.contains(index) ? palette.hlColors[index] : "#ffde59"
                case .text: hex = palette.textColors.indices.contains(index) ? palette.textColors[index] : "#1c1c1e"
                case .laser: hex = palette.laserColors.indices.contains(index) ? palette.laserColors[index] : "#ff3b30"
                default: hex = "#1c1c1e"
                }
                return Color(UIColor(hex: hex))
            },
            set: { newCol in
                let hex = UIColor(newCol).toHexString()
                switch tool {
                case .pen:
                    if palette.penColors.indices.contains(index) { palette.penColors[index] = hex }
                case .highlighter:
                    if palette.hlColors.indices.contains(index) { palette.hlColors[index] = hex }
                case .text:
                    if palette.textColors.indices.contains(index) {
                        palette.textColors[index] = hex
                        controllerBox.vc?.updateActiveTextBoxStyle()
                    }
                case .laser:
                    if palette.laserColors.indices.contains(index) { palette.laserColors[index] = hex }
                default: break
                }
            }
        )
    }

    private func editColorPopover(tool: DrawingTool, index: Int) -> some View {
        let presets = (tool == .highlighter) ? palette.quickHighlighterPresets : palette.quickInkPresets
        let canRemove: Bool = {
            switch tool {
            case .pen: return palette.penColors.count > 1
            case .highlighter: return palette.hlColors.count > 1
            case .text: return palette.textColors.count > 1
            case .laser: return palette.laserColors.count > 1
            default: return false
            }
        }()

        return VStack(alignment: .leading, spacing: 14) {
            Text("Edit Color Slot").font(.headline)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
                ForEach(presets, id: \.self) { hex in
                    Button {
                        colorBinding(for: tool, index: index).wrappedValue = Color(UIColor(hex: hex))
                        Haptics.selection()
                    } label: {
                        Circle()
                            .fill(Color(UIColor(hex: hex)))
                            .frame(width: 28, height: 28)
                            .overlay(Circle().stroke(Color.primary.opacity(0.18), lineWidth: 0.8))
                    }
                    .buttonStyle(.plain)
                }
            }

            ColorPicker("Custom Color", selection: colorBinding(for: tool, index: index), supportsOpacity: false)
                .font(.subheadline.weight(.medium))

            if canRemove {
                Divider()
                Button(role: .destructive) {
                    switch tool {
                    case .pen: palette.removePenColor(at: index)
                    case .highlighter: palette.removeHlColor(at: index)
                    case .text:
                        palette.removeTextColor(at: index)
                        controllerBox.vc?.updateActiveTextBoxStyle()
                    case .laser: palette.removeLaserColor(at: index)
                    default: break
                    }
                    activePopover = nil
                    Haptics.light()
                } label: {
                    Label("Remove Swatch", systemImage: "trash")
                        .font(.subheadline.weight(.medium))
                }
            }
        }
        .padding(16)
        .frame(width: 264)
    }

    private func addColorPopover(for tool: DrawingTool) -> some View {
        let presets = (tool == .highlighter) ? palette.quickHighlighterPresets : palette.quickInkPresets

        return VStack(alignment: .leading, spacing: 14) {
            Text("Add Color to Palette").font(.headline)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
                ForEach(presets, id: \.self) { hex in
                    Button {
                        addColorHex(hex, to: tool)
                        activePopover = nil
                        Haptics.selection()
                    } label: {
                        Circle()
                            .fill(Color(UIColor(hex: hex)))
                            .frame(width: 28, height: 28)
                            .overlay(Circle().stroke(Color.primary.opacity(0.18), lineWidth: 0.8))
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            ColorPicker("Pick Custom Color", selection: $addColorDraft, supportsOpacity: false)
                .font(.subheadline.weight(.medium))

            Button {
                let hex = UIColor(addColorDraft).toHexString()
                addColorHex(hex, to: tool)
                activePopover = nil
                Haptics.selection()
            } label: {
                Text("Add Color")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .frame(width: 264)
    }

    private func addColorHex(_ hex: String, to tool: DrawingTool) {
        switch tool {
        case .pen: palette.addPenColor(hex)
        case .highlighter: palette.addHlColor(hex)
        case .text:
            palette.addTextColor(hex)
            controllerBox.vc?.updateActiveTextBoxStyle()
        case .laser: palette.addLaserColor(hex)
        default: break
        }
    }

    private func thicknessSlotPopover(tool: DrawingTool, index: Int) -> some View {
        let isPen = (tool == .pen)
        let isHL = (tool == .highlighter)
        let minVal: Double = isPen ? 0.5 : 6.0
        let maxVal: Double = isPen ? 12.0 : (isHL ? 44.0 : 64.0)
        let stepVal: Double = isPen ? 0.1 : 1.0
        let presets: [Double] = isPen ? [0.8, 1.4, 2.6, 4.5, 7.0] : (isHL ? [10, 16, 22, 30, 38] : [10, 18, 28, 42, 56])
        let slotTitle = ["Slot 1 (Fine)", "Slot 2 (Medium)", "Slot 3 (Thick)"][max(0, min(2, index))]

        let valBinding = Binding<Double>(
            get: {
                if isPen { return palette.penSizes[index] }
                if isHL { return palette.hlSizes[index] }
                return palette.eraserSizes[index]
            },
            set: { v in
                if isPen { palette.penSizes[index] = (v * 10).rounded() / 10 }
                else if isHL { palette.hlSizes[index] = v.rounded() }
                else { palette.eraserSizes[index] = v.rounded() }
            }
        )

        let previewColor: Color = isPen
            ? Color(UIColor(hex: palette.activePenColorHex))
            : (isHL ? Color(UIColor(hex: palette.activeHlColorHex)) : .primary)

        let curVal = valBinding.wrappedValue
        let previewDiam = max(5, min(32, CGFloat(isPen ? curVal * 2.5 : curVal * 0.55)))

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(slotTitle).font(.headline)
                Spacer()
                Text(isPen ? String(format: "%.1f pt", curVal) : String(format: "%.0f pt", curVal))
                    .font(.subheadline.bold())
                    .monospacedDigit()
                    .foregroundColor(.accentColor)
            }

            HStack {
                Spacer()
                Circle()
                    .fill(previewColor)
                    .frame(width: previewDiam, height: previewDiam)
                    .overlay(Circle().stroke(Color.primary.opacity(0.14), lineWidth: 0.7))
                Spacer()
            }
            .frame(height: 36)

            Slider(value: valBinding, in: minVal...maxVal, step: stepVal)

            HStack(spacing: 6) {
                ForEach(presets, id: \.self) { p in
                    Button {
                        valBinding.wrappedValue = p
                        Haptics.selection()
                    } label: {
                        Text(isPen ? String(format: "%.1f", p) : "\(Int(p))")
                            .font(.system(size: 11.5, weight: .semibold))
                            .monospacedDigit()
                            .foregroundColor(.primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.08))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .frame(width: 268)
    }



    // MARK: - Floating Lasso & Text Box Action Pills

    private var lassoActionBar: some View {
        HStack(spacing: 8) {
            ForEach(Array(palette.penColors.prefix(6)), id: \.self) { hex in
                Button {
                    controllerBox.vc?.lassoRecolor(hex: hex)
                    Haptics.selection()
                } label: {
                    Circle()
                        .fill(Color(UIColor(hex: hex)))
                        .frame(width: 20, height: 20)
                        .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1))
                }
            }
            Divider().frame(height: 18)
            lassoPillButton("Duplicate") { controllerBox.vc?.lassoDuplicate(); Haptics.light() }
            lassoPillButton("Copy") { controllerBox.vc?.lassoCopy(); Haptics.light() }
            lassoPillButton("Cut") { controllerBox.vc?.lassoCut(); Haptics.light() }
            lassoPillButton("Delete", danger: true) { controllerBox.vc?.lassoDelete(); Haptics.light() }
            Button {
                controllerBox.vc?.clearLassoSelection(commitFirst: true)
                Haptics.light()
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 24, height: 24)
                    .background(Color.accentColor)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(floatingPillBg)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(hairlineColor, lineWidth: 0.9))
        .shadow(color: .black.opacity(0.14), radius: 4, y: 2)
    }

    private func lassoPillButton(_ title: String, danger: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(danger ? .red : .primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4.5)
                .background(danger ? Color.red.opacity(0.14) : Color.primary.opacity(0.07))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var textBoxActionBar: some View {
        HStack(spacing: 8) {
            Text("Drag top bar to move · Drag edge dot to resize")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.leading, 4)
            Divider().frame(height: 16)
            lassoPillButton("Style") { activePopover = .text }
            lassoPillButton("Duplicate") { controllerBox.vc?.duplicateActiveTextBox(); Haptics.light() }
            lassoPillButton("Delete", danger: true) { controllerBox.vc?.deleteActiveTextBox(); Haptics.light() }
            Button {
                controllerBox.vc?.commitActiveTextBox()
                Haptics.light()
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 24, height: 24)
                    .background(Color.accentColor)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(floatingPillBg)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(hairlineColor, lineWidth: 0.9))
        .shadow(color: .black.opacity(0.14), radius: 4, y: 2)
    }

    // MARK: - Tool Settings Popovers

    private var textSettingsPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Text Box Style").font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Font").font(.caption.bold()).foregroundColor(.secondary)
                Picker("Font", selection: $palette.textFont) {
                    ForEach(TextFontOption.allCases) { f in
                        Text(f.title).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: palette.textFont) { _ in
                    controllerBox.vc?.updateActiveTextBoxStyle()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Font Size").font(.caption.bold()).foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(palette.textSize)) pt")
                        .font(.caption.bold())
                        .foregroundColor(.accentColor)
                }
                Slider(value: $palette.textSize, in: 8...72, step: 1)
                    .onChange(of: palette.textSize) { _ in
                        controllerBox.vc?.updateActiveTextBoxStyle()
                    }
            }

            Toggle("Bold Text", isOn: $palette.textBold)
                .font(.subheadline.weight(.medium))
                .onChange(of: palette.textBold) { _ in
                    controllerBox.vc?.updateActiveTextBoxStyle()
                }

            VStack(alignment: .leading, spacing: 6) {
                Text("Box Background").font(.caption.bold()).foregroundColor(.secondary)
                HStack(spacing: 8) {
                    ForEach(palette.textBgPresets, id: \.hex) { preset in
                        let selected = (palette.textBgHex == preset.hex)
                        Button {
                            palette.textBgHex = preset.hex
                            controllerBox.vc?.updateActiveTextBoxStyle()
                            Haptics.selection()
                        } label: {
                            Text(preset.name)
                                .font(.system(size: 11.5, weight: selected ? .bold : .medium))
                                .foregroundColor(selected ? .white : .primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    selected
                                        ? Color.accentColor
                                        : (preset.hex.isEmpty ? Color.primary.opacity(0.08) : Color(UIColor(hex: preset.hex)).opacity(0.65))
                                )
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 300)
    }

    private var penSettingsPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pen Style").font(.headline)

            Picker("Pen Style", selection: $palette.penStyle) {
                ForEach(PenStyleOption.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Stabilization").font(.caption.bold()).foregroundColor(.secondary)
                    Spacer()
                    Text(palette.penSmooth == 0 ? "Off" : "Level \(palette.penSmooth)")
                        .font(.caption.bold()).foregroundColor(.accentColor)
                }
                Picker("Stabilization", selection: $palette.penSmooth) {
                    ForEach(0...5, id: \.self) { lvl in
                        Text(lvl == 0 ? "Off" : "\(lvl)").tag(lvl)
                    }
                }
                .pickerStyle(.segmented)
            }

            Toggle("Draw and Hold for Shapes", isOn: $palette.holdToShape)
                .font(.subheadline.weight(.medium))

            Text("Tip: Tap a selected color or thickness circle on the toolbar to customize it.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(18)
        .frame(width: 300)
    }

    private var highlighterSettingsPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Highlighter").font(.headline)
            Toggle("Draw in Straight Line", isOn: $palette.hlStraight)
                .font(.subheadline.weight(.medium))
            Text("Tip: Tap a selected color or thickness circle on the toolbar to customize it.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(18)
        .frame(width: 280)
    }

    private var eraserSettingsPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Eraser").font(.headline)

            Picker("Eraser Mode", selection: $palette.eraserMode) {
                ForEach(EraserModeOption.allCases) { m in
                    Text(m.title).tag(m)
                }
            }
            .pickerStyle(.segmented)

            Toggle("Erase Highlighter Only", isOn: $palette.eraseHlOnly)
                .font(.subheadline.weight(.medium))
        }
        .padding(18)
        .frame(width: 280)
    }

    private var laserSettingsPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Laser Pointer").font(.headline)
            Picker("Mode", selection: $palette.laserTrail) {
                Text("Dot").tag(false)
                Text("Trail").tag(true)
            }
            .pickerStyle(.segmented)
        }
        .padding(18)
        .frame(width: 240)
    }

    private var jumpPagePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Go to Page (1–\(toolState.totalPages))").font(.headline)
            HStack(spacing: 8) {
                TextField("Page #", text: $jumpPageInput)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                Button("Go") {
                    if let n = Int(jumpPageInput.trimmingCharacters(in: .whitespaces)) {
                        controllerBox.vc?.jumpToPage(n, animated: true)
                    }
                    activePopover = nil
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }

    // MARK: - Reusable Goodnotes Control Primitives

    private func barIconButton(
        systemName: String,
        tint: Color? = nil,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: primaryIconFont, weight: .regular))
                .foregroundColor(
                    disabled
                        ? .primary.opacity(0.24)
                        : (tint ?? .primary.opacity(0.84))
                )
                .frame(width: primaryIconFrame, height: primaryIconFrame)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func toolSlotButton<Content: View>(
        active: Bool,
        accent: Color = .blue,
        @ViewBuilder icon: () -> Content,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            icon()
                .frame(width: toolSlotFrame, height: toolSlotFrame)
                .background(
                    Circle()
                        .fill(
                            active
                                ? (colorScheme == .dark ? accent : accent.opacity(0.15))
                                : Color.clear
                        )
                )
                .overlay(
                    Circle()
                        .stroke(active && colorScheme != .dark ? accent.opacity(0.35) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func colorSwatch(hex: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color(UIColor(hex: hex)))
                    .frame(width: swatchInnerSize, height: swatchInnerSize)
                    .overlay(
                        Circle()
                            .stroke(Color.primary.opacity(0.18), lineWidth: 0.7)
                    )
                if selected {
                    Circle()
                        .stroke(Color.accentColor, lineWidth: 2.2)
                        .frame(width: swatchRingSize, height: swatchRingSize)
                }
            }
            .frame(width: swatchHitFrame, height: swatchHitFrame)
        }
        .buttonStyle(.plain)
    }
}

/// Clean Goodnotes-style proportional solid circle thickness button!
private struct GoodnotesThicknessCircleButton: View {
    let diameter: CGFloat
    let selected: Bool
    let fillColor: Color
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    #if targetEnvironment(macCatalyst)
    private let ringSize: CGFloat = 34
    private let hitSize: CGFloat = 36
    private let dotScale: CGFloat = 1.15
    #else
    private let ringSize: CGFloat = 30
    private let hitSize: CGFloat = 32
    private let dotScale: CGFloat = 1.0
    #endif

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(selected ? Color.accentColor.opacity(0.16) : Color.clear)
                    .frame(width: ringSize, height: ringSize)
                if selected {
                    Circle()
                        .stroke(Color.accentColor.opacity(0.75), lineWidth: 1.5)
                        .frame(width: ringSize, height: ringSize)
                }
                Circle()
                    .fill(selected ? Color.accentColor : (colorScheme == .dark ? Color.white.opacity(0.84) : Color(white: 0.22)))
                    .frame(width: diameter * dotScale, height: diameter * dotScale)
            }
            .frame(width: hitSize, height: hitSize)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Crisp Goodnotes-Style Adaptive Tool Icons

private struct GoodnotesHandIcon: View {
    let isActive: Bool
    let isDark: Bool

    #if targetEnvironment(macCatalyst)
    private let iconSize: CGFloat = 20
    #else
    private let iconSize: CGFloat = 16.5
    #endif

    var body: some View {
        Image(systemName: isActive ? "hand.raised.fill" : "hand.raised")
            .font(.system(size: iconSize, weight: .regular))
            .foregroundColor(isActive ? (isDark ? .white : .blue) : (isDark ? .white.opacity(0.86) : Color(white: 0.22)))
    }
}

private struct GoodnotesPenIcon: View {
    let inkColor: Color
    let isActive: Bool
    let isDark: Bool

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let stroke: Color = isActive ? (isDark ? .white : .blue) : (isDark ? .white.opacity(0.86) : Color(white: 0.22))

            var barrel = Path()
            barrel.move(to: CGPoint(x: w * 0.62, y: h * 0.14))
            barrel.addLine(to: CGPoint(x: w * 0.84, y: h * 0.36))
            barrel.addLine(to: CGPoint(x: w * 0.44, y: h * 0.76))
            barrel.addLine(to: CGPoint(x: w * 0.22, y: h * 0.54))
            barrel.closeSubpath()
            ctx.stroke(barrel, with: .color(stroke), style: StrokeStyle(lineWidth: 1.55, lineCap: .round, lineJoin: .round))

            var band = Path()
            band.move(to: CGPoint(x: w * 0.34, y: h * 0.42))
            band.addLine(to: CGPoint(x: w * 0.56, y: h * 0.64))
            ctx.stroke(band, with: .color(isActive && isDark ? .white.opacity(0.75) : inkColor), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

            var nib = Path()
            nib.move(to: CGPoint(x: w * 0.22, y: h * 0.54))
            nib.addLine(to: CGPoint(x: w * 0.14, y: h * 0.84))
            nib.addLine(to: CGPoint(x: w * 0.44, y: h * 0.76))
            ctx.stroke(nib, with: .color(stroke), style: StrokeStyle(lineWidth: 1.55, lineCap: .round, lineJoin: .round))
        }
    }
}

private struct GoodnotesEraserIcon: View {
    let isActive: Bool
    let isDark: Bool

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let stroke: Color = isActive ? (isDark ? .white : .blue) : (isDark ? .white.opacity(0.86) : Color(white: 0.22))

            var block = Path()
            block.move(to: CGPoint(x: w * 0.48, y: h * 0.18))
            block.addLine(to: CGPoint(x: w * 0.84, y: h * 0.54))
            block.addLine(to: CGPoint(x: w * 0.56, y: h * 0.82))
            block.addLine(to: CGPoint(x: w * 0.28, y: h * 0.82))
            block.addLine(to: CGPoint(x: w * 0.16, y: h * 0.70))
            block.addLine(to: CGPoint(x: w * 0.16, y: h * 0.50))
            block.closeSubpath()
            ctx.stroke(block, with: .color(stroke), style: StrokeStyle(lineWidth: 1.55, lineCap: .round, lineJoin: .round))

            var div = Path()
            div.move(to: CGPoint(x: w * 0.31, y: h * 0.35))
            div.addLine(to: CGPoint(x: w * 0.67, y: h * 0.71))
            ctx.stroke(div, with: .color(stroke.opacity(0.85)), style: StrokeStyle(lineWidth: 1.45, lineCap: .round))

            var line = Path()
            line.move(to: CGPoint(x: w * 0.54, y: h * 0.82))
            line.addLine(to: CGPoint(x: w * 0.84, y: h * 0.82))
            ctx.stroke(line, with: .color(stroke.opacity(0.55)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
    }
}

private struct GoodnotesHighlighterIcon: View {
    let accentColor: Color
    let isActive: Bool
    let isDark: Bool

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let stroke: Color = isActive ? (isDark ? .white : .blue) : (isDark ? .white.opacity(0.86) : Color(white: 0.22))

            var bar = Path()
            bar.move(to: CGPoint(x: w * 0.20, y: h * 0.80))
            bar.addLine(to: CGPoint(x: w * 0.78, y: h * 0.80))
            ctx.stroke(bar, with: .color(isActive && isDark ? .white.opacity(0.75) : accentColor), style: StrokeStyle(lineWidth: 2.8, lineCap: .round))

            var barrel = Path()
            barrel.move(to: CGPoint(x: w * 0.56, y: h * 0.20))
            barrel.addLine(to: CGPoint(x: w * 0.78, y: h * 0.42))
            barrel.addLine(to: CGPoint(x: w * 0.48, y: h * 0.72))
            barrel.addLine(to: CGPoint(x: w * 0.26, y: h * 0.50))
            barrel.closeSubpath()
            ctx.stroke(barrel, with: .color(stroke), style: StrokeStyle(lineWidth: 1.55, lineCap: .round, lineJoin: .round))

            var nib = Path()
            nib.move(to: CGPoint(x: w * 0.26, y: h * 0.50))
            nib.addLine(to: CGPoint(x: w * 0.20, y: h * 0.67))
            nib.addLine(to: CGPoint(x: w * 0.34, y: h * 0.72))
            nib.addLine(to: CGPoint(x: w * 0.48, y: h * 0.72))
            ctx.stroke(nib, with: .color(stroke), style: StrokeStyle(lineWidth: 1.55, lineCap: .round, lineJoin: .round))
        }
    }
}

private struct GoodnotesLassoIcon: View {
    let isActive: Bool
    let isDark: Bool

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let stroke: Color = isActive ? (isDark ? .white : .blue) : (isDark ? .white.opacity(0.86) : Color(white: 0.22))

            let oval = Path(ellipseIn: CGRect(x: w * 0.14, y: h * 0.14, width: w * 0.72, height: h * 0.54))
            ctx.stroke(oval, with: .color(stroke), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [3.2, 2.4]))

            let knot = Path(ellipseIn: CGRect(x: w * 0.22, y: h * 0.60, width: w * 0.16, height: h * 0.16))
            ctx.stroke(knot, with: .color(stroke), style: StrokeStyle(lineWidth: 1.45))

            var tail = Path()
            tail.move(to: CGPoint(x: w * 0.30, y: h * 0.76))
            tail.addQuadCurve(to: CGPoint(x: w * 0.40, y: h * 0.90), control: CGPoint(x: w * 0.28, y: h * 0.87))
            ctx.stroke(tail, with: .color(stroke), style: StrokeStyle(lineWidth: 1.55, lineCap: .round))
        }
    }
}

private struct GoodnotesTextIcon: View {
    let isActive: Bool
    let isDark: Bool

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let stroke: Color = isActive ? (isDark ? .white : .blue) : (isDark ? .white.opacity(0.86) : Color(white: 0.22))

            let boxRect = CGRect(x: w * 0.12, y: h * 0.14, width: w * 0.76, height: h * 0.72)
            let boxPath = Path(roundedRect: boxRect, cornerRadius: 3.5)
            ctx.stroke(boxPath, with: .color(stroke.opacity(0.82)), style: StrokeStyle(lineWidth: 1.35, lineCap: .round, dash: [3.0, 2.2]))

            var tTop = Path()
            tTop.move(to: CGPoint(x: w * 0.32, y: h * 0.34))
            tTop.addLine(to: CGPoint(x: w * 0.68, y: h * 0.34))
            ctx.stroke(tTop, with: .color(stroke), style: StrokeStyle(lineWidth: 1.85, lineCap: .round))

            var tStem = Path()
            tStem.move(to: CGPoint(x: w * 0.50, y: h * 0.34))
            tStem.addLine(to: CGPoint(x: w * 0.50, y: h * 0.70))
            ctx.stroke(tStem, with: .color(stroke), style: StrokeStyle(lineWidth: 1.85, lineCap: .round))

            var tBase = Path()
            tBase.move(to: CGPoint(x: w * 0.42, y: h * 0.70))
            tBase.addLine(to: CGPoint(x: w * 0.58, y: h * 0.70))
            ctx.stroke(tBase, with: .color(stroke), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
    }
}

private struct GoodnotesLaserIcon: View {
    let laserColor: Color
    let isActive: Bool
    let isDark: Bool

    var body: some View {
        Canvas { ctx, size in
            let cx = size.width * 0.5, cy = size.height * 0.5
            let ray: Color = isActive ? (isDark ? .white : .red) : (isDark ? .white.opacity(0.84) : Color(white: 0.25))
            let dot: Color = isActive && isDark ? .white : laserColor

            let angles: [CGFloat] = [0, 45, 90, 135, 180, 225, 270, 315]
            for deg in angles {
                let rad = deg * .pi / 180.0
                let isCardinal = Int(deg) % 90 == 0
                let rIn: CGFloat = 5.2
                let rOut: CGFloat = isCardinal ? 8.5 : 7.6
                var p = Path()
                p.move(to: CGPoint(x: cx + cos(rad) * rIn, y: cy + sin(rad) * rIn))
                p.addLine(to: CGPoint(x: cx + cos(rad) * rOut, y: cy + sin(rad) * rOut))
                ctx.stroke(p, with: .color(ray.opacity(isCardinal ? 0.95 : 0.7)), style: StrokeStyle(lineWidth: isCardinal ? 1.55 : 1.3, lineCap: .round))
            }

            let coreR: CGFloat = 2.8
            let core = Path(ellipseIn: CGRect(x: cx - coreR, y: cy - coreR, width: coreR * 2, height: coreR * 2))
            ctx.fill(core, with: .color(dot))
        }
    }
}


// MARK: - Isolated High-Frequency HUD Subviews (ZERO NotebookScreen Rebuilds During Scroll!)

private struct BookmarkToolbarButton: View {
    @ObservedObject var hud: NotebookHUDState
    let iconFont: CGFloat
    let iconFrame: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: hud.isCurrentPageBookmarked ? "bookmark.fill" : "bookmark")
                .font(.system(size: iconFont, weight: .regular))
                .foregroundColor(hud.isCurrentPageBookmarked ? .orange : .primary.opacity(0.84))
                .frame(width: iconFrame, height: iconFrame)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct HobonichiRibbonBar: View {
    @ObservedObject var hud: NotebookHUDState
    let secondaryBarBg: Color
    let controllerBox: PDFNotebookRepresentable.ControllerBox

    var body: some View {
        HStack(spacing: 8) {
            ribbonChip("Index", active: hud.currentPage == 1, activeColor: Color(red: 0.78, green: 0.29, blue: 0.19)) {
                controllerBox.vc?.jumpToHoboIndex()
                Haptics.selection()
            }
            ribbonChip("This Week", active: false, activeColor: .accentColor) {
                controllerBox.vc?.jumpToHoboCurrentWeek()
                Haptics.selection()
            }
            ribbonChip(hud.isOnHoboNotes ? "⇄ Back to Week" : "⇄ Notes", active: hud.isOnHoboNotes, activeColor: Color(red: 0.78, green: 0.62, blue: 0.18)) {
                controllerBox.vc?.toggleHoboNotesRibbon()
                Haptics.selection()
            }
            Menu {
                Button { controllerBox.vc?.expandHoboWeeks(4) } label: {
                    Label("Add +4 Weeks (1 Month)", systemImage: "calendar.badge.plus")
                }
                Button { controllerBox.vc?.expandHoboWeeks(12) } label: {
                    Label("Add +12 Weeks (3 Months)", systemImage: "calendar.badge.plus")
                }
                Divider()
                Button { controllerBox.vc?.addHoboBackNotesPage() } label: {
                    Label("Add Back Notes Spread", systemImage: "note.text.badge.plus")
                }
            } label: {
                Text("+ Expand")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(Color(red: 0.78, green: 0.62, blue: 0.18))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color(red: 0.78, green: 0.62, blue: 0.18).opacity(0.14))
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(secondaryBarBg)
    }

    private func ribbonChip(_ title: String, active: Bool, activeColor: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(active ? .white : .primary.opacity(0.84))
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .background(active ? activeColor : Color.primary.opacity(0.07))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct NotebookFloatingHUD<JumpPopover: View>: View {
    @ObservedObject var hud: NotebookHUDState
    let isHobonichi: Bool
    let hasTopActionBar: Bool
    let pagePillFont: CGFloat
    let hairlineColor: Color
    let floatingPillBg: Color
    let onTapPagePill: () -> Void
    @Binding var jumpPopoverPresented: Bool
    @ViewBuilder let jumpPopoverContent: () -> JumpPopover

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 10) {
            if !hud.toastMessage.isEmpty {
                Text(hud.toastMessage)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundColor(colorScheme == .dark ? .white : .primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(floatingPillBg)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(hairlineColor, lineWidth: 0.8))
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                    .padding(.top, hasTopActionBar ? 0 : 10)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }

            Spacer()

            // Zero-blur Goodnotes Bottom Page Pill (saves 60Hz WindowServer blur readback on macOS!)
            Button(action: onTapPagePill) {
                HStack(spacing: 5) {
                    if isHobonichi && !hud.currentSlotLabel.isEmpty {
                        Text(hud.currentSlotLabel)
                            .font(.system(size: pagePillFont, weight: .semibold))
                        Text("·")
                            .opacity(0.55)
                        Text("\(hud.currentPage)/\(hud.totalPages)")
                            .font(.system(size: pagePillFont, weight: .medium))
                            .monospacedDigit()
                    } else {
                        Text("Page \(hud.currentPage) of \(hud.totalPages)")
                            .font(.system(size: pagePillFont, weight: .semibold))
                            .monospacedDigit()
                    }
                    if hud.saveStatus != "Saved" {
                        Text("· \(hud.saveStatus)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                .foregroundColor(.primary.opacity(0.88))
                .padding(.horizontal, 13)
                .padding(.vertical, 5.5)
                .background(floatingPillBg)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(hairlineColor, lineWidth: 0.8))
                .shadow(color: .black.opacity(0.10), radius: 3, y: 1.5)
            }
            .buttonStyle(.plain)
            .opacity(hud.isWriting ? 0.25 : 0.95)
            .animation(.easeOut(duration: 0.16), value: hud.isWriting)
            .popover(isPresented: $jumpPopoverPresented) {
                jumpPopoverContent()
            }
            .padding(.bottom, 12)
        }
        .animation(.easeOut(duration: 0.18), value: hud.toastMessage)
    }
}
