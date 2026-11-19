import SwiftUI

private enum ToolPopoverKind: Int, Identifiable {
    case pen, highlighter, eraser, laser, jumpPage, sync
    var id: Int { rawValue }
}

struct NotebookScreen: View {
    let pdfURL: URL
    let relativePath: String
    let onClose: () -> Void

    @EnvironmentObject var vault: VaultManager
    @EnvironmentObject var syncManager: DriveSyncManager
    @StateObject private var toolState = NotebookToolState()
    @State private var controllerBox = PDFNotebookRepresentable.ControllerBox()
    @State private var activePopover: ToolPopoverKind? = nil
    @State private var showPageOverview = false
    @State private var showSyncSettings = false
    @State private var jumpPageInput: String = ""

    var body: some View {
        ZStack {
            PDFNotebookRepresentable(
                pdfURL: pdfURL,
                relativePath: relativePath,
                toolState: toolState,
                syncManager: syncManager,
                controllerBox: controllerBox
            )
            .ignoresSafeArea()

            // Top Floating Toolbar + Lasso Action Bar + Toast + Bottom Page Pill
            VStack(spacing: 10) {
                floatingDock
                    .padding(.top, 10)
                    .padding(.horizontal, 12)

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
                        .background(Color(red: 0.11, green: 0.12, blue: 0.15).opacity(0.95))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))
                        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }

                Spacer()

