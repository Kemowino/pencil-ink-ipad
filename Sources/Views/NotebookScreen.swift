import SwiftUI

private enum ToolPopoverKind: Int, Identifiable {
    case pen, highlighter, eraser, laser, jumpPage, sync
    var id: Int { rawValue }
}

struct NotebookScreen: View {
    let tab: OpenDocumentTab
    let isActive: Bool
    let showBackButton: Bool

    @EnvironmentObject var vault: VaultManager
    @EnvironmentObject var syncManager: DriveSyncManager
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var toolState: NotebookToolState

    @State private var activePopover: ToolPopoverKind? = nil
    @State private var showPageOverview = false
    @State private var showSyncSettings = false
    @State private var showAppSettings = false
    @State private var jumpPageInput: String = ""

    init(tab: OpenDocumentTab, isActive: Bool, showBackButton: Bool) {
        self.tab = tab
        self.isActive = isActive
        self.showBackButton = showBackButton
        self._toolState = ObservedObject(wrappedValue: tab.toolState)
    }

    private var controllerBox: PDFNotebookRepresentable.ControllerBox {
        tab.controllerBox
    }

    var body: some View {
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

            // Floating Glass Dock + Contextual Bars + Bottom Page Pill
            VStack(spacing: 8) {
                floatingDock
                    .padding(.top, 8)
                    .padding(.horizontal, 12)

                if toolState.isHobonichi {
                    hobonichiRibbonBar
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if toolState.hasLassoSelection {
                    lassoActionBar
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if !toolState.toastMessage.isEmpty {
                    Text(toolState.toastMessage)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(Color(red: 0.09, green: 0.10, blue: 0.13).opacity(0.92))
                        )
                        .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 0.8))
                        .shadow(color: .black.opacity(0.32), radius: 10, y: 4)
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }

                Spacer()

                // Bottom Frosted Page Pill (softly dims while actively writing)
                Button {
                    jumpPageInput = "\(toolState.currentPage)"
                    activePopover = .jumpPage
                    Haptics.selection()
                } label: {
                    HStack(spacing: 6) {
                        if toolState.isHobonichi && !toolState.currentSlotLabel.isEmpty {
                            Text(toolState.currentSlotLabel)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                            Text("·")
                                .opacity(0.55)
                            Text("\(toolState.currentPage)/\(toolState.totalPages)")
                                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                                .monospacedDigit()
                        } else {
                            Text("Page \(toolState.currentPage) of \(toolState.totalPages)")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                        }
                        if toolState.saveStatus != "Saved" {
                            Text("· \(toolState.saveStatus)")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundColor(.white.opacity(0.68))
                        }
                    }
                    .foregroundColor(.white.opacity(0.92))
                    .padding(.horizontal, 15)
                    .padding(.vertical, 7)
                    .background(
                        Capsule()
                            .fill(Color(red: 0.09, green: 0.10, blue: 0.13).opacity(0.88))
                    )
                    .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.8))
                    .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
                }
                .opacity(toolState.isWriting ? 0.32 : 1.0)
                .animation(.easeOut(duration: 0.18), value: toolState.isWriting)
                .popover(isPresented: Binding(
                    get: { activePopover == .jumpPage },
                    set: { if !$0 { activePopover = nil } }
                )) {
                    jumpPagePopover
                }
                .padding(.bottom, 12)
            }
            .animation(.spring(response: 0.24, dampingFraction: 0.86), value: toolState.toastMessage)
            .animation(.spring(response: 0.26, dampingFraction: 0.86), value: toolState.hasLassoSelection)
            .animation(.spring(response: 0.26, dampingFraction: 0.86), value: toolState.tool)
        }
        .sheet(isPresented: $showPageOverview) {
            PageOverviewSheet(toolState: toolState, controllerBox: controllerBox)
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

    private var btnSize: CGFloat {
        settings.compactToolbar ? 31 : 35
    }

    private var floatingDock: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: settings.compactToolbar ? 6 : 8) {
                // Cluster 1: Back (only when Tab Bar is off) + Overview/Search + Undo / Redo
                HStack(spacing: 3) {
                    if showBackButton {
                        toolbarButton(systemName: "chevron.left", active: false) {
                            controllerBox.vc?.saveNow()
                            tabManager.showLibrary()
                        }
                    }
                    toolbarButton(systemName: "square.grid.2x2", active: showPageOverview) {
                        controllerBox.vc?.clearLassoSelection(commitFirst: true)
                        Haptics.light()
                        showPageOverview = true
                    }
                    toolbarButton(systemName: "arrow.uturn.backward", active: false, disabled: !toolState.canUndo) {
                        controllerBox.vc?.performUndo()
                        Haptics.light()
                    }
                    toolbarButton(systemName: "arrow.uturn.forward", active: false, disabled: !toolState.canRedo) {
                        controllerBox.vc?.performRedo()
                        Haptics.light()
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 3.5)
                .background(Color.white.opacity(0.07))
                .clipShape(Capsule())

                // Cluster 2: Bespoke Vector Drawing Tools
                HStack(spacing: 3) {
                    customToolbarButton(active: toolState.tool == .pen, tint: .blue) {
                        FountainPenToolIcon(
                            inkColor: Color(UIColor(hex: toolState.activePenColorHex)),
                            isActive: toolState.tool == .pen
                        )
                    } action: {
                        if toolState.tool == .pen { activePopover = .pen }
                        else { selectTool(.pen) }
                    }
                    .popover(isPresented: Binding(
                        get: { activePopover == .pen },
                        set: { if !$0 { activePopover = nil } }
                    )) { penSettingsPopover }

                    customToolbarButton(active: toolState.tool == .highlighter, tint: .blue) {
                        HighlighterToolIcon(
                            accentColor: Color(UIColor(hex: toolState.activeHlColorHex)),
                            isActive: toolState.tool == .highlighter
                        )
                    } action: {
                        if toolState.tool == .highlighter { activePopover = .highlighter }
                        else { selectTool(.highlighter) }
                    }
                    .popover(isPresented: Binding(
                        get: { activePopover == .highlighter },
                        set: { if !$0 { activePopover = nil } }
                    )) { highlighterSettingsPopover }

                    customToolbarButton(active: toolState.tool == .eraser, tint: .blue) {
                        EraserToolIcon(isActive: toolState.tool == .eraser)
                    } action: {
                        if toolState.tool == .eraser { activePopover = .eraser }
                        else { selectTool(.eraser) }
                    }
                    .popover(isPresented: Binding(
                        get: { activePopover == .eraser },
                        set: { if !$0 { activePopover = nil } }
                    )) { eraserSettingsPopover }

                    customToolbarButton(active: toolState.tool == .lasso, tint: .blue) {
                        LassoToolIcon(isActive: toolState.tool == .lasso)
                    } action: {
                        selectTool(.lasso)
                    }

                    customToolbarButton(active: toolState.tool == .laser, tint: .red) {
                        LaserToolIcon(
                            laserColor: Color(UIColor(hex: toolState.laserColorHex)),
                            isActive: toolState.tool == .laser
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
                .padding(.horizontal, 5)
                .padding(.vertical, 3.5)
                .background(Color.white.opacity(0.07))
                .clipShape(Capsule())

                // Cluster 3: Contextual Quick Swatches & Sizes
                contextualBar

                // Cluster 4: Page Actions + Document Menu (•••) + Sync Dot
                HStack(spacing: 3) {
                    Menu {
                        ForEach(PaperTemplate.allCases) { tpl in
                            Button {
                                controllerBox.vc?.insertBlankPage(after: toolState.currentPage - 1, template: tpl)
                                Haptics.light()
                            } label: {
                                Label("Add \(tpl.title) Page", systemImage: "doc.badge.plus")
                            }
                        }
                    } label: {
                        Image(systemName: "plus.rectangle.on.rectangle")
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundColor(.white.opacity(0.88))
                            .frame(width: btnSize, height: btnSize)
                    }

                    toolbarButton(
                        systemName: toolState.isCurrentPageBookmarked ? "bookmark.fill" : "bookmark",
                        active: toolState.isCurrentPageBookmarked,
                        tint: .orange
                    ) {
                        controllerBox.vc?.toggleBookmarkForCurrentPage()
                        Haptics.light()
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
                            controllerBox.vc?.duplicatePage(at: toolState.currentPage - 1)
                            Haptics.light()
                        } label: {
                            Label("Duplicate This Page", systemImage: "doc.on.doc")
                        }

                        Button {
                            controllerBox.vc?.exportCurrentPagePNG()
                        } label: {
                            Label("Export Page as PNG", systemImage: "photo")
                        }

                        Button {
                            controllerBox.vc?.exportAnnotatedPDF()
                        } label: {
                            Label("Export Full Annotated PDF", systemImage: "doc.richtext")
                        }

                        Divider()

                        Button {
                            showAppSettings = true
                        } label: {
                            Label("App Settings…", systemImage: "gearshape")
                        }

                        Divider()

                        Button(role: .destructive) {
                            controllerBox.vc?.clearCurrentPageStrokes()
                            Haptics.light()
                        } label: {
                            Label("Clear Page Writing", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white.opacity(0.88))
                            .frame(width: btnSize, height: btnSize)
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
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 3.5)
                .background(Color.white.opacity(0.07))
                .clipShape(Capsule())
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: UIScreen.main.bounds.width - 20)
        .background(
            ZStack {
                Capsule().fill(.ultraThinMaterial)
                Capsule().fill(Color(red: 0.08, green: 0.09, blue: 0.12).opacity(0.76))
            }
        )
        .clipShape(Capsule())
        .overlay(
            Capsule().stroke(
                LinearGradient(
                    colors: [Color.white.opacity(0.24), Color.white.opacity(0.08)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 0.9
            )
        )
        .shadow(color: .black.opacity(0.38), radius: 16, y: 6)
    }

    // Hobonichi Techo Weeks Two-Ribbon Bar
    private var hobonichiRibbonBar: some View {
        HStack(spacing: 6) {
            Button {
                controllerBox.vc?.jumpToHoboIndex()
                Haptics.selection()
            } label: {
                Text("Index")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundColor(toolState.currentPage == 1 ? .white : Color(red: 0.96, green: 0.95, blue: 0.92))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(toolState.currentPage == 1 ? Color(red: 0.78, green: 0.29, blue: 0.19) : Color.white.opacity(0.09))
                    .clipShape(Capsule())
            }

            Button {
                controllerBox.vc?.jumpToHoboCurrentWeek()
                Haptics.selection()
            } label: {
                Text("This Week")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundColor(Color(red: 0.96, green: 0.95, blue: 0.92))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.09))
                    .clipShape(Capsule())
            }

            Button {
                controllerBox.vc?.toggleHoboNotesRibbon()
                Haptics.selection()
            } label: {
                Text(toolState.isOnHoboNotes ? "⇄ Back to Week" : "⇄ Notes")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundColor(toolState.isOnHoboNotes ? Color(white: 0.1) : Color(red: 0.96, green: 0.95, blue: 0.92))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(toolState.isOnHoboNotes ? Color(red: 0.83, green: 0.69, blue: 0.22) : Color.white.opacity(0.09))
                    .clipShape(Capsule())
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
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundColor(Color(red: 0.83, green: 0.69, blue: 0.22))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(red: 0.83, green: 0.69, blue: 0.22).opacity(0.16))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(red: 0.10, green: 0.11, blue: 0.14).opacity(0.92))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color(red: 0.83, green: 0.69, blue: 0.22).opacity(0.38), lineWidth: 0.9))
        .shadow(color: .black.opacity(0.32), radius: 10, y: 4)
    }

    // Floating Lasso Action Bar
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
                        .overlay(Circle().stroke(Color.white.opacity(0.75), lineWidth: 1.5))
                }
            }
            Divider().frame(height: 18).background(Color.white.opacity(0.22))
            lassoPillButton("Duplicate") { controllerBox.vc?.lassoDuplicate(); Haptics.light() }
            lassoPillButton("Copy") { controllerBox.vc?.lassoCopy(); Haptics.light() }
            lassoPillButton("Cut") { controllerBox.vc?.lassoCut(); Haptics.light() }
            lassoPillButton("Delete", danger: true) { controllerBox.vc?.lassoDelete(); Haptics.light() }
            Button {
                controllerBox.vc?.clearLassoSelection(commitFirst: true)
                Haptics.light()
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 26, height: 26)
                    .background(Color.blue)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(red: 0.09, green: 0.10, blue: 0.13).opacity(0.95))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 0.9))
        .shadow(color: .black.opacity(0.38), radius: 12, y: 5)
    }

    private func lassoPillButton(_ title: String, danger: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(danger ? Color(red: 1.0, green: 0.34, blue: 0.30) : .white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(danger ? Color.red.opacity(0.18) : Color.white.opacity(0.10))
                .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private var contextualBar: some View {
        switch toolState.tool {
        case .pen:
            HStack(spacing: 7) {
                ForEach(0..<toolState.penColors.count, id: \.self) { idx in
                    colorDot(hex: toolState.penColors[idx], selected: toolState.penColorIndex == idx) {
                        if toolState.penColorIndex == idx { activePopover = .pen }
                        else { toolState.penColorIndex = idx; Haptics.selection() }
                    }
                }
                Divider().frame(height: 18).background(Color.white.opacity(0.2))
                ForEach(0..<toolState.penSizes.count, id: \.self) { idx in
                    sizeDot(size: toolState.penSizes[idx], selected: toolState.penSizeIndex == idx) {
                        if toolState.penSizeIndex == idx { activePopover = .pen }
                        else { toolState.penSizeIndex = idx; Haptics.selection() }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4.5)
            .background(Color.white.opacity(0.08))
            .clipShape(Capsule())

        case .highlighter:
            HStack(spacing: 7) {
                ForEach(0..<toolState.hlColors.count, id: \.self) { idx in
                    colorDot(hex: toolState.hlColors[idx], selected: toolState.hlColorIndex == idx) {
                        if toolState.hlColorIndex == idx { activePopover = .highlighter }
                        else { toolState.hlColorIndex = idx; Haptics.selection() }
                    }
                }
                Divider().frame(height: 18).background(Color.white.opacity(0.2))
                ForEach(0..<toolState.hlSizes.count, id: \.self) { idx in
                    sizeDot(size: toolState.hlSizes[idx] / 4.2, selected: toolState.hlSizeIndex == idx) {
                        if toolState.hlSizeIndex == idx { activePopover = .highlighter }
                        else { toolState.hlSizeIndex = idx; Haptics.selection() }
                    }
                }
                Divider().frame(height: 18).background(Color.white.opacity(0.2))
                toolbarButton(systemName: "ruler", active: toolState.hlStraight) {
                    toolState.hlStraight.toggle()
                    Haptics.selection()
                    toolState.showToast(toolState.hlStraight ? "Straight Highlighter ON" : "Freehand Highlighter")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3.5)
            .background(Color.white.opacity(0.08))
            .clipShape(Capsule())

        case .eraser:
            HStack(spacing: 7) {
                Picker("Mode", selection: $toolState.eraserMode) {
                    ForEach(EraserModeOption.allCases) { m in
                        Text(m.title).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 122)

                ForEach(0..<toolState.eraserSizes.count, id: \.self) { idx in
                    sizeDot(size: toolState.eraserSizes[idx] / 6.0, selected: toolState.eraserSizeIndex == idx) {
                        toolState.eraserSizeIndex = idx
                        Haptics.selection()
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3.5)
            .background(Color.white.opacity(0.08))
            .clipShape(Capsule())

        case .lasso:
            Text(toolState.hasLassoSelection
                 ? "\(toolState.lassoSelectedCount) selected · drag, scale, rotate"
                 : (toolState.hasLassoClipboard ? "Circle strokes or tap to paste" : "Circle strokes to select"))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(.white.opacity(0.84))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.08))
                .clipShape(Capsule())

        case .laser:
            HStack(spacing: 7) {
                ForEach(toolState.laserColors, id: \.self) { hex in
                    colorDot(hex: hex, selected: toolState.laserColorHex == hex) {
                        toolState.laserColorHex = hex
                        Haptics.selection()
                    }
                }
                Divider().frame(height: 18).background(Color.white.opacity(0.2))
                Button {
                    toolState.laserTrail.toggle()
                    Haptics.selection()
                } label: {
                    Text(toolState.laserTrail ? "Trail" : "Dot")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(toolState.laserTrail ? Color.red.opacity(0.75) : Color.white.opacity(0.14))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4.5)
            .background(Color.white.opacity(0.08))
            .clipShape(Capsule())
        }
    }

    // MARK: - Tool Popovers

    private var penSettingsPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pen Settings").font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Pen Style").font(.caption.bold()).foregroundColor(.secondary)
                Picker("Pen Style", selection: $toolState.penStyle) {
                    ForEach(PenStyleOption.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Stabilization").font(.caption.bold()).foregroundColor(.secondary)
                    Spacer()
                    Text(toolState.penSmooth == 0 ? "Off" : "Level \(toolState.penSmooth)")
                        .font(.caption.bold()).foregroundColor(.blue)
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
                    Text("Stroke Width").font(.caption.bold()).foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.1f pt", toolState.activePenSize))
                        .font(.caption.bold()).foregroundColor(.blue)
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
                "Active Ink Color",
                selection: Binding(
                    get: { Color(UIColor(hex: toolState.activePenColorHex)) },
                    set: { toolState.penColors[toolState.penColorIndex] = UIColor($0).toHexString() }
                ),
                supportsOpacity: false
            )
            .font(.subheadline.weight(.medium))

            Toggle("Hold to Snap Shapes", isOn: $toolState.holdToShape)
                .font(.subheadline.weight(.medium))
        }
        .padding(18)
        .frame(width: 300)
    }

    private var highlighterSettingsPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Highlighter Settings").font(.headline)
            Toggle("Draw in Straight Lines", isOn: $toolState.hlStraight)
                .font(.subheadline.weight(.medium))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Highlighter Width").font(.caption.bold()).foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.0f pt", toolState.activeHlSize))
                        .font(.caption.bold()).foregroundColor(.blue)
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
                "Highlight Color",
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
            Text("Eraser Settings").font(.headline)

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
                    Text("Eraser Diameter").font(.caption.bold()).foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.0f pt", toolState.eraserSizes[toolState.eraserSizeIndex]))
                        .font(.caption.bold()).foregroundColor(.blue)
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
            Toggle("Fading Trail", isOn: $toolState.laserTrail)
                .font(.subheadline.weight(.medium))
            HStack(spacing: 12) {
                ForEach(toolState.laserColors, id: \.self) { hex in
                    colorDot(hex: hex, selected: toolState.laserColorHex == hex) {
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

    // MARK: - Controls

    private func toolbarButton(
        systemName: String,
        active: Bool,
        disabled: Bool = false,
        tint: Color = .blue,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: settings.compactToolbar ? 14.5 : 15.5, weight: .semibold))
                .foregroundColor(active ? .white : .white.opacity(disabled ? 0.25 : 0.86))
                .frame(width: btnSize, height: btnSize)
                .background(active ? tint : Color.clear)
                .clipShape(Circle())
        }
        .disabled(disabled)
    }

    private func colorDot(hex: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(Color(UIColor(hex: hex)))
                .frame(width: settings.compactToolbar ? 20 : 22, height: settings.compactToolbar ? 20 : 22)
                .overlay(
                    Circle()
                        .stroke(selected ? Color.blue : Color.white.opacity(0.68), lineWidth: selected ? 2.6 : 1.4)
                )
                .scaleEffect(selected ? 1.12 : 1.0)
        }
    }

    private func customToolbarButton<Content: View>(
        active: Bool,
        tint: Color = .blue,
        @ViewBuilder icon: () -> Content,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            icon()
                .frame(width: btnSize, height: btnSize)
                .background(active ? tint : Color.clear)
                .clipShape(Circle())
        }
    }

    private func sizeDot(size: Double, selected: Bool, action: @escaping () -> Void) -> some View {
        let dotDiameter = max(4, min(14, size * 2.3))
        return Button(action: action) {
            ZStack {
                Circle()
                    .fill(selected ? Color.blue.opacity(0.28) : Color.white.opacity(0.08))
                    .frame(width: settings.compactToolbar ? 23 : 26, height: settings.compactToolbar ? 23 : 26)
                    .overlay(Circle().stroke(selected ? Color.white : Color.white.opacity(0.22), lineWidth: 1.4))
                Circle()
                    .fill(Color.white)
                    .frame(width: dotDiameter, height: dotDiameter)
            }
        }
    }
}

