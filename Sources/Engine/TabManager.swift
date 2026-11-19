import Foundation
import SwiftUI

struct OpenDocumentTab: Identifiable, Equatable {
    let id: String
    let url: URL
    let relativePath: String
    var title: String
    let isHobonichi: Bool
    let isStandaloneScoped: Bool
    let controllerBox: PDFNotebookRepresentable.ControllerBox
    let toolState: NotebookToolState

    static func == (lhs: OpenDocumentTab, rhs: OpenDocumentTab) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.relativePath == rhs.relativePath
    }
}

/// Manages multiple simultaneously open PDF & Journal tabs with instant zero-reload switching.
@MainActor
final class TabManager: ObservableObject {
    @Published var tabs: [OpenDocumentTab] = []
    /// `nil` means the Library bookshelf is currently visible; otherwise the active tab's ID.
    @Published var activeTabID: String? = nil

    private let maxTabs = 8
    private let savedTabsKey = "pencilink.native.opentabs.v1"
    private let savedActiveKey = "pencilink.native.activetab.v1"
    private var didRestoreSession = false

    var activeTab: OpenDocumentTab? {
        guard let aid = activeTabID else { return nil }
        return tabs.first(where: { $0.id == aid })
    }

    func openDocument(
        url: URL,
        relativePath: String,
        title: String? = nil,
        isHobonichi: Bool = false,
        isStandaloneScoped: Bool = false,
        vault: VaultManager? = nil
    ) {
        let stdID = url.standardizedFileURL.resolvingSymlinksInPath().path
        vault?.recordRecentlyOpened(relativePath)

        // If already open in a tab, switch instantly!
        if let existing = tabs.first(where: { $0.id == stdID }) {
            selectTab(existing.id)
            return
        }

        // Enforce tab cap cleanly by saving and closing the oldest inactive tab
        if tabs.count >= maxTabs,
           let victim = tabs.first(where: { $0.id != activeTabID }) {
            closeTab(victim.id, switchAfter: false)
        }

        let displayTitle = (title?.isEmpty == false)
            ? title!
            : url.deletingPathExtension().lastPathComponent

        let tab = OpenDocumentTab(
            id: stdID,
            url: url,
            relativePath: relativePath,
            title: displayTitle,
            isHobonichi: isHobonichi,
            isStandaloneScoped: isStandaloneScoped,
            controllerBox: PDFNotebookRepresentable.ControllerBox(),
            toolState: NotebookToolState()
        )

        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            tabs.append(tab)
        }
        selectTab(tab.id)
        persistOpenTabs()
    }

    func selectTab(_ id: String?) {
        let prevID = activeTabID
        if prevID == id { return }

        if let prevID, let prevTab = tabs.first(where: { $0.id == prevID }) {
            prevTab.controllerBox.vc?.setTabActive(false)
        }

        withAnimation(.spring(response: 0.26, dampingFraction: 0.88)) {
            activeTabID = id
        }

        if let id, let nextTab = tabs.first(where: { $0.id == id }) {
            nextTab.controllerBox.vc?.setTabActive(true)
        }
        Haptics.selection()
        persistOpenTabs()
    }

    func showLibrary() {
        selectTab(nil)
    }

    func closeTab(_ id: String, switchAfter: Bool = true) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closing = tabs[idx]
        closing.controllerBox.vc?.saveNow()
        closing.controllerBox.vc?.syncNowWithDrive(silent: true, forceFolderScan: false)
        closing.controllerBox.vc?.setTabActive(false)
        if closing.isStandaloneScoped {
            closing.url.stopAccessingSecurityScopedResource()
        }

        let wasActive = (activeTabID == id)
        var nextID: String? = activeTabID
        if wasActive && switchAfter {
            if tabs.count == 1 {
                nextID = nil
            } else if idx > 0 {
                nextID = tabs[idx - 1].id
            } else {
                nextID = tabs[1].id
            }
        }

        withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
            tabs.remove(at: idx)
            if switchAfter {
                activeTabID = nextID
            }
        }

        if let nextID, let nextTab = tabs.first(where: { $0.id == nextID }) {
            nextTab.controllerBox.vc?.setTabActive(true)
        }
        Haptics.light()
        persistOpenTabs()
    }

    func closeAllTabs() {
        for tab in tabs {
            tab.controllerBox.vc?.saveNow()
            tab.controllerBox.vc?.syncNowWithDrive(silent: true, forceFolderScan: false)
            tab.controllerBox.vc?.setTabActive(false)
            if tab.isStandaloneScoped {
                tab.url.stopAccessingSecurityScopedResource()
            }
        }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
            tabs.removeAll()
            activeTabID = nil
        }
        persistOpenTabs()
    }

    func handleDeletedDocument(relativePath: String) {
        if let tab = tabs.first(where: { $0.relativePath == relativePath }) {
            closeTab(tab.id)
        }
    }

    func handleRenamedDocument(oldRelativePath: String, newURL: URL, newRelativePath: String, newTitle: String) {
        guard let idx = tabs.firstIndex(where: { $0.relativePath == oldRelativePath }) else { return }
        // Close and reopen cleanly under the new URL so file paths and sidecar sync stay 100% consistent
        let wasActive = (activeTabID == tabs[idx].id)
        let isHobo = tabs[idx].isHobonichi
        closeTab(tabs[idx].id, switchAfter: false)
        let newTab = OpenDocumentTab(
            id: newURL.standardizedFileURL.resolvingSymlinksInPath().path,
            url: newURL,
            relativePath: newRelativePath,
            title: newTitle,
            isHobonichi: isHobo,
            isStandaloneScoped: false,
            controllerBox: PDFNotebookRepresentable.ControllerBox(),
            toolState: NotebookToolState()
        )
        tabs.insert(newTab, at: min(idx, tabs.count))
        if wasActive {
            selectTab(newTab.id)
        }
        persistOpenTabs()
    }

    func restoreSessionIfNeeded(from vault: VaultManager) {
        guard !didRestoreSession, AppSettings.shared.restoreTabsOnLaunch, !vault.pdfs.isEmpty else { return }
        didRestoreSession = true
        let savedPaths = UserDefaults.standard.stringArray(forKey: savedTabsKey) ?? []
        let savedActive = UserDefaults.standard.string(forKey: savedActiveKey)
        guard !savedPaths.isEmpty else { return }

        var restoredActiveID: String? = nil
        for rel in savedPaths.prefix(maxTabs) {
            guard let item = vault.pdfs.first(where: { $0.relativePath == rel }) else { continue }
            let stdID = item.url.standardizedFileURL.resolvingSymlinksInPath().path
            if tabs.contains(where: { $0.id == stdID }) { continue }
            let tab = OpenDocumentTab(
                id: stdID,
                url: item.url,
                relativePath: item.relativePath,
                title: item.name,
                isHobonichi: item.isHobonichi,
                isStandaloneScoped: false,
                controllerBox: PDFNotebookRepresentable.ControllerBox(),
                toolState: NotebookToolState()
            )
            tabs.append(tab)
            if savedActive == rel {
                restoredActiveID = stdID
            }
        }
        if let aid = restoredActiveID {
            activeTabID = aid
        }
    }

    private func persistOpenTabs() {
        let vaultPaths = tabs.filter { !$0.isStandaloneScoped }.map { $0.relativePath }
        UserDefaults.standard.set(vaultPaths, forKey: savedTabsKey)
        if let active = activeTab, !active.isStandaloneScoped {
            UserDefaults.standard.set(active.relativePath, forKey: savedActiveKey)
        } else {
            UserDefaults.standard.removeObject(forKey: savedActiveKey)
        }
    }
}
