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
                DocumentTabBar()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            ZStack {
                // Keep LibraryView mounted so folder & scroll positions stay preserved
                LibraryView()
                    .opacity(tabManager.activeTabID == nil ? 1 : 0)
                    .allowsHitTesting(tabManager.activeTabID == nil)
                    .zIndex(tabManager.activeTabID == nil ? 5 : 0)

                // Keep all open document tabs alive in memory for instant 0ms tab switching
                ForEach(tabManager.tabs) { tab in
                    let isActive = (tabManager.activeTabID == tab.id)
                    NotebookScreen(
                        tab: tab,
                        isActive: isActive,
                        showBackButton: !shouldShowTabBar
                    )
                    .opacity(isActive ? 1 : 0)
                    .allowsHitTesting(isActive)
                    .zIndex(isActive ? 10 : 1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: shouldShowTabBar)
        .onChange(of: vault.pdfs) { _ in
            tabManager.restoreSessionIfNeeded(from: vault)
        }
        .onAppear {
            tabManager.restoreSessionIfNeeded(from: vault)
        }
    }
}

private struct DocumentTabBar: View {
    @EnvironmentObject var tabManager: TabManager
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            // Library Home Tab Pill
            Button {
                tabManager.showLibrary()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Library")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundColor(tabManager.activeTabID == nil ? .white : .primary.opacity(0.82))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(
                    tabManager.activeTabID == nil
                        ? AnyShapeStyle(Color.blue)
                        : AnyShapeStyle(Color.primary.opacity(0.07))
                )
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Divider()
                .frame(height: 18)
                .padding(.horizontal, 2)

            // Open Document Tabs Strip
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(tabManager.tabs) { tab in
                            TabChipView(
                                tab: tab,
                                isActive: tabManager.activeTabID == tab.id,
                                onSelect: { tabManager.selectTab(tab.id) },
                                onClose: { tabManager.closeTab(tab.id) }
                            )
                            .id(tab.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: tabManager.activeTabID) { newID in
                    if let id = newID {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }

            // Quick "+" button to pick another book from Library
            Button {
                tabManager.showLibrary()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundColor(.primary.opacity(0.75))
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Open another document")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.10))
                .frame(height: 0.5)
        }
    }
}

private struct TabChipView: View {
    let tab: OpenDocumentTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    Image(systemName: tab.isHobonichi ? "calendar" : "doc.richtext")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(
                            isActive
                                ? (tab.isHobonichi ? Color.orange : Color.blue)
                                : .secondary
                        )
                    Text(tab.title)
                        .font(.system(size: 12.5, weight: isActive ? .semibold : .medium))
                        .foregroundColor(isActive ? .primary : .secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 165, alignment: .leading)
                }
            }
            .buttonStyle(.plain)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(isActive ? .secondary : .secondary.opacity(0.65))
                    .frame(width: 18, height: 18)
                    .background(Color.primary.opacity(isActive ? 0.09 : 0.04))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    isActive
                        ? (colorScheme == .dark ? Color.white.opacity(0.14) : Color.white)
                        : Color.primary.opacity(0.045)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isActive
                        ? (tab.isHobonichi ? Color.orange.opacity(0.45) : Color.blue.opacity(0.45))
                        : Color.primary.opacity(0.06),
                    lineWidth: isActive ? 1.1 : 0.6
                )
        )
        .shadow(color: isActive ? .black.opacity(colorScheme == .dark ? 0.25 : 0.08) : .clear, radius: 4, y: 1)
    }
}
