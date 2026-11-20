import SwiftUI

private enum ToolPopoverKind: Int, Identifiable {
    case pen, highlighter, eraser, text, laser, jumpPage, sync
    var id: Int { rawValue }
}

struct NotebookScreen: View {
    let tab: OpenDocumentTab
    let isActive: Bool
    let showHomeButtonInBar: Bool

    @EnvironmentObject var vault: VaultManager
    @EnvironmentObject var syncManager: DriveSyncManager
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var toolState: NotebookToolState
    @Environment(\.colorScheme) private var colorScheme

    @State private var activePopover: ToolPopoverKind? = nil
    @State private var showPageOverview = false
    @State private var openOverviewInSearch = false
    @State private var showSyncSettings = false
    @State private var showAppSettings = false
    @State private var jumpPageInput: String = ""

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

    var body: some View {
        VStack(spacing: 0) {
            // Row 1: Goodnotes Primary Document Bar
            goodnotesPrimaryBar

            Rectangle()
                .fill(hairlineColor)
                .frame(height: 0.5)

            // Row 2: Goodnotes Drawing Tool Bar (Centered tools | colors | diagonal stroke weights)
            goodnotesToolBar

            Rectangle()
                .fill(hairlineColor)
                .frame(height: 0.5)

            // Optional Hobonichi Ribbon Strip (only for Hobonichi journals)
            if toolState.isHobonichi {
                hobonichiRibbonStrip
                Rectangle()
                    .fill(hairlineColor)
                    .frame(height: 0.5)
            }

            // Full-bleed Document Canvas with subtle floating overlays (Lasso bar, Toast, Bottom Page Pill)
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

                    if !toolState.toastMessage.isEmpty {
                        Text(toolState.toastMessage)
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            .foregroundColor(colorScheme == .dark ? .white : .primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(.regularMaterial)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(hairlineColor, lineWidth: 0.8))
                            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                            .padding(.top, toolState.hasLassoSelection ? 0 : 10)
                            .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    }

                    Spacer()

                    // Subtle Goodnotes Bottom Page Pill (fades gently while writing)
                    Button {
                        jumpPageInput = "\(toolState.currentPage)"
                        activePopover = .jumpPage
                        Haptics.selection()
                    } label: {
                        HStack(spacing: 5) {
                            if toolState.isHobonichi && !toolState.currentSlotLabel.isEmpty {
                                Text(toolState.currentSlotLabel)
                                    .font(.system(size: 11.5, weight: .semibold))
                                Text("·")
                                    .opacity(0.55)
                                Text("\(toolState.currentPage)/\(toolState.totalPages)")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .monospacedDigit()
                            } else {
                                Text("Page \(toolState.currentPage) of \(toolState.totalPages)")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .monospacedDigit()
                            }
                            if toolState.saveStatus != "Saved" {
                                Text("· \(toolState.saveStatus)")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .foregroundColor(.primary.opacity(0.88))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 5.5)
                        .background(.regularMaterial)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(hairlineColor, lineWidth: 0.8))
                        .shadow(color: .black.opacity(0.14), radius: 6, y: 2)
                    }
                    .buttonStyle(.plain)
                    .opacity(toolState.isWriting ? 0.25 : 0.95)
                    .animation(.easeOut(duration: 0.16), value: toolState.isWriting)
                    .popover(isPresented: Binding(
                        get: { activePopover == .jumpPage },
                        set: { if !$0 { activePopover = nil } }
                    )) {
                        jumpPagePopover
                    }
                    .padding(.bottom, 12)
                }
                .animation(.easeOut(duration: 0.18), value: toolState.toastMessage)
                .animation(.easeOut(duration: 0.18), value: toolState.hasLassoSelection)
                .animation(.easeOut(duration: 0.18), value: toolState.hasActiveTextBox)
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
            // Left Cluster: (Optional House icon if tab bar hidden) + Overview + Search + Bookmark + Share
            HStack(spacing: 2) {
                if showHomeButtonInBar {
                    barIconButton(systemName: "house") {
                        controllerBox.vc?.saveNow()
                        tabManager.showLibrary()
                    }
                }

                barIconButton(systemName: "square.grid.2x2") {
                    controllerBox.vc?.clearLassoSelection(commitFirst: true)
                    openOverviewInSearch = false
                    Haptics.light()
                    showPageOverview = true
                }

                barIconButton(systemName: "magnifyingglass") {
                    controllerBox.vc?.clearLassoSelection(commitFirst: true)
                    openOverviewInSearch = true
                    Haptics.light()
                    showPageOverview = true
                }

                barIconButton(
                    systemName: toolState.isCurrentPageBookmarked ? "bookmark.fill" : "bookmark",
                    tint: toolState.isCurrentPageBookmarked ? .orange : nil
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
                        .font(.system(size: 16.5, weight: .regular))
                        .foregroundColor(.primary.opacity(0.84))
                        .frame(width: 36, height: 36)
                }
            }

            Spacer(minLength: 8)

            // Center: Clean Goodnotes Document Title + Chevron (tap to Jump to Page)
            Button {
                jumpPageInput = "\(toolState.currentPage)"
                activePopover = .jumpPage
                Haptics.selection()
            } label: {
                HStack(spacing: 4) {
                    Text(tab.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: 280)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            // Right Cluster: Undo + Redo + Add Page + Sync Dot + More (•••)
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
                        .font(.system(size: 16.5, weight: .regular))
                        .foregroundColor(.primary.opacity(0.84))
                        .frame(width: 36, height: 36)
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
                            controllerBox.vc?.saveNow()
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
                        Label("Document & App Settings…", systemImage: "gearshape")
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
                        .font(.system(size: 16.5, weight: .medium))
                        .foregroundColor(.primary.opacity(0.84))
                        .frame(width: 36, height: 36)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(primaryBarBg)
    }

    // MARK: - Row 2: Goodnotes Signature Centered Drawing Tool Bar

    private var goodnotesToolBar: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    // Core Goodnotes Tool Icons (Pen, Eraser, Highlighter, Lasso, Text Box, Laser)
                    HStack(spacing: 7) {
                        toolSlotButton(active: toolState.tool == .pen, accent: .blue) {
                            GoodnotesPenIcon(
                                inkColor: Color(UIColor(hex: toolState.activePenColorHex)),
                                isActive: toolState.tool == .pen,
                                isDark: colorScheme == .dark
                            )
                        } action: {
                            if toolState.tool == .pen { activePopover = .pen }
                            else { selectTool(.pen) }
                        }
                        .popover(isPresented: Binding(
                            get: { activePopover == .pen },
                            set: { if !$0 { activePopover = nil } }
                        )) { penSettingsPopover }

                        toolSlotButton(active: toolState.tool == .eraser, accent: .blue) {
                            GoodnotesEraserIcon(isActive: toolState.tool == .eraser, isDark: colorScheme == .dark)
                        } action: {
                            if toolState.tool == .eraser { activePopover = .eraser }
                            else { selectTool(.eraser) }
                        }
                        .popover(isPresented: Binding(
                            get: { activePopover == .eraser },
                            set: { if !$0 { activePopover = nil } }
                        )) { eraserSettingsPopover }

                        toolSlotButton(active: toolState.tool == .highlighter, accent: .blue) {
                            GoodnotesHighlighterIcon(
                                accentColor: Color(UIColor(hex: toolState.activeHlColorHex)),
                                isActive: toolState.tool == .highlighter,
                                isDark: colorScheme == .dark
                            )
                        } action: {
                            if toolState.tool == .highlighter { activePopover = .highlighter }
                            else { selectTool(.highlighter) }
                        }
                        .popover(isPresented: Binding(
                            get: { activePopover == .highlighter },
                            set: { if !$0 { activePopover = nil } }
                        )) { highlighterSettingsPopover }

                        toolSlotButton(active: toolState.tool == .lasso, accent: .blue) {
                            GoodnotesLassoIcon(isActive: toolState.tool == .lasso, isDark: colorScheme == .dark)
                        } action: {
                            selectTool(.lasso)
                        }

                        toolSlotButton(active: toolState.tool == .text, accent: .blue) {
                            GoodnotesTextIcon(isActive: toolState.tool == .text, isDark: colorScheme == .dark)
                        } action: {
                            if toolState.tool == .text { activePopover = .text }
                            else { selectTool(.text) }
                        }
                        .popover(isPresented: Binding(
                            get: { activePopover == .text },
                            set: { if !$0 { activePopover = nil } }
                        )) { textSettingsPopover }

                        toolSlotButton(active: toolState.tool == .laser, accent: .red) {
                            GoodnotesLaserIcon(
                                laserColor: Color(UIColor(hex: toolState.laserColorHex)),
                                isActive: toolState.tool == .laser,
                                isDark: colorScheme == .dark
                            )
                        } action: {
                            if toolState.tool == .laser { activePopover = .laser }
                            else { selectTool(.laser) }
                        }
                        .popover(isPresented: Binding(
                            get: { activePopover == .laser },
                            set: { if !$0 { activePopover = nil } }
                        )) { laserSettingsPopover }
                    }

                    Rectangle()
                        .fill(hairlineColor)
                        .frame(width: 1, height: 22)

                    // Contextual Quick Swatches & Goodnotes Diagonal Stroke-Width / Font Controls
                    contextualSlots
                }
                .padding(.horizontal, 16)
                .frame(minWidth: geo.size.width, minHeight: geo.size.height)
            }
        }
        .frame(height: settings.compactToolbar ? 42 : 48)
        .background(secondaryBarBg)
    }

    @ViewBuilder
    private var contextualSlots: some View {
        switch toolState.tool {
        case .pen:
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    ForEach(0..<toolState.penColors.count, id: \.self) { idx in
                        colorSwatch(hex: toolState.penColors[idx], selected: toolState.penColorIndex == idx) {
                            if toolState.penColorIndex == idx { activePopover = .pen }
                            else { toolState.penColorIndex = idx; Haptics.selection() }
                        }
                    }
                }

                Rectangle()
                    .fill(hairlineColor)
                    .frame(width: 1, height: 20)

                HStack(spacing: 6) {
                    ForEach(0..<toolState.penSizes.count, id: \.self) { idx in
                        GoodnotesStrokeWeightButton(
                            thickness: CGFloat(1.4 + Double(idx) * 1.4),
                            selected: toolState.penSizeIndex == idx
                        ) {
                            if toolState.penSizeIndex == idx { activePopover = .pen }
                            else { toolState.penSizeIndex = idx; Haptics.selection() }
                        }
                    }
                }
            }

        case .highlighter:
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    ForEach(0..<toolState.hlColors.count, id: \.self) { idx in
                        colorSwatch(hex: toolState.hlColors[idx], selected: toolState.hlColorIndex == idx) {
                            if toolState.hlColorIndex == idx { activePopover = .highlighter }
                            else { toolState.hlColorIndex = idx; Haptics.selection() }
                        }
                    }
                }

                Rectangle()
                    .fill(hairlineColor)
                    .frame(width: 1, height: 20)

                HStack(spacing: 6) {
                    ForEach(0..<toolState.hlSizes.count, id: \.self) { idx in
                        GoodnotesStrokeWeightButton(
                            thickness: CGFloat(2.2 + Double(idx) * 1.7),
                            selected: toolState.hlSizeIndex == idx
                        ) {
                            if toolState.hlSizeIndex == idx { activePopover = .highlighter }
                            else { toolState.hlSizeIndex = idx; Haptics.selection() }
                        }
                    }
                }

                Rectangle()
                    .fill(hairlineColor)
                    .frame(width: 1, height: 20)

                Button {
                    toolState.hlStraight.toggle()
                    Haptics.selection()
                    toolState.showToast(toolState.hlStraight ? "Straight Highlighter ON" : "Freehand Highlighter")
                } label: {
                    Image(systemName: "ruler")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(toolState.hlStraight ? .white : .primary.opacity(0.78))
                        .frame(width: 30, height: 30)
                        .background(toolState.hlStraight ? Color.accentColor : Color.primary.opacity(0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

        case .eraser:
            HStack(spacing: 10) {
                Picker("Mode", selection: $toolState.eraserMode) {
                    ForEach(EraserModeOption.allCases) { m in
                        Text(m.title).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 128)

                Rectangle()
                    .fill(hairlineColor)
                    .frame(width: 1, height: 20)

                HStack(spacing: 6) {
                    ForEach(0..<toolState.eraserSizes.count, id: \.self) { idx in
                        eraserSizeButton(diameter: CGFloat(6 + idx * 4), selected: toolState.eraserSizeIndex == idx) {
                            toolState.eraserSizeIndex = idx
                            Haptics.selection()
                        }
                    }
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
                HStack(spacing: 8) {
                    ForEach(0..<toolState.textColors.count, id: \.self) { idx in
                        colorSwatch(hex: toolState.textColors[idx], selected: toolState.textColorIndex == idx) {
                            if toolState.textColorIndex == idx {
                                activePopover = .text
                            } else {
                                toolState.textColorIndex = idx
                                controllerBox.vc?.updateActiveTextBoxStyle()
                                Haptics.selection()
                            }
                        }
                    }
                }

                Rectangle()
                    .fill(hairlineColor)
                    .frame(width: 1, height: 20)

                HStack(spacing: 5) {
                    Button {
                        toolState.textSize = max(8, toolState.textSize - 2)
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
                        Text("\(Int(toolState.textSize))pt")
                            .font(.system(size: 12.5, weight: .semibold))
                            .monospacedDigit()
                            .foregroundColor(.primary)
                            .frame(minWidth: 38)
                    }
                    .buttonStyle(.plain)

                    Button {
                        toolState.textSize = min(72, toolState.textSize + 2)
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

                Rectangle()
                    .fill(hairlineColor)
                    .frame(width: 1, height: 20)

                Button {
                    toolState.textBold.toggle()
                    controllerBox.vc?.updateActiveTextBoxStyle()
                    Haptics.selection()
                } label: {
                    Text("B")
                        .font(.system(size: 14, weight: .bold, design: .serif))
                        .foregroundColor(toolState.textBold ? .white : .primary.opacity(0.8))
                        .frame(width: 28, height: 28)
                        .background(toolState.textBold ? Color.accentColor : Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }

        case .laser:
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    ForEach(toolState.laserColors, id: \.self) { hex in
                        colorSwatch(hex: hex, selected: toolState.laserColorHex == hex) {
                            toolState.laserColorHex = hex
                            Haptics.selection()
                        }
                    }
                }
                Rectangle()
                    .fill(hairlineColor)
                    .frame(width: 1, height: 20)
                Picker("Laser", selection: $toolState.laserTrail) {
                    Text("Dot").tag(false)
                    Text("Trail").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 112)
            }
        }
    }

    // MARK: - Hobonichi Two-Ribbon Strip

    private var hobonichiRibbonStrip: some View {
        HStack(spacing: 8) {
            ribbonChip("Index", active: toolState.currentPage == 1, activeColor: Color(red: 0.78, green: 0.29, blue: 0.19)) {
                controllerBox.vc?.jumpToHoboIndex()
                Haptics.selection()
            }
            ribbonChip("This Week", active: false, activeColor: .accentColor) {
                controllerBox.vc?.jumpToHoboCurrentWeek()
                Haptics.selection()
            }
            ribbonChip(toolState.isOnHoboNotes ? "⇄ Back to Week" : "⇄ Notes", active: toolState.isOnHoboNotes, activeColor: Color(red: 0.78, green: 0.62, blue: 0.18)) {
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

    // MARK: - Goodnotes Floating Lasso Action Pill

    private var lassoActionBar: some View {
        HStack(spacing: 8) {
            ForEach(toolState.penColors, id: \.self) { hex in
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
        .background(.regularMaterial)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(hairlineColor, lineWidth: 0.9))
        .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
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


    // Floating Action Pill while typing/editing a Text Box
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
        .background(.regularMaterial)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(hairlineColor, lineWidth: 0.9))
        .shadow(color: .black.opacity(0.20), radius: 10, y: 4)
    }

    private var textSettingsPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Text Box Style").font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Font").font(.caption.bold()).foregroundColor(.secondary)
                Picker("Font", selection: $toolState.textFont) {
                    ForEach(TextFontOption.allCases) { f in
                        Text(f.title).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: toolState.textFont) { _ in
                    controllerBox.vc?.updateActiveTextBoxStyle()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Font Size").font(.caption.bold()).foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(toolState.textSize)) pt")
                        .font(.caption.bold())
                        .foregroundColor(.accentColor)
                }
                Slider(value: $toolState.textSize, in: 8...72, step: 1)
                    .onChange(of: toolState.textSize) { _ in
                        controllerBox.vc?.updateActiveTextBoxStyle()
                    }
            }

            Toggle("Bold Text", isOn: $toolState.textBold)
                .font(.subheadline.weight(.medium))
                .onChange(of: toolState.textBold) { _ in
                    controllerBox.vc?.updateActiveTextBoxStyle()
                }

            ColorPicker(
                "Text Color",
                selection: Binding(
                    get: { Color(UIColor(hex: toolState.activeTextColorHex)) },
                    set: {
                        toolState.textColors[toolState.textColorIndex] = UIColor($0).toHexString()
                        controllerBox.vc?.updateActiveTextBoxStyle()
                    }
                ),
                supportsOpacity: false
            )
            .font(.subheadline.weight(.medium))

            VStack(alignment: .leading, spacing: 6) {
                Text("Box Background").font(.caption.bold()).foregroundColor(.secondary)
                HStack(spacing: 8) {
                    ForEach(toolState.textBgPresets, id: \.hex) { preset in
                        let selected = (toolState.textBgHex == preset.hex)
                        Button {
                            toolState.textBgHex = preset.hex
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

    // MARK: - Tool Settings Popovers (Goodnotes Style)

    private var penSettingsPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pen Style").font(.headline)

            Picker("Pen Style", selection: $toolState.penStyle) {
                ForEach(PenStyleOption.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Stabilization").font(.caption.bold()).foregroundColor(.secondary)
                    Spacer()
                    Text(toolState.penSmooth == 0 ? "Off" : "Level \(toolState.penSmooth)")
                        .font(.caption.bold()).foregroundColor(.accentColor)
                }
                Picker("Stabilization", selection: $toolState.penSmooth) {
                    ForEach(0...5, id: \.self) { lvl in
                        Text(lvl == 0 ? "Off" : "\(lvl)").tag(lvl)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Stroke Thickness").font(.caption.bold()).foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.1f pt", toolState.activePenSize))
                        .font(.caption.bold()).foregroundColor(.accentColor)
                }
                Slider(
                    value: Binding(
                        get: { toolState.activePenSize },
                        set: { toolState.penSizes[toolState.penSizeIndex] = ($0 * 10).rounded() / 10 }
                    ),
                    in: 0.6...12.0,
                    step: 0.2
                )
            }

            ColorPicker(
                "Custom Color",
                selection: Binding(
                    get: { Color(UIColor(hex: toolState.activePenColorHex)) },
                    set: { toolState.penColors[toolState.penColorIndex] = UIColor($0).toHexString() }
                ),
                supportsOpacity: false
            )
            .font(.subheadline.weight(.medium))

            Toggle("Draw and Hold for Shapes", isOn: $toolState.holdToShape)
                .font(.subheadline.weight(.medium))
        }
        .padding(18)
        .frame(width: 300)
    }

    private var highlighterSettingsPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Highlighter").font(.headline)
            Toggle("Draw in Straight Line", isOn: $toolState.hlStraight)
                .font(.subheadline.weight(.medium))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Width").font(.caption.bold()).foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.0f pt", toolState.activeHlSize))
                        .font(.caption.bold()).foregroundColor(.accentColor)
                }
                Slider(
                    value: Binding(
                        get: { toolState.activeHlSize },
                        set: { toolState.hlSizes[toolState.hlSizeIndex] = $0.rounded() }
                    ),
                    in: 6.0...44.0,
                    step: 1.0
                )
            }

            ColorPicker(
                "Custom Color",
                selection: Binding(
                    get: { Color(UIColor(hex: toolState.activeHlColorHex)) },
                    set: { toolState.hlColors[toolState.hlColorIndex] = UIColor($0).toHexString() }
                ),
                supportsOpacity: false
            )
            .font(.subheadline.weight(.medium))
        }
        .padding(18)
        .frame(width: 280)
    }

    private var eraserSettingsPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Eraser").font(.headline)

            Picker("Eraser Mode", selection: $toolState.eraserMode) {
                ForEach(EraserModeOption.allCases) { m in
                    Text(m.title).tag(m)
                }
            }
            .pickerStyle(.segmented)

            Toggle("Erase Highlighter Only", isOn: $toolState.eraseHlOnly)
                .font(.subheadline.weight(.medium))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Size").font(.caption.bold()).foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.0f pt", toolState.eraserSizes[toolState.eraserSizeIndex]))
                        .font(.caption.bold()).foregroundColor(.accentColor)
                }
                Slider(
                    value: Binding(
                        get: { toolState.eraserSizes[toolState.eraserSizeIndex] },
                        set: { toolState.eraserSizes[toolState.eraserSizeIndex] = $0.rounded() }
                    ),
                    in: 6.0...64.0,
                    step: 2.0
                )
            }
        }
        .padding(18)
        .frame(width: 280)
    }

    private var laserSettingsPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Laser Pointer").font(.headline)
            Picker("Mode", selection: $toolState.laserTrail) {
                Text("Dot").tag(false)
                Text("Trail").tag(true)
            }
            .pickerStyle(.segmented)

            HStack(spacing: 12) {
                ForEach(toolState.laserColors, id: \.self) { hex in
                    colorSwatch(hex: hex, selected: toolState.laserColorHex == hex) {
                        toolState.laserColorHex = hex
                    }
                }
            }
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
                .font(.system(size: 16.5, weight: .regular))
                .foregroundColor(
                    disabled
                        ? .primary.opacity(0.24)
                        : (tint ?? .primary.opacity(0.84))
                )
                .frame(width: 36, height: 36)
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
                .frame(width: 36, height: 36)
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
                    .frame(width: 22, height: 22)
                    .overlay(
                        Circle()
                            .stroke(Color.primary.opacity(0.16), lineWidth: 0.7)
                    )
                if selected {
                    Circle()
                        .stroke(Color.accentColor, lineWidth: 2.2)
                        .frame(width: 28, height: 28)
                }
            }
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
    }

    private func eraserSizeButton(diameter: CGFloat, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(selected ? Color.accentColor.opacity(0.16) : Color.clear)
                    .frame(width: 30, height: 30)
                Circle()
                    .fill(selected ? Color.accentColor : Color.primary.opacity(0.65))
                    .frame(width: diameter, height: diameter)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Iconic Goodnotes diagonal stroke-weight icon (thin / medium / thick)
private struct GoodnotesStrokeWeightButton: View {
    let thickness: CGFloat
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.16) : Color.clear)
                    .frame(width: 30, height: 30)
                Capsule()
                    .fill(selected ? Color.accentColor : Color.primary.opacity(0.75))
                    .frame(width: 15, height: thickness)
                    .rotationEffect(.degrees(-45))
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Crisp Goodnotes-Style Adaptive Tool Icons (Light & Dark Mode)

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
        .frame(width: 22, height: 22)
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
        .frame(width: 22, height: 22)
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
        .frame(width: 22, height: 22)
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
        .frame(width: 22, height: 22)
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
        .frame(width: 22, height: 22)
    }
}


private struct GoodnotesTextIcon: View {
    let isActive: Bool
    let isDark: Bool

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let stroke: Color = isActive ? (isDark ? .white : .blue) : (isDark ? .white.opacity(0.86) : Color(white: 0.22))

            // Dashed square text-box outline (classic Goodnotes Text Tool icon!)
            let boxRect = CGRect(x: w * 0.12, y: h * 0.14, width: w * 0.76, height: h * 0.72)
            let boxPath = Path(roundedRect: boxRect, cornerRadius: 3.5)
            ctx.stroke(boxPath, with: .color(stroke.opacity(0.82)), style: StrokeStyle(lineWidth: 1.35, lineCap: .round, dash: [3.0, 2.2]))

            // Crisp serif-like T in the center
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
        .frame(width: 22, height: 22)
    }
}
