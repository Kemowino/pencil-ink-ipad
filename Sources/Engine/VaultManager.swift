import Foundation
import SwiftUI

struct PDFItem: Identifiable, Hashable {
    let id: String
    let url: URL
    let name: String
    let relativeFolder: String
    let modifiedAt: Date
    let hasInk: Bool
}

final class VaultManager: ObservableObject {
    @Published var vaultURL: URL?
    @Published var pdfs: [PDFItem] = []
    @Published var statusMessage: String = ""
    @Published var isUsingLocalFallback: Bool = false

    private let bookmarkKey = "pencilink.vault.bookmark.v1"
    private var accessingRoot = false

    init() {
        restoreSavedVault()
    }

    deinit {
        stopAccessingVault()
    }

    private func stopAccessingVault() {
        if accessingRoot, let url = vaultURL {
            url.stopAccessingSecurityScopedResource()
            accessingRoot = false
        }
    }

    func useLocalDocumentsFolder() {
        stopAccessingVault()
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            statusMessage = "Could not locate app Documents folder."
            return
        }
        isUsingLocalFallback = true
        vaultURL = docs
        statusMessage = "Using On My iPad → Pencil Ink folder."
        refreshPDFList()
    }

    func setVaultFolder(_ url: URL) {
        stopAccessingVault()
        isUsingLocalFallback = false
        let started = url.startAccessingSecurityScopedResource()
        accessingRoot = started
        vaultURL = url
        statusMessage = started ? "" : "Folder selected (note: iOS did not grant security-scoped access — if running in LiveContainer, enable Fix File Picker or install via SideStore)."

        do {
            let bookmark = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        } catch {
            statusMessage = "Connected for this session, but bookmark save failed: \(error.localizedDescription)"
        }
        refreshPDFList()
    }

    func restoreSavedVault() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            accessingRoot = url.startAccessingSecurityScopedResource()
            isUsingLocalFallback = false
            vaultURL = url
            if stale {
                setVaultFolder(url)
            } else {
                refreshPDFList()
            }
        } catch {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
        }
    }

    func refreshPDFList() {
        guard let root = vaultURL else {
            pdfs = []
            return
        }
        let fm = FileManager.default
        let rootPath = root.path
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [PDFItem] = []
            var scanErr: String?
            if !fm.isReadableFile(atPath: rootPath) {
                scanErr = "Cannot read folder \"\(root.lastPathComponent)\". If using LiveContainer, enable 'Fix File Picker' in app settings or install directly in SideStore."
            } else if let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let fileURL as URL in enumerator {
                    guard fileURL.pathExtension.lowercased() == "pdf" else { continue }
                    let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
                    let mod = values?.contentModificationDate ?? Date.distantPast
                    let parentPath = fileURL.deletingLastPathComponent().path
                    let rel: String
                    if parentPath.hasPrefix(rootPath) {
                        let suffix = String(parentPath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        rel = suffix
                    } else {
                        rel = ""
                    }
                    let inkExists = fm.fileExists(atPath: fileURL.path + ".ink.json")
                    found.append(PDFItem(
                        id: fileURL.path,
                        url: fileURL,
                        name: fileURL.deletingPathExtension().lastPathComponent,
                        relativeFolder: rel,
                        modifiedAt: mod,
                        hasInk: inkExists
                    ))
                }
            }
            found.sort { $0.modifiedAt > $1.modifiedAt }
            DispatchQueue.main.async {
                self.pdfs = found
                if let err = scanErr {
                    self.statusMessage = err
                }
            }
        }
    }
}
