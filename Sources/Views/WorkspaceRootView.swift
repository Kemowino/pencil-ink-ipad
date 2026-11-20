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
        .animation(.easeOut(duration: 0.2), value: shouldShowTabBar)
        .onChange(of: vault.pdfs) { _ in
            tabManager.restoreSessionIfNeeded(from: vault)
        }
        .onAppear {
            tabManager.restoreSessionIfNeeded(from: vault)
        }
    }
}

/// Authentic Goodnotes 6 top tab strip:
/// - Clean House icon button on the far left (no "Library" label)
/// - Flush, flat segmented document tabs with hairline dividers & subtle close `×`
/// - Active tab surface seamlessly connects into the Goodnotes document bar below
private struct GoodnotesTabBar: View {
    @EnvironmentObject var tabManager: TabManager
    @Environment(\.colorScheme) private var colorScheme

    private var stripBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.085, green: 0.090, blue: 0.102)
            : Color(red: 0.915, green: 0.922, blue: 0.938)
    }

    private var activeTabSurface: Color {
        colorScheme == .dark
            ? Color(red: 0.135, green: 0.140, blue: 0.156)
            : Color.white
    }

    private var dividerColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.10)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Iconic Goodnotes House Icon (no text!)
            Button {
                tabManager.showLibrary()
            } label: {
                Image(systemName: tabManager.activeTabID == nil ? "house.fill" : "house")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(tabManager.activeTabID == nil ? Color.accentColor : .secondary)
                    .frame(width: 48, height: 38)
                    .background(tabManager.activeTabID == nil ? activeTabSurface : Color.clear)
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(dividerColor)
                .frame(width: 0.5, height: 38)

            // Flush Goodnotes Document Tabs
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(tabManager.tabs) { tab in
                            GoodnotesTabItem(
                                tab: tab,
                                isActive: tabManager.activeTabID == tab.id,
                                activeSurface: activeTabSurface,
                                dividerColor: dividerColor,
                                onSelect: { tabManager.selectTab(tab.id) },
                                onClose: { tabManager.closeTab(tab.id) }
                            )
                            .id(tab.id)
                        }
                    }
                }
                .onChange(of: tabManager.activeTabID) { newID in
                    if let id = newID {
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }

            Rectangle()
                .fill(dividerColor)
                .frame(width: 0.5, height: 38)

            // Minimal `+` button to jump to Library to open another document
            Button {
                tabManager.showLibrary()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 40, height: 38)
            }
            .buttonStyle(.plain)
        }
        .frame(height: 38)
        .background(stripBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(dividerColor)
                .frame(height: 0.5)
        }
    }
}

private struct GoodnotesTabItem: View {
    let tab: OpenDocumentTab
    let isActive: Bool
    let activeSurface: Color
    let dividerColor: Color
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Button(action: onSelect) {
                    HStack(spacing: 6) {
                        Image(systemName: tab.isHobonichi ? "calendar" : "doc.text")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(
                                isActive
                                    ? (tab.isHobonichi ? Color.orange : Color.accentColor)
                                    : .secondary.opacity(0.8)
                            )
                        Text(tab.title)
                            .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                            .foregroundColor(isActive ? .primary : .secondary)
                            .lineLimit(1)
                            .frame(minWidth: 68, maxWidth: 185, alignment: .leading)
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(.secondary.opacity(isActive ? 0.85 : 0.55))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(height: 38)
            .background(isActive ? activeSurface : Color.clear)
            .overlay(alignment: .top) {
                if isActive {
                    Rectangle()
                        .fill(tab.isHobonichi ? Color.orange : Color.accentColor)
                        .frame(height: 2)
                }
            }

            Rectangle()
                .fill(dividerColor)
                .frame(width: 0.5, height: isActive ? 38 : 20)
        }
    }
}
