import SwiftUI

private enum ToolPopoverKind: Int, Identifiable {
    case pen, highlighter, eraser, laser, jumpPage
    var id: Int { rawValue }
}

struct NotebookScreen: View {
    let pdfURL: URL
    let onClose: () -> Void

    @StateObject private var toolState = NotebookToolState()
    @State private var controllerBox = PDFNotebookRepresentable.ControllerBox()
    @State private var activePopover: ToolPopoverKind? = nil
    @State private var jumpPageInput: String = ""

    var body: some View {
        ZStack {
            PDFNotebookRepresentable(
                pdfURL: pdfURL,
                toolState: toolState,
                controllerBox: controllerBox
            )
            .ignoresSafeArea()

            // Top Floating Toolbar + Toast
            VStack(spacing: 10) {
                floatingDock
                    .padding(.top, 10)
                    .padding(.horizontal, 12)

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
        }
        .statusBar(hidden: false)
    }

    private var floatingDock: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Group 1: Back + Undo / Redo
                HStack(spacing: 4) {
                    toolbarButton(systemName: "chevron.left", active: false) {
                        controllerBox.vc?.saveNow()
                        onClose()
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

                // Group 2: Tools (tap an active tool again for its settings popover!)
                HStack(spacing: 4) {
                    toolbarButton(systemName: "pencil.tip", active: toolState.tool == .pen) {
                        if toolState.tool == .pen { activePopover = .pen }
                        else { toolState.tool = .pen }
                    }
                    .popover(isPresented: Binding(
                        get: { activePopover == .pen },
                        set: { if !$0 { activePopover = nil } }
                    )) { penSettingsPopover }

                    toolbarButton(systemName: "highlighter", active: toolState.tool == .highlighter) {
                        if toolState.tool == .highlighter { activePopover = .highlighter }
                        else { toolState.tool = .highlighter }
                    }
                    .popover(isPresented: Binding(
                        get: { activePopover == .highlighter },
                        set: { if !$0 { activePopover = nil } }
                    )) { highlighterSettingsPopover }

                    toolbarButton(systemName: "eraser", active: toolState.tool == .eraser) {
                        if toolState.tool == .eraser { activePopover = .eraser }
                        else { toolState.tool = .eraser }
                    }
                    .popover(isPresented: Binding(
                        get: { activePopover == .eraser },
                        set: { if !$0 { activePopover = nil } }
                    )) { eraserSettingsPopover }

                    toolbarButton(systemName: "sparkles", active: toolState.tool == .laser, tint: .red) {
                        if toolState.tool == .laser { activePopover = .laser }
                        else { toolState.tool = .laser }
                    }
                    .popover(isPresented: Binding(
                        get: { activePopover == .laser },
                        set: { if !$0 { activePopover = nil } }
                    )) { laserSettingsPopover }

                    toolbarButton(
                        systemName: toolState.twoFingerScrollLock ? "lock.fill" : "hand.draw",
                        active: toolState.twoFingerScrollLock,
                        tint: .orange
                    ) {
                        toolState.twoFingerScrollLock.toggle()
                        toolState.showToast(toolState.twoFingerScrollLock ? "2-Finger Scroll Lock ON" : "1-Finger Scroll ON")
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.06))
                .clipShape(Capsule())

                // Group 3: Contextual Controls
                contextualBar
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .fixedSize(horizontal: true, vertical: false)
        .background(Color(red: 0.10, green: 0.11, blue: 0.13).opacity(0.95))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.42), radius: 14, y: 6)
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
                .frame(width: 130)

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
