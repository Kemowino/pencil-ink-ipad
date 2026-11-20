import SwiftUI

struct WorkspaceRootView: View {
    @EnvironmentObject var vault: VaultManager
    @EnvironmentObject var syncManager: DriveSyncManager
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var settings: AppSettings

    private var shouldShowTabBar: Bool {
        settings.showTabBar && !tabManager.tabs.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if shouldShowTabBar {
                GoodnotesTabBar()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            ZStack {
                LibraryView()
                    .opacity(tabManager.activeTabID == nil ? 1 : 0)
                    .allowsHitTesting(tabManager.activeTabID == nil)
                    .zIndex(tabManager.activeTabID == nil ? 5 : 0)

                ForEach(tabManager.tabs) { tab in
                    let isActive = (tabManager.activeTabID == tab.id)
                    NotebookScreen(
                        tab: tab,
                        isActive: isActive,
                        showHomeButtonInBar: !shouldShowTabBar
                    )
                    .opacity(isActive ? 1 : 0)
                    .allowsHitTesting(isActive)
                    .zIndex(isActive ? 10 : 1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            // Hidden Cmd+W shortcut to close active tab on Mac / iPad hardware keyboard
            Button("") {
                if let aid = tabManager.activeTabID {
                    tabManager.closeTab(aid)
                }
            }
            .keyboardShortcut("w", modifiers: .command)
            .opacity(0)
            .allowsHitTesting(false)
        )
        .animation(.easeOut(duration: 0.18), value: shouldShowTabBar)
        .onChange(of: vault.pdfs) { _ in
            tabManager.restoreSessionIfNeeded(from: vault)
        }
        .onAppear {
            tabManager.restoreSessionIfNeeded(from: vault)
        }
    }
}

/// Authentic Goodnotes 6 curved folder-tab shape:
/// Rounded top corners (`topRadius`) + smooth concave outward bottom flares (`flare`)
/// so the active tab flows seamlessly into the primary document bar below with zero seam.
private struct GoodnotesFolderTabShape: Shape {
    var topRadius: CGFloat = 10
    var flare: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let r = min(topRadius, (w - flare * 2) * 0.5, h * 0.5)
        let f = min(flare, w * 0.25, h * 0.5)

        var p = Path()
        // Bottom-left flare start
        p.move(to: CGPoint(x: 0, y: h))
        // Concave flare curving up into left edge
        p.addQuadCurve(to: CGPoint(x: f, y: h - f), control: CGPoint(x: f, y: h))
        // Left vertical edge up to top-left corner
        p.addLine(to: CGPoint(x: f, y: r))
        // Rounded top-left corner
        p.addQuadCurve(to: CGPoint(x: f + r, y: 0), control: CGPoint(x: f, y: 0))
        // Top horizontal edge
        p.addLine(to: CGPoint(x: w - f - r, y: 0))
        // Rounded top-right corner
        p.addQuadCurve(to: CGPoint(x: w - f, y: r), control: CGPoint(x: w - f, y: 0))
        // Right vertical edge down to flare
        p.addLine(to: CGPoint(x: w - f, y: h - f))
        // Concave flare curving out to bottom-right
        p.addQuadCurve(to: CGPoint(x: w, y: h), control: CGPoint(x: w - f, y: h))
        p.closeSubpath()
        return p
    }
}

/// Pixel-faithful Goodnotes 6 Tab Bar:
/// - Recessed top track with clean House icon on the far left (zero text, zero boxy borders)
/// - Curved rounded-top active folder tab merging seamlessly into the document toolbar below
/// - Soft vertical dividers ONLY between adjacent inactive tabs
private struct GoodnotesTabBar: View {
    @EnvironmentObject var tabManager: TabManager
    @Environment(\.colorScheme) private var colorScheme

    private var trackBg: Color {
        colorScheme == .dark
            ? Color(red: 0.082, green: 0.086, blue: 0.098)
            : Color(red: 0.895, green: 0.905, blue: 0.925)
    }

    private var activeTabFill: Color {
        colorScheme == .dark
            ? Color(red: 0.135, green: 0.140, blue: 0.156)
            : Color.white
    }

    private var bottomHairline: Color {
        colorScheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.10)
    }

    private var inactiveDivider: Color {
        colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.13)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            trackBg

            // Bottom hairline sits BEHIND the active curved tab so the active tab seamlessly breaks the seam!
            Rectangle()
                .fill(bottomHairline)
                .frame(height: 0.5)

            HStack(alignment: .bottom, spacing: 0) {
                // Clean Goodnotes House Button on far left
                Button {
                    tabManager.showLibrary()
                } label: {
                    Image(systemName: tabManager.activeTabID == nil ? "house.fill" : "house")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(
                            tabManager.activeTabID == nil
                                ? Color.accentColor
                                : (colorScheme == .dark ? Color.white.opacity(0.75) : Color.black.opacity(0.65))
                        )
                        .frame(width: 34, height: 28)
                        .background(
                            Circle()
                                .fill(tabManager.activeTabID == nil ? Color.accentColor.opacity(0.14) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .padding(.leading, 10)
                .padding(.trailing, 4)
                .padding(.bottom, 4)

                // Curved Folder Document Tabs
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .bottom, spacing: -6) {
                            ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { idx, tab in
                                let isActive = (tabManager.activeTabID == tab.id)
                                let nextIsActive = (idx + 1 < tabManager.tabs.count) && (tabManager.activeTabID == tabManager.tabs[idx + 1].id)
                                let showTrailingDivider = !isActive && !nextIsActive && (idx < tabManager.tabs.count - 1)

                                GoodnotesCurvedTab(
                                    tab: tab,
                                    isActive: isActive,
                                    activeFill: activeTabFill,
                                    showTrailingDivider: showTrailingDivider,
                                    dividerColor: inactiveDivider,
                                    onSelect: { tabManager.selectTab(tab.id) },
                                    onClose: { tabManager.closeTab(tab.id) }
                                )
                                .zIndex(isActive ? 20 : Double(idx))
                                .id(tab.id)
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                    .onChange(of: tabManager.activeTabID) { newID in
                        if let id = newID {
                            withAnimation(.easeOut(duration: 0.18)) {
                                proxy.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                }

                // Subtle `+` button to pick another book from Library
                Button {
                    tabManager.showLibrary()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundColor(colorScheme == .dark ? Color.white.opacity(0.68) : Color.black.opacity(0.58))
                        .frame(width: 32, height: 28)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                .padding(.bottom, 4)
            }
        }
        .frame(height: 36)
    }
}

private struct GoodnotesCurvedTab: View {
    let tab: OpenDocumentTab
    let isActive: Bool
    let activeFill: Color
    let showTrailingDivider: Bool
    let dividerColor: Color
    let onSelect: () -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 6) {
                Button(action: onSelect) {
                    HStack(spacing: 5) {
                        if tab.isHobonichi {
                            Image(systemName: "calendar")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(isActive ? .orange : .secondary.opacity(0.8))
                        }
                        Text(tab.title)
                            .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                            .foregroundColor(isActive ? .primary : .secondary)
                            .lineLimit(1)
                            .frame(minWidth: 74, maxWidth: 168, alignment: .center)
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(isActive ? .secondary : .secondary.opacity(0.55))
                        .frame(width: 18, height: 18)
                        .background(
                            Circle()
                                .fill(isActive ? Color.primary.opacity(0.08) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 18)
            .padding(.trailing, 14)
            .frame(height: 32)
            .background {
                if isActive {
                    GoodnotesFolderTabShape(topRadius: 10, flare: 8)
                        .fill(activeFill)
                        .shadow(
                            color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.08),
                            radius: 3,
                            x: 0,
                            y: -1
                        )
                }
            }

            if showTrailingDivider {
                Rectangle()
                    .fill(dividerColor)
                    .frame(width: 1, height: 14)
                    .padding(.trailing, 3)
            }
        }
    }
}