// MARK: - Bespoke Vector Tool Icons (Fountain Pen, Chisel Highlighter, Precision Eraser, Lasso, Laser)

private struct FountainPenToolIcon: View {
    let inkColor: Color
    let isActive: Bool

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            let strokeColor: Color = isActive ? .white : .white.opacity(0.90)

            // Pen body
            var barrel = Path()
            barrel.move(to: CGPoint(x: w * 0.62, y: h * 0.14))
            barrel.addLine(to: CGPoint(x: w * 0.84, y: h * 0.36))
            barrel.addLine(to: CGPoint(x: w * 0.44, y: h * 0.76))
            barrel.addLine(to: CGPoint(x: w * 0.22, y: h * 0.54))
            barrel.closeSubpath()
            ctx.stroke(barrel, with: .color(strokeColor), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

            // Ink-colored grip accent band
            var band = Path()
            band.move(to: CGPoint(x: w * 0.34, y: h * 0.42))
            band.addLine(to: CGPoint(x: w * 0.56, y: h * 0.64))
            ctx.stroke(
                band,
                with: .color(isActive ? Color.white.opacity(0.75) : inkColor),
                style: StrokeStyle(lineWidth: 2.6, lineCap: .round)
            )

            // Tapered precision nib
            var nib = Path()
            nib.move(to: CGPoint(x: w * 0.22, y: h * 0.54))
            nib.addLine(to: CGPoint(x: w * 0.14, y: h * 0.84))
            nib.addLine(to: CGPoint(x: w * 0.44, y: h * 0.76))
            ctx.stroke(nib, with: .color(strokeColor), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

            // Subtle colored ink tip dot
            let tipDot = Path(ellipseIn: CGRect(x: w * 0.11, y: h * 0.79, width: 3.4, height: 3.4))
            ctx.fill(tipDot, with: .color(isActive ? .white : inkColor))
        }
        .frame(width: 22, height: 22)
    }
}