                // Bottom Page Indicator Pill (tap to jump to any page)
                Button {
                    jumpPageInput = "\(toolState.currentPage)"
                    activePopover = .jumpPage
                } label: {
                    Text("Page \(toolState.currentPage) / \(toolState.totalPages)  ·  \(toolState.saveStatus)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(Color(red: 0.11, green: 0.12, blue: 0.15).opacity(0.94))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
                        .shadow(color: .black.opacity(0.32), radius: 10, y: 4)
                }
                .popover(isPresented: Binding(
                    get: { activePopover == .jumpPage },
                    set: { if !$0 { activePopover = nil } }
                )) {
                    jumpPagePopover
                }
                .padding(.bottom, 12)
            }
            .animation(.easeOut(duration: 0.16), value: toolState.toastMessage)
            .animation(.easeOut(duration: 0.16), value: toolState.hasLassoSelection)
        }
        .statusBar(hidden: false)
        .sheet(isPresented: $showPageOverview) {
            PageOverviewSheet(toolState: toolState, controllerBox: controllerBox)
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showSyncSettings) {
            DriveSyncSettingsSheet(syncManager: syncManager, vault: vault)
                .preferredColorScheme(.dark)
                .onDisappear {
                    controllerBox.vc?.startLiveDriveSync()
                }
        }
    }

    private func selectTool(_ t: DrawingTool) {
        toolState.tool = t
        controllerBox.vc?.onToolChanged(to: t)
    }

    private var floatingDock: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Group 1: Back + Page Overview + Undo / Redo
                HStack(spacing: 4) {
                    toolbarButton(systemName: "chevron.left", active: false) {
                        controllerBox.vc?.saveNow()
                        onClose()
                    }
                    toolbarButton(systemName: "square.grid.2x2", active: showPageOverview) {
                        controllerBox.vc?.clearLassoSelection(commitFirst: true)
                        showPageOverview = true
                    }
                    toolbarButton(systemName: "arrow.uturn.backward", active: false, disabled: !toolState.canUndo) {
                        controllerBox.vc?.performUndo()
                    }
                    toolbarButton(systemName: "arrow.uturn.forward", active: false, disabled: !toolState.canRedo) {
                        controllerBox.vc?.performRedo()
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.06))
                .clipShape(Capsule())

                // Group 2: Tools (Pen, Highlighter, Eraser, Lasso, Laser)
                HStack(spacing: 4) {
                    toolbarButton(systemName: "pencil.tip", active: toolState.tool == .pen) {
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

                    toolbarButton(systemName: "eraser", active: toolState.tool == .eraser) {
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
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.06))
                .clipShape(Capsule())

                // Group 3: Contextual Controls
                contextualBar

                // Group 4: Page Actions (Add Page, Bookmark, Document Options / Export)
                HStack(spacing: 4) {
                    Menu {
                        ForEach(PaperTemplate.allCases) { tpl in
                            Button {
                                controllerBox.vc?.insertBlankPage(after: toolState.currentPage - 1, template: tpl)
                            } label: {
                                Label("Add \(tpl.title) Page", systemImage: "doc.badge.plus")
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white.opacity(0.88))
                            .frame(width: 34, height: 34)
                    }

                    toolbarButton(
                        systemName: toolState.isCurrentPageBookmarked ? "bookmark.fill" : "bookmark",
                        active: toolState.isCurrentPageBookmarked,
                        tint: .orange
                    ) {
                        controllerBox.vc?.toggleBookmarkForCurrentPage()
                    }

                    Menu {
                        Button {
                            controllerBox.vc?.exportCurrentPagePNG()
                        } label: {
                            Label("Share / Export Page as PNG", systemImage: "photo")
                        }
                        Button {
                            controllerBox.vc?.exportAnnotatedPDF()
                        } label: {
                            Label("Export Full Annotated PDF", systemImage: "doc.richtext")
                        }
                        Divider()
                        Button {
                            controllerBox.vc?.duplicatePage(at: toolState.currentPage - 1)
                        } label: {
                            Label("Duplicate This Page", systemImage: "doc.on.doc")
                        }
                        Button {
                            controllerBox.vc?.resetZoom()
                        } label: {
                            Label("Fit Page to Width", systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                        Divider()
                        Button(role: .destructive) {
                            controllerBox.vc?.clearCurrentPageStrokes()
                        } label: {
                            Label("Clear Page Writing", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white.opacity(0.88))
                            .frame(width: 34, height: 34)
                    }

                    SyncStatusDotButton(syncManager: syncManager) {
                        activePopover = .sync
                    }
                    .popover(isPresented: Binding(
                        get: { activePopover == .sync },
                        set: { if !$0 { activePopover = nil } }
                    )) {
                        SyncStatusPopoverView(
                            syncManager: syncManager,
                            onSyncNow: {
                                controllerBox.vc?.saveNow()
                                controllerBox.vc?.syncNowWithDrive(silent: false)
                            },
                            onOpenSettings: {
                                activePopover = nil
                                showSyncSettings = true
                            }
                        )
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.06))
                .clipShape(Capsule())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: UIScreen.main.bounds.width - 20)
        .background(Color(red: 0.10, green: 0.11, blue: 0.13).opacity(0.95))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.42), radius: 14, y: 6)
    }

    // Floating Lasso Action Bar (appears whenever strokes are circled)
    private var lassoActionBar: some View {
        HStack(spacing: 8) {
            ForEach(toolState.penColors, id: \.self) { hex in
                Button {
                    controllerBox.vc?.lassoRecolor(hex: hex)
                } label: {
                    Circle()
                        .fill(Color(UIColor(hex: hex)))
                        .frame(width: 20, height: 20)
                        .overlay(Circle().stroke(Color.white.opacity(0.75), lineWidth: 1.5))
                }
            }
            Divider().frame(height: 18).background(Color.white.opacity(0.22))
            lassoPillButton("Duplicate") { controllerBox.vc?.lassoDuplicate() }
            lassoPillButton("Copy") { controllerBox.vc?.lassoCopy() }
            lassoPillButton("Cut") { controllerBox.vc?.lassoCut() }
            lassoPillButton("Delete", danger: true) { controllerBox.vc?.lassoDelete() }
            Button {
                controllerBox.vc?.clearLassoSelection(commitFirst: true)
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
        .background(Color(red: 0.10, green: 0.11, blue: 0.14).opacity(0.96))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))
        .shadow(color: .black.opacity(0.42), radius: 12, y: 5)
    }

    private func lassoPillButton(_ title: String, danger: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(danger ? Color(red: 1.0, green: 0.30, blue: 0.26) : .white)
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
                        else { toolState.penColorIndex = idx }
                    }
                }
                Divider().frame(height: 18).background(Color.white.opacity(0.2))
                ForEach(0..<toolState.penSizes.count, id: \.self) { idx in
                    sizeDot(size: toolState.penSizes[idx], selected: toolState.penSizeIndex == idx) {
                        if toolState.penSizeIndex == idx { activePopover = .pen }
                        else { toolState.penSizeIndex = idx }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.08))
            .clipShape(Capsule())

        case .highlighter:
            HStack(spacing: 7) {
                ForEach(0..<toolState.hlColors.count, id: \.self) { idx in
                    colorDot(hex: toolState.hlColors[idx], selected: toolState.hlColorIndex == idx) {
                        if toolState.hlColorIndex == idx { activePopover = .highlighter }
                        else { toolState.hlColorIndex = idx }
                    }
                }
                Divider().frame(height: 18).background(Color.white.opacity(0.2))
                ForEach(0..<toolState.hlSizes.count, id: \.self) { idx in
                    sizeDot(size: toolState.hlSizes[idx] / 4.2, selected: toolState.hlSizeIndex == idx) {
                        if toolState.hlSizeIndex == idx { activePopover = .highlighter }
                        else { toolState.hlSizeIndex = idx }
                    }
                }
                Divider().frame(height: 18).background(Color.white.opacity(0.2))
                toolbarButton(systemName: "ruler", active: toolState.hlStraight) {
                    toolState.hlStraight.toggle()
                    toolState.showToast(toolState.hlStraight ? "Straight Highlighter ON" : "Freehand Highlighter")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
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
                .frame(width: 124)

                ForEach(0..<toolState.eraserSizes.count, id: \.self) { idx in
                    sizeDot(size: toolState.eraserSizes[idx] / 6.0, selected: toolState.eraserSizeIndex == idx) {
                        toolState.eraserSizeIndex = idx
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.08))
            .clipShape(Capsule())

        case .lasso:
            Text(toolState.hasLassoSelection
                 ? "\(toolState.lassoSelectedCount) selected · drag, scale, or rotate"
                 : (toolState.hasLassoClipboard ? "Circle strokes or tap to paste" : "Circle strokes to select"))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(.white.opacity(0.82))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.08))
                .clipShape(Capsule())

        case .laser:
            HStack(spacing: 7) {
                ForEach(toolState.laserColors, id: \.self) { hex in
                    colorDot(hex: hex, selected: toolState.laserColorHex == hex) {
                        toolState.laserColorHex = hex
                    }
                }
                Divider().frame(height: 18).background(Color.white.opacity(0.2))
                Button {
                    toolState.laserTrail.toggle()
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
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.08))
            .clipShape(Capsule())
        }
    }

    // MARK: - Tool Settings Popovers

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
                    Text("Active Stroke Size").font(.caption.bold()).foregroundColor(.secondary)
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
                "Active Color Slot",
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
                    Text("Active Width").font(.caption.bold()).foregroundColor(.secondary)
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
                "Active Highlight Color",
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
                    Text("Active Eraser Diameter").font(.caption.bold()).foregroundColor(.secondary)
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
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(active ? .white : .white.opacity(disabled ? 0.25 : 0.85))
                .frame(width: 34, height: 34)
                .background(active ? tint : Color.clear)
                .clipShape(Circle())
        }
        .disabled(disabled)
    }

    private func colorDot(hex: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(Color(UIColor(hex: hex)))
                .frame(width: 22, height: 22)
                .overlay(
                    Circle()
                        .stroke(selected ? Color.blue : Color.white.opacity(0.65), lineWidth: selected ? 2.5 : 1.5)
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
                .frame(width: 34, height: 34)
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
                    .frame(width: 26, height: 26)
                    .overlay(Circle().stroke(selected ? Color.white : Color.white.opacity(0.22), lineWidth: 1.5))
                Circle()
                    .fill(Color.white)
                    .frame(width: dotDiameter, height: dotDiameter)
            }
        }
    }
}

