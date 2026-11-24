import SwiftUI

struct WorkspaceRootView: View {
    let syncManagerRef: DriveSyncManager
    @EnvironmentObject var vault: VaultManager
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var incomingFiles: IncomingFileManager
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
                if tabManager.activeTabID == nil {
                    LibraryView()
                        .zIndex(5)
                }

                ForEach(tabManager.tabs) { tab in
                    let isActive = (tabManager.activeTabID == tab.id)
                    NotebookScreen(
                        tab: tab,
                        isActive: isActive,
                        showHomeButtonInBar: !shouldShowTabBar,
                        vault: vault,
                        syncManager: syncManagerRef,
                        tabManager: tabManager
                    )
                    .opacity(isActive ? 1 : 0)
                    .allowsHitTesting(isActive)
                    .zIndex(isActive ? 10 : 1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
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
            syncManagerRef.onRemoteDeletedPath = { relPath, isFolder in
                if isFolder {
                    tabManager.handleDeletedFolder(relativeFolder: relPath)
                } else {
                    tabManager.handleDeletedDocument(relativePath: relPath)
                }
            }
        }
        .sheet(item: $incomingFiles.pendingFile, onDismiss: {
            if incomingFiles.pendingFile != nil {
                incomingFiles.finishPending(deleteStagedFile: true)
            }
        }) { incoming in
            IncomingImportSheet(incoming: incoming)
                .preferredColorScheme(settings.appTheme.preferredColorScheme)
        }
        .alert("Could Not Open File", isPresented: Binding(
            get: { incomingFiles.stagingError != nil },
            set: { if !$0 { incomingFiles.stagingError = nil } }
        )) {
            Button("OK", role: .cancel) { incomingFiles.stagingError = nil }
        } message: {
            Text(incomingFiles.stagingError ?? "")
        }
    }
}

/// Authentic Goodnotes 6 curved folder-tab shape:
/// Rounded top corners + concave outward bottom flares merging seamlessly into Row 1.
private struct GoodnotesFolderTabShape: Shape {
    var topRadius: CGFloat = 10
    var flare: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let r = min(topRadius, (w - flare * 2) * 0.5, h * 0.5)
        let f = min(flare, w * 0.25, h * 0.5)

        var p = Path()
        p.move(to: CGPoint(x: 0, y: h))
        p.addQuadCurve(to: CGPoint(x: f, y: h - f), control: CGPoint(x: f, y: h))
        p.addLine(to: CGPoint(x: f, y: r))
        p.addQuadCurve(to: CGPoint(x: f + r, y: 0), control: CGPoint(x: f, y: 0))
        p.addLine(to: CGPoint(x: w - f - r, y: 0))
        p.addQuadCurve(to: CGPoint(x: w - f, y: r), control: CGPoint(x: w - f, y: 0))
        p.addLine(to: CGPoint(x: w - f, y: h - f))
        p.addQuadCurve(to: CGPoint(x: w, y: h), control: CGPoint(x: w - f, y: h))
        p.closeSubpath()
        return p
    }
}

private struct GoodnotesTabBar: View {
    @EnvironmentObject var tabManager: TabManager
    @Environment(\.colorScheme) private var colorScheme

    #if targetEnvironment(macCatalyst)
    // Native 1.0x Mac Idiom ("Optimize for Mac" — crisp native macOS proportions, zero 0.77x scaling!)
    private let barHeight: CGFloat = 38
    private let houseIconSize: CGFloat = 15.5
    private let houseFrameW: CGFloat = 34
    private let houseFrameH: CGFloat = 28
    private let plusIconSize: CGFloat = 14
    private let plusFrameW: CGFloat = 32
    private let plusFrameH: CGFloat = 28
    #else
    private let barHeight: CGFloat = 36
    private let houseIconSize: CGFloat = 15
    private let houseFrameW: CGFloat = 34
    private let houseFrameH: CGFloat = 28
    private let plusIconSize: CGFloat = 13.5
    private let plusFrameW: CGFloat = 32
    private let plusFrameH: CGFloat = 28
    #endif

