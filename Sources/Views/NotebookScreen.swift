import SwiftUI

struct NotebookScreen: View {
    let pdfURL: URL
    let onClose: () -> Void

    @StateObject private var toolState = NotebookToolState()
    @State private var controllerBox = PDFNotebookRepresentable.ControllerBox()

    var body: some View {
        ZStack(alignment: .top) {
            PDFNotebookRepresentable(
                pdfURL: pdfURL,
                toolState: toolState,
                controllerBox: controllerBox
            )
            .ignoresSafeArea()

            // Floating Top Island Toolbar
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // Back + Undo / Redo
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

                    // Tools: Pen, Highlighter, Eraser, 2-Finger Scroll Lock
                    HStack(spacing: 4) {
                        toolbarButton(systemName: "pencil.tip", active: toolState.tool == .pen) {
                            toolState.tool = .pen
                        }
                        toolbarButton(systemName: "highlighter", active: toolState.tool == .highlighter) {
                            toolState.tool = .highlighter
                        }
                        toolbarButton(systemName: "eraser", active: toolState.tool == .eraser) {
                            toolState.tool = .eraser
                        }
                        toolbarButton(
                            systemName: toolState.twoFingerScrollLock ? "lock.fill" : "hand.draw",
                            active: toolState.twoFingerScrollLock,
                            tint: .orange
                        ) {
                            toolState.twoFingerScrollLock.toggle()
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.06))
                    .clipShape(Capsule())

                    // Contextual Colors & Sizes
                    if toolState.tool == .pen {
                        HStack(spacing: 7) {
                            ForEach(toolState.penColors, id: \.self) { hex in
                                colorDot(hex: hex, selected: toolState.penColorHex == hex) {
                                    toolState.penColorHex = hex
                                }
                            }
                            Divider().frame(height: 18).background(Color.white.opacity(0.2))
                            ForEach(toolState.penSizes, id: \.self) { sz in
                                sizeDot(size: sz, selected: toolState.penSize == sz) {
                                    toolState.penSize = sz
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Capsule())
                    } else if toolState.tool == .highlighter {
                        HStack(spacing: 7) {
                            ForEach(toolState.hlColors, id: \.self) { hex in
                                colorDot(hex: hex, selected: toolState.highlighterColorHex == hex) {
                                    toolState.highlighterColorHex = hex
                                }
                            }
                            Divider().frame(height: 18).background(Color.white.opacity(0.2))
                            ForEach(toolState.hlSizes, id: \.self) { sz in
                                sizeDot(size: sz / 4.0, selected: toolState.highlighterSize == sz) {
                                    toolState.highlighterSize = sz
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Capsule())
                    }

                    // Page & Save status pill
                    Text("\(toolState.currentPage)/\(toolState.totalPages) · \(toolState.saveStatus)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.horizontal, 10)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: UIScreen.main.bounds.width - 24)
            .background(Color(red: 0.10, green: 0.11, blue: 0.13).opacity(0.95))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
            .padding(.top, 12)
        }
        .statusBar(hidden: false)
    }

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
        let dotDiameter = max(4, min(14, size * 2.4))
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