private struct HighlighterToolIcon: View {
    let accentColor: Color
    let isActive: Bool

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            let strokeColor: Color = isActive ? .white : .white.opacity(0.90)

            var bar = Path()
            bar.move(to: CGPoint(x: w * 0.20, y: h * 0.80))
            bar.addLine(to: CGPoint(x: w * 0.78, y: h * 0.80))
            ctx.stroke(
                bar,
                with: .color(isActive ? Color.white.opacity(0.68) : accentColor.opacity(0.90)),
                style: StrokeStyle(lineWidth: 2.8, lineCap: .round)
            )

            var barrel = Path()
            barrel.move(to: CGPoint(x: w * 0.56, y: h * 0.20))
            barrel.addLine(to: CGPoint(x: w * 0.78, y: h * 0.42))
            barrel.addLine(to: CGPoint(x: w * 0.48, y: h * 0.72))
            barrel.addLine(to: CGPoint(x: w * 0.26, y: h * 0.50))
            barrel.closeSubpath()
            ctx.stroke(barrel, with: .color(strokeColor), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

            var nib = Path()
            nib.move(to: CGPoint(x: w * 0.26, y: h * 0.50))
            nib.addLine(to: CGPoint(x: w * 0.20, y: h * 0.67))
            nib.addLine(to: CGPoint(x: w * 0.34, y: h * 0.72))
            nib.addLine(to: CGPoint(x: w * 0.48, y: h * 0.72))
            ctx.stroke(nib, with: .color(strokeColor), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

            var band = Path()
            band.move(to: CGPoint(x: w * 0.46, y: h * 0.30))
            band.addLine(to: CGPoint(x: w * 0.68, y: h * 0.52))
            ctx.stroke(band, with: .color(strokeColor.opacity(0.7)), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
        }
        .frame(width: 22, height: 22)
    }
}

private struct EraserToolIcon: View {
    let isActive: Bool

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            let strokeColor: Color = isActive ? .white : .white.opacity(0.90)