// MARK: - Custom Crisp Vector Tool Icons (Chisel Highlighter, Lasso, Laser Pointer)

private struct HighlighterToolIcon: View {
    let accentColor: Color
    let isActive: Bool

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            let strokeColor: Color = isActive ? .white : .white.opacity(0.88)

            var bar = Path()
            bar.move(to: CGPoint(x: w * 0.22, y: h * 0.78))
            bar.addLine(to: CGPoint(x: w * 0.76, y: h * 0.78))
            ctx.stroke(
                bar,
                with: .color(isActive ? Color.white.opacity(0.65) : accentColor.opacity(0.85)),
                style: StrokeStyle(lineWidth: 2.6, lineCap: .round)
            )

            var barrel = Path()
            barrel.move(to: CGPoint(x: w * 0.56, y: h * 0.22))
            barrel.addLine(to: CGPoint(x: w * 0.77, y: h * 0.43))
            barrel.addLine(to: CGPoint(x: w * 0.48, y: h * 0.72))
            barrel.addLine(to: CGPoint(x: w * 0.27, y: h * 0.51))
            barrel.closeSubpath()
            ctx.stroke(barrel, with: .color(strokeColor), style: StrokeStyle(lineWidth: 1.65, lineCap: .round, lineJoin: .round))

            var nib = Path()
            nib.move(to: CGPoint(x: w * 0.27, y: h * 0.51))
            nib.addLine(to: CGPoint(x: w * 0.21, y: h * 0.67))
            nib.addLine(to: CGPoint(x: w * 0.34, y: h * 0.72))
            nib.addLine(to: CGPoint(x: w * 0.48, y: h * 0.72))
            ctx.stroke(nib, with: .color(strokeColor), style: StrokeStyle(lineWidth: 1.65, lineCap: .round, lineJoin: .round))

            var band = Path()
            band.move(to: CGPoint(x: w * 0.47, y: h * 0.31))
            band.addLine(to: CGPoint(x: w * 0.68, y: h * 0.52))
            ctx.stroke(band, with: .color(strokeColor.opacity(0.7)), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
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
            let strokeColor: Color = isActive ? .white : .white.opacity(0.88)

            // Dashed lasso loop
            let ovalRect = CGRect(x: w * 0.14, y: h * 0.14, width: w * 0.72, height: h * 0.54)
            let oval = Path(ellipseIn: ovalRect)
            ctx.stroke(
                oval,
                with: .color(strokeColor),
                style: StrokeStyle(lineWidth: 1.65, lineCap: .round, dash: [3.2, 2.4])
            )

            // Knot ring + tail at bottom-left
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
            let rayColor: Color = isActive ? .white : .white.opacity(0.86)
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