    private var trackBg: Color { DesignTokens.tabTrack(colorScheme) }
    private var activeTabFill: Color { DesignTokens.chromePrimary(colorScheme) }
    private var bottomHairline: Color { DesignTokens.hairline(colorScheme) }

    private var inactiveDivider: Color {
        colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.13)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            trackBg

            Rectangle()
                .fill(bottomHairline)
                .frame(height: 0.5)

            HStack(alignment: .bottom, spacing: 0) {
                Button {
                    tabManager.showLibrary()
                } label: {
                    Image(systemName: tabManager.activeTabID == nil ? "house.fill" : "house")
                        .font(.system(size: houseIconSize, weight: .medium))
                        .foregroundColor(
                            tabManager.activeTabID == nil
                                ? Color.accentColor
                                : (colorScheme == .dark ? Color.white.opacity(0.78) : Color.black.opacity(0.68))
                        )
                        .frame(width: houseFrameW, height: houseFrameH)
                        .background(
                            Circle()
                                .fill(tabManager.activeTabID == nil ? Color.accentColor.opacity(0.14) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .padding(.leading, 12)
                .padding(.trailing, 4)
                .padding(.bottom, 5)

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

                Button {
                    tabManager.showLibrary()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: plusIconSize, weight: .medium))
                        .foregroundColor(colorScheme == .dark ? Color.white.opacity(0.72) : Color.black.opacity(0.62))
                        .frame(width: plusFrameW, height: plusFrameH)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 10)
                .padding(.bottom, 5)
            }
        }
        .frame(height: barHeight)
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

    #if targetEnvironment(macCatalyst)
    private let tabHeight: CGFloat = 33
    private let titleFontSize: CGFloat = 12.5
    private let calIconSize: CGFloat = 10.5
    private let minTitleW: CGFloat = 96
    private let maxTitleW: CGFloat = 210
    private let closeIconSize: CGFloat = 9.5
    private let closeFrame: CGFloat = 19
    private let topRadius: CGFloat = 9
    private let flare: CGFloat = 8
    private let padLead: CGFloat = 18
    private let padTrail: CGFloat = 14
    private let divHeight: CGFloat = 14
    #else
    private let tabHeight: CGFloat = 32
    private let titleFontSize: CGFloat = 12.5
    private let calIconSize: CGFloat = 10.5
    private let minTitleW: CGFloat = 74
    private let maxTitleW: CGFloat = 168
    private let closeIconSize: CGFloat = 9
    private let closeFrame: CGFloat = 18
    private let topRadius: CGFloat = 10
    private let flare: CGFloat = 8
    private let padLead: CGFloat = 18
    private let padTrail: CGFloat = 14
    private let divHeight: CGFloat = 14
    #endif

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 8) {
                Button(action: onSelect) {
                    HStack(spacing: 6) {
                        if tab.isHobonichi {
                            Image(systemName: "calendar")
                                .font(.system(size: calIconSize, weight: .semibold))
                                .foregroundColor(isActive ? .orange : .secondary.opacity(0.8))
                        }
                        Text(tab.title)
                            .font(.system(size: titleFontSize, weight: isActive ? .semibold : .regular))
                            .foregroundColor(isActive ? .primary : .secondary)
                            .lineLimit(1)
                            .frame(minWidth: minTitleW, maxWidth: maxTitleW, alignment: .center)
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: closeIconSize, weight: .bold))
                        .foregroundColor(isActive ? .secondary : .secondary.opacity(0.6))
                        .frame(width: closeFrame, height: closeFrame)
                        .background(
                            Circle()
                                .fill(isActive ? Color.primary.opacity(0.09) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, padLead)
            .padding(.trailing, padTrail)
            .frame(height: tabHeight)
            .background {
                if isActive {
                    GoodnotesFolderTabShape(topRadius: topRadius, flare: flare)
                        .fill(activeFill)
                }
            }

            if showTrailingDivider {
                Rectangle()
                    .fill(dividerColor)
                    .frame(width: 1, height: divHeight)
                    .padding(.trailing, 3)
            }
        }
    }
}