            // Angled eraser block
            var bodyPath = Path()
            bodyPath.move(to: CGPoint(x: w * 0.48, y: h * 0.18))
            bodyPath.addLine(to: CGPoint(x: w * 0.84, y: h * 0.54))
            bodyPath.addLine(to: CGPoint(x: w * 0.56, y: h * 0.82))
            bodyPath.addLine(to: CGPoint(x: w * 0.28, y: h * 0.82))
            bodyPath.addLine(to: CGPoint(x: w * 0.16, y: h * 0.70))
            bodyPath.addLine(to: CGPoint(x: w * 0.16, y: h * 0.50))
            bodyPath.closeSubpath()
            ctx.stroke(bodyPath, with: .color(strokeColor), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

            // Sleeve divider
            var div = Path()
            div.move(to: CGPoint(x: w * 0.31, y: h * 0.35))
            div.addLine(to: CGPoint(x: w * 0.67, y: h * 0.71))
            ctx.stroke(div, with: .color(strokeColor.opacity(0.85)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

            // Baseline wipe
            var base = Path()
            base.move(to: CGPoint(x: w * 0.54, y: h * 0.82))
            base.addLine(to: CGPoint(x: w * 0.84, y: h * 0.82))
            ctx.stroke(base, with: .color(strokeColor.opacity(0.65)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }
        .frame(width: 22, height: 22)
    }
}

private struct LassoToolIcon: View {
    let isActive: Bool

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            let strokeColor: Color = isActive ? .white : .white.opacity(0.90)

            let ovalRect = CGRect(x: w * 0.14, y: h * 0.14, width: w * 0.72, height: h * 0.54)
            let oval = Path(ellipseIn: ovalRect)
            ctx.stroke(
                oval,
                with: .color(strokeColor),
                style: StrokeStyle(lineWidth: 1.65, lineCap: .round, dash: [3.2, 2.4])
            )

            let knot = Path(ellipseIn: CGRect(x: w * 0.22, y: h * 0.60, width: w * 0.16, height: h * 0.16))
            ctx.stroke(knot, with: .color(strokeColor), style: StrokeStyle(lineWidth: 1.5))

            var tail = Path()
            tail.move(to: CGPoint(x: w * 0.30, y: h * 0.76))
            tail.addQuadCurve(to: CGPoint(x: w * 0.40, y: h * 0.90), control: CGPoint(x: w * 0.28, y: h * 0.87))
            ctx.stroke(tail, with: .color(strokeColor), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }
        .frame(width: 22, height: 22)
    }
}

private struct LaserToolIcon: View {
    let laserColor: Color
    let isActive: Bool

    var body: some View {
        Canvas { ctx, size in
            let cx = size.width * 0.5
            let cy = size.height * 0.5
            let rayColor: Color = isActive ? .white : .white.opacity(0.88)
            let dotColor: Color = isActive ? .white : laserColor

            let angles: [CGFloat] = [0, 45, 90, 135, 180, 225, 270, 315]
            for deg in angles {
                let rad = deg * .pi / 180.0
                let isCardinal = Int(deg) % 90 == 0
                let rIn: CGFloat = isCardinal ? 5.2 : 5.4
                let rOut: CGFloat = isCardinal ? 8.6 : 7.8
                var ray = Path()
                ray.move(to: CGPoint(x: cx + cos(rad) * rIn, y: cy + sin(rad) * rIn))
                ray.addLine(to: CGPoint(x: cx + cos(rad) * rOut, y: cy + sin(rad) * rOut))
                ctx.stroke(
                    ray,
                    with: .color(rayColor.opacity(isCardinal ? 0.95 : 0.72)),
                    style: StrokeStyle(lineWidth: isCardinal ? 1.65 : 1.4, lineCap: .round)
                )
            }

            if !isActive {
                let haloR: CGFloat = 4.2
                let halo = Path(ellipseIn: CGRect(x: cx - haloR, y: cy - haloR, width: haloR * 2, height: haloR * 2))
                ctx.fill(halo, with: .color(laserColor.opacity(0.32)))
            }

            let coreR: CGFloat = 2.8
            let core = Path(ellipseIn: CGRect(x: cx - coreR, y: cy - coreR, width: coreR * 2, height: coreR * 2))
            ctx.fill(core, with: .color(dotColor))
        }
        .frame(width: 22, height: 22)
    }
}
