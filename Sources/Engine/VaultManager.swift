import Foundation
import SwiftUI
import PDFKit
import UIKit

struct PDFItem: Identifiable, Hashable {
    let id: String
    let url: URL
    let name: String
    let relativeFolder: String
    let relativePath: String
    let modifiedAt: Date
    let hasInk: Bool
    let isHobonichi: Bool
}

struct FolderItem: Identifiable, Hashable {
    let id: String
    let url: URL
    let name: String
    let relativePath: String
    let pdfCount: Int
}

final class VaultManager: ObservableObject {
    @Published var vaultURL: URL?
    @Published var pdfs: [PDFItem] = []
    @Published var allFolders: [FolderItem] = []
    @Published var statusMessage: String = ""
    @Published var isUsingLocalFallback: Bool = false
    @Published var coverColors: [String: Int] = [:]
    @Published var journalPaths: Set<String> = []
    @Published var favoritePaths: Set<String> = []
    @Published var recentPaths: [String] = []
    @Published var lastSavedVaultName: String = ""

    private let bookmarkKey = "pencilink.vault.bookmark.v1"
    private let useLocalVaultKey = "pencilink.vault.useLocal.v1"
    private let lastVaultPathKey = "pencilink.vault.lastPath.v1"
    private let lastVaultNameKey = "pencilink.vault.lastName.v1"
    private let coverColorsKey = "pencilink.native.coverColors.v1"

    /// True when executing as a guest app inside LiveContainer on iOS/iPadOS.
    static var isRunningInLiveContainer: Bool {
        #if targetEnvironment(macCatalyst)
        return false
        #else
        let env = ProcessInfo.processInfo.environment
        if env["LC_HOME_PATH"] != nil || env["LC_GLOBAL_TWEAK_FOLDER"] != nil {
            return true
        }
        let bundlePath = Bundle.main.bundlePath.lowercased()
        let homePath = NSHomeDirectory().lowercased()
        if bundlePath.contains("livecontainer") || homePath.contains("livecontainer") {
            return true
        }
        // LiveContainer loads guest bundles from inside `/Documents/Applications/`
        if bundlePath.contains("/documents/applications/") {
            return true
        }
        return false
        #endif
    }

    static var localFolderDisplayName: String {
        #if targetEnvironment(macCatalyst)
        return "Local App Folder"
        #else
        if isRunningInLiveContainer {
            return "LiveContainer App Folder"
        }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "On My iPad" : "On My iPhone"
        return "\(device) → Pencil Ink"
        #endif
    }
    private let journalPathsKey = "pencilink.native.journalPaths.v1"
    private let favoritePathsKey = "pencilink.native.favoritePaths.v1"
    private let recentPathsKey = "pencilink.native.recentPaths.v1"
    private var scopedRootURL: URL?
    private var accessingRoot = false
    private let thumbCache = NSCache<NSString, UIImage>()
    private let thumbQueue = DispatchQueue(label: "com.pencilink.coverthumbs", qos: .utility)

    init() {
        thumbCache.countLimit = 120
        loadMetadata()
        restoreSavedVault()
    }

    deinit {
        stopAccessingVault()
    }

    private func loadMetadata() {
        if let data = UserDefaults.standard.data(forKey: coverColorsKey),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            coverColors = decoded
        }
        if let arr = UserDefaults.standard.stringArray(forKey: journalPathsKey) {
            journalPaths = Set(arr)
        }
        if let favs = UserDefaults.standard.stringArray(forKey: favoritePathsKey) {
            favoritePaths = Set(favs)
        }
        if let recs = UserDefaults.standard.stringArray(forKey: recentPathsKey) {
            recentPaths = recs
        }
    }

    private func saveMetadata() {
        if let data = try? JSONEncoder().encode(coverColors) {
            UserDefaults.standard.set(data, forKey: coverColorsKey)
        }
        UserDefaults.standard.set(Array(journalPaths), forKey: journalPathsKey)
        UserDefaults.standard.set(Array(favoritePaths), forKey: favoritePathsKey)
        UserDefaults.standard.set(recentPaths, forKey: recentPathsKey)
    }

    func toggleFavorite(_ relativePath: String) {
        if favoritePaths.contains(relativePath) {
            favoritePaths.remove(relativePath)
        } else {
            favoritePaths.insert(relativePath)
        }
        saveMetadata()
    }

    func isFavorite(_ relativePath: String) -> Bool {
        favoritePaths.contains(relativePath)
    }

    func recordRecentlyOpened(_ relativePath: String) {
        recentPaths.removeAll { $0 == relativePath }
        recentPaths.insert(relativePath, at: 0)
        if recentPaths.count > 16 {
            recentPaths = Array(recentPaths.prefix(16))
        }
        saveMetadata()
    }

    func clearThumbnailCache() {
        thumbCache.removeAllObjects()
    }

    func setCoverColor(for relativePath: String, paletteID: Int) {
        coverColors[relativePath] = paletteID
        saveMetadata()
    }

    func cycleCoverColor(for item: PDFItem) {
        let palettes = item.isHobonichi ? HobonichiEngine.hoboPalettes : HobonichiEngine.notebookPalettes
        let cur = HobonichiEngine.palette(for: item.name, customID: coverColors[item.relativePath])
        let idx = palettes.firstIndex(where: { $0.id == cur.id }) ?? 0
        let next = palettes[(idx + 1) % palettes.count]
        setCoverColor(for: item.relativePath, paletteID: next.id)
    }

    func markAsJournal(_ relativePath: String) {
        journalPaths.insert(relativePath)
        saveMetadata()
    }

    func standardizedRootPath() -> String? {
        vaultURL?.standardizedFileURL.resolvingSymlinksInPath().path
    }

    func relativePath(for url: URL) -> String {
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        if let root = standardizedRootPath(), target.hasPrefix(root) {
            return String(target.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return url.lastPathComponent
    }

    private func stopAccessingVault() {
        if accessingRoot, let url = scopedRootURL ?? vaultURL {
            url.stopAccessingSecurityScopedResource()
            accessingRoot = false
        }
        scopedRootURL = nil
    }

    /// If the user selected the parent `Obsidian` container folder on iPad instead of
    /// stepping into the vault folder (e.g. `My Notes`), automatically resolve the inner
    /// Obsidian vault root so vault-relative paths match MacBook/Windows 1:1.
    private func resolveEffectiveVaultRoot(from selected: URL) -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: selected.appendingPathComponent(".obsidian").path) {
            return selected
        }
        guard let children = try? fm.contentsOfDirectory(
            at: selected,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return selected
        }
        let subdirs = children.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        let vaults = subdirs.filter {
            fm.fileExists(atPath: $0.appendingPathComponent(".obsidian").path)
        }
        if vaults.count == 1 {
            return vaults[0]
        }
        // Fallback when `.obsidian` is hidden by a file provider: if user picked the `Obsidian`
        // container folder and it contains a single vault folder (e.g. `My Notes`), step into it.
        if selected.lastPathComponent.lowercased() == "obsidian", subdirs.count == 1 {
            let hasDirectPDFs = children.contains { $0.pathExtension.lowercased() == "pdf" }
            if !hasDirectPDFs {
                return subdirs[0]
            }
        }
        return selected
    }

    func useLocalDocumentsFolder() {
        stopAccessingVault()
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            statusMessage = "Could not locate app Documents folder."
            return
        }
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        isUsingLocalFallback = true
        scopedRootURL = docs
        vaultURL = docs
        lastSavedVaultName = Self.localFolderDisplayName
        UserDefaults.standard.set(true, forKey: useLocalVaultKey)
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.set(docs.path, forKey: lastVaultPathKey)
        UserDefaults.standard.set(Self.localFolderDisplayName, forKey: lastVaultNameKey)
        statusMessage = ""
        refreshPDFList()
    }

    func setVaultFolder(_ url: URL) {
        stopAccessingVault()
        isUsingLocalFallback = false
        UserDefaults.standard.set(false, forKey: useLocalVaultKey)
        let started = url.startAccessingSecurityScopedResource()
        accessingRoot = started
        scopedRootURL = url
        let effective = resolveEffectiveVaultRoot(from: url)
        vaultURL = effective
        lastSavedVaultName = effective.lastPathComponent
        UserDefaults.standard.set(effective.path, forKey: lastVaultPathKey)
        UserDefaults.standard.set(effective.lastPathComponent, forKey: lastVaultNameKey)

        if started || FileManager.default.isReadableFile(atPath: effective.path) {
            statusMessage = ""
        } else if Self.isRunningInLiveContainer {
            statusMessage = "Folder selected in LiveContainer. If files don't load, long-press Pencil Ink in LiveContainer → Settings → enable \"Fix File Picker\" (or tap Use LiveContainer App Folder + Google Drive Sync)."
        } else {
            statusMessage = "Folder selected, waiting for read permission."
        }

        do {
            let bookmark = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        } catch {
            if Self.isRunningInLiveContainer {
                statusMessage = "Connected for this session. Inside LiveContainer, enable \"Fix File Picker\" or use LiveContainer App Folder for permanent access."
            } else {
                statusMessage = "Connected for this session, but bookmark save failed: \(error.localizedDescription)"
            }
        }
        refreshPDFList()
    }

    func restoreSavedVault() {
        lastSavedVaultName = UserDefaults.standard.string(forKey: lastVaultNameKey) ?? ""

        // 1. If user chose Local App Folder (super reliable in LiveContainer!), restore immediately!
        if UserDefaults.standard.bool(forKey: useLocalVaultKey) {
            useLocalDocumentsFolder()
            return
        }

        // 2. Try resolving saved security-scoped bookmark
        if let data = UserDefaults.standard.data(forKey: bookmarkKey) {
            var stale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
                let started = url.startAccessingSecurityScopedResource()
                accessingRoot = started
                isUsingLocalFallback = false
                scopedRootURL = url
                let effective = resolveEffectiveVaultRoot(from: url)
                if started || FileManager.default.isReadableFile(atPath: effective.path) {
                    vaultURL = effective
                    lastSavedVaultName = effective.lastPathComponent
                    if stale {
                        if let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
                        }
                    }
                    refreshPDFList()
                    return
                }
            } catch {
                // Fall through to LiveContainer direct-path check below before giving up
            }
        }

        // 3. LiveContainer fallback: if the last folder path is still directly readable (e.g. external data folder / shared container), restore it seamlessly!
        if let lastPath = UserDefaults.standard.string(forKey: lastVaultPathKey), !lastPath.isEmpty {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: lastPath, isDirectory: &isDir),
               isDir.boolValue,
               FileManager.default.isReadableFile(atPath: lastPath) {
                let url = URL(fileURLWithPath: lastPath, isDirectory: true)
                isUsingLocalFallback = false
                scopedRootURL = url
                vaultURL = resolveEffectiveVaultRoot(from: url)
                refreshPDFList()
                return
            } else if Self.isRunningInLiveContainer && !lastSavedVaultName.isEmpty {
                statusMessage = "LiveContainer reset external folder permission for \"\(lastSavedVaultName)\". Re-select the folder (with Fix File Picker enabled) or switch to LiveContainer App Folder + Drive Sync."
            }
        }
    }

    func ensureSecurityScopeActive() {
        if !accessingRoot, let url = scopedRootURL, !isUsingLocalFallback {
            accessingRoot = url.startAccessingSecurityScopedResource()
        }
    }

    func refreshPDFListAsync() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            refreshPDFList {
                cont.resume()
            }
        }
    }

    func refreshPDFList(completion: (() -> Void)? = nil) {
        ensureSecurityScopeActive()
        guard let root = vaultURL else {
            pdfs = []
            allFolders = []
            completion?()
            return
        }
        let fm = FileManager.default
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let jPaths = journalPaths
        let cColors = coverColors

        DispatchQueue.global(qos: .userInitiated).async {
            var foundPDFs: [PDFItem] = []
            var folderURLs: [String: URL] = [:]
            var folderPDFCounts: [String: Int] = [:]
            var scanErr: String?

            if !fm.isReadableFile(atPath: rootPath) {
                scanErr = "Cannot read folder \"\(root.lastPathComponent)\". Install directly via SideStore for full folder access."
            } else if let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let itemURL as URL in enumerator {
                    let stdPath = itemURL.standardizedFileURL.resolvingSymlinksInPath().path
                    let relPath: String
                    if stdPath.hasPrefix(rootPath) {
                        relPath = String(stdPath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    } else {
                        relPath = itemURL.lastPathComponent
                    }
                    if relPath.isEmpty { continue }

                    let vals = try? itemURL.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
                    if vals?.isDirectory == true {
                        // Skip `.ink.d` internal folders if any exist locally
                        if itemURL.lastPathComponent.hasSuffix(".ink.d") {
                            enumerator.skipDescendants()
                            continue
                        }
                        folderURLs[relPath] = itemURL
                        continue
                    }

                    guard itemURL.pathExtension.lowercased() == "pdf" else { continue }
                    let mod = vals?.contentModificationDate ?? Date.distantPast
                    let relFolder = (relPath as NSString).deletingLastPathComponent
                    let inkExists = fm.fileExists(atPath: itemURL.path + ".ink.json")
                    let lowerName = itemURL.lastPathComponent.lowercased()
                    let isHobo = jPaths.contains(relPath)
                        || (cColors[relPath] ?? 0) >= 100
                        || relPath.hasPrefix("Journals/")
                        || lowerName.contains("hobonichi")

                    foundPDFs.append(PDFItem(
                        id: stdPath,
                        url: itemURL,
                        name: itemURL.deletingPathExtension().lastPathComponent,
                        relativeFolder: relFolder,
                        relativePath: relPath,
                        modifiedAt: mod,
                        hasInk: inkExists,
                        isHobonichi: isHobo
                    ))

                    // Increment PDF count for every ancestor folder
                    var curDir = relFolder
                    while !curDir.isEmpty {
                        folderPDFCounts[curDir, default: 0] += 1
                        let parent = (curDir as NSString).deletingLastPathComponent
                        if parent == curDir { break }
                        curDir = parent
                    }
                }
            }

            foundPDFs.sort { $0.modifiedAt > $1.modifiedAt }
            let foldersList: [FolderItem] = folderURLs.map { rel, url in
                FolderItem(
                    id: rel,
                    url: url,
                    name: url.lastPathComponent,
                    relativePath: rel,
                    pdfCount: folderPDFCounts[rel] ?? 0
                )
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            DispatchQueue.main.async {
                self.pdfs = foundPDFs
                self.allFolders = foldersList
                if let err = scanErr {
                    self.statusMessage = err
                }
                completion?()
            }
        }
    }

    // MARK: - Cover Preview Thumbnails (Cached Page 1 PDF Preview)

    func cachedCoverThumb(for item: PDFItem) -> UIImage? {
        let key = "\(item.id)|\(Int(item.modifiedAt.timeIntervalSince1970))" as NSString
        return thumbCache.object(forKey: key)
    }

    func loadCoverThumb(for item: PDFItem, completion: @escaping (UIImage?) -> Void) {
        let key = "\(item.id)|\(Int(item.modifiedAt.timeIntervalSince1970))" as NSString
        if let hit = thumbCache.object(forKey: key) {
            completion(hit)
            return
        }
        // Hobonichi journals look crispest with their fabric book covers!
        if item.isHobonichi {
            completion(nil)
            return
        }
        let url = item.url
        thumbQueue.async { [weak self] in
            guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let sz = PageCanvasView.normalizedPageSize(for: page)
            guard sz.width > 0, sz.height > 0 else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let scale = min(1.0, 260.0 / sz.width)
            let slot = PageSlot(index: 0, key: "1", pdfN: 1, srcN: nil, blank: nil, size: sz)
            let img = PageCanvasView.renderSlotBackground(slot: slot, pdfDoc: doc, zoomScale: scale, maxPixels: 300_000)
            self?.thumbCache.setObject(img, forKey: key)
            DispatchQueue.main.async { completion(img) }
        }
    }

    // MARK: - File Creation & Vault Operations

    func directoryURL(for relativeFolder: String) -> URL? {
        guard let root = vaultURL else { return nil }
        let clean = relativeFolder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if clean.isEmpty { return root }
        return root.appendingPathComponent(clean, isDirectory: true)
    }

    private func uniqueFileURL(in dir: URL, baseName: String, ext: String) -> URL {
        let fm = FileManager.default
        let cleanBase = baseName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = cleanBase.isEmpty ? "Untitled" : cleanBase
        var candidate = dir.appendingPathComponent("\(stem).\(ext)")
        var i = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(stem) (\(i)).\(ext)")
            i += 1
        }
        return candidate
    }

    func createNotebook(title: String, template: PaperTemplate, coverID: Int, inFolder relativeFolder: String) throws -> (url: URL, relPath: String) {
        guard let dir = directoryURL(for: relativeFolder) else {
            throw NSError(domain: "VaultManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Select a vault folder first."])
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = uniqueFileURL(in: dir, baseName: title, ext: "pdf")
        let pdfData = HobonichiEngine.createNotebookPDF(template: template)
        try writeCoordinated(data: pdfData, to: target)
        let rel = relativePath(for: target)
        setCoverColor(for: rel, paletteID: coverID)
        refreshPDFList()
        return (target, rel)
    }

    func createHobonichiJournal(
        title: String,
        coverID: Int,
        startMode: String,
        initialWeeks: Int,
        inFolder relativeFolder: String
    ) throws -> (url: URL, relPath: String) {
        let targetFolder = relativeFolder.isEmpty ? "Journals" : relativeFolder
        guard let dir = directoryURL(for: targetFolder) else {
            throw NSError(domain: "VaultManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Select a vault folder first."])
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = uniqueFileURL(in: dir, baseName: title, ext: "pdf")
        let pdfData = HobonichiEngine.createHobonichiBasePDF()
        try writeCoordinated(data: pdfData, to: target)

        let cal = HobonichiEngine.calendar
        let now = Date()
        let startDate: Date
        if startMode == "year" {
            var c = DateComponents(); c.year = cal.component(.year, from: now); c.month = 1; c.day = 1
            startDate = cal.date(from: c) ?? now
        } else if startMode == "month" {
            var c = DateComponents(); c.year = cal.component(.year, from: now); c.month = cal.component(.month, from: now); c.day = 1
            startDate = cal.date(from: c) ?? now
        } else {
            startDate = now
        }

        let rel = relativePath(for: target)
        var doc = InkDocument.empty(name: rel)
        doc.bookmarks["__hobo__"] = PageMark(on: false, t: Int64(Date().timeIntervalSince1970 * 1000), title: "Hobonichi Weeks")
        let entries = HobonichiEngine.buildPlannerEntries(startDate: startDate, numWeeks: initialWeeks, existingBlanks: [:], startNotePages: 5)
        for e in entries { doc.blanks[e.id] = e }
        doc.layoutBlanks()
        try doc.save(for: target)

        setCoverColor(for: rel, paletteID: coverID)
        markAsJournal(rel)
        refreshPDFList()
        return (target, rel)
    }

    func createFolder(name: String, inFolder relativeFolder: String) throws {
        guard let dir = directoryURL(for: relativeFolder) else { return }
        let clean = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let target = dir.appendingPathComponent(clean, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        refreshPDFList()
    }

    func importPDFCopy(from sourceURL: URL, intoFolder relativeFolder: String) throws -> (url: URL, relPath: String) {
        guard let dir = directoryURL(for: relativeFolder) else {
            throw NSError(domain: "VaultManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Select a vault folder first."])
        }
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: sourceURL)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = uniqueFileURL(in: dir, baseName: sourceURL.deletingPathExtension().lastPathComponent, ext: "pdf")
        try writeCoordinated(data: data, to: target)
        let rel = relativePath(for: target)
        refreshPDFList()
        return (target, rel)
    }

    @discardableResult
    func renamePDF(_ item: PDFItem, newTitle: String) throws -> (url: URL, relPath: String, title: String)? {
        try renamePDF(at: item.url, oldRelativePath: item.relativePath, newTitle: newTitle)
    }

    @discardableResult
    func renamePDF(at sourceURL: URL, oldRelativePath: String, newTitle: String) throws -> (url: URL, relPath: String, title: String)? {
        let clean = newTitle
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let parent = sourceURL.deletingLastPathComponent()
        let dest = parent.appendingPathComponent("\(clean).pdf")
        if dest.standardizedFileURL.path == sourceURL.standardizedFileURL.path { return nil }
        if FileManager.default.fileExists(atPath: dest.path) {
            throw NSError(domain: "VaultManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "A file named \"\(clean).pdf\" already exists in this folder."])
        }
        try FileManager.default.moveItem(at: sourceURL, to: dest)

        let oldSidecar = InkDocument.sidecarURL(for: sourceURL)
        let newSidecar = InkDocument.sidecarURL(for: dest)
        let newRel = relativePath(for: dest)
        if FileManager.default.fileExists(atPath: oldSidecar.path) {
            try? FileManager.default.moveItem(at: oldSidecar, to: newSidecar)
            var doc = InkDocument.load(for: dest)
            doc.name = newRel
            try? doc.save(for: dest)
        }

        // Preserve remembered reading page across the rename
        let oldPageKey = "pencilink.lastpage." + sourceURL.lastPathComponent
        let newPageKey = "pencilink.lastpage." + dest.lastPathComponent
        let savedPage = UserDefaults.standard.integer(forKey: oldPageKey)
        if savedPage > 0 {
            UserDefaults.standard.set(savedPage, forKey: newPageKey)
            UserDefaults.standard.removeObject(forKey: oldPageKey)
        }

        if let col = coverColors.removeValue(forKey: oldRelativePath) {
            coverColors[newRel] = col
        }
        if journalPaths.remove(oldRelativePath) != nil {
            journalPaths.insert(newRel)
        }
        if favoritePaths.remove(oldRelativePath) != nil {
            favoritePaths.insert(newRel)
        }
        recentPaths = recentPaths.map { $0 == oldRelativePath ? newRel : $0 }
        saveMetadata()
        refreshPDFList()
        return (dest, newRel, clean)
    }

    func duplicatePDF(_ item: PDFItem) throws {
        let parent = item.url.deletingLastPathComponent()
        let dest = uniqueFileURL(in: parent, baseName: "\(item.name) (copy)", ext: "pdf")
        try FileManager.default.copyItem(at: item.url, to: dest)
        let oldSidecar = InkDocument.sidecarURL(for: item.url)
        if FileManager.default.fileExists(atPath: oldSidecar.path) {
            var doc = InkDocument.load(for: item.url)
            doc.name = relativePath(for: dest)
            try? doc.save(for: dest)
        }
        let newRel = relativePath(for: dest)
        if let col = coverColors[item.relativePath] { coverColors[newRel] = col }
        if item.isHobonichi { journalPaths.insert(newRel) }
        saveMetadata()
        refreshPDFList()
    }

    func deletePDF(_ item: PDFItem) throws {
        try FileManager.default.removeItem(at: item.url)
        let sidecar = InkDocument.sidecarURL(for: item.url)
        if FileManager.default.fileExists(atPath: sidecar.path) {
            try? FileManager.default.removeItem(at: sidecar)
        }
        coverColors.removeValue(forKey: item.relativePath)
        journalPaths.remove(item.relativePath)
        favoritePaths.remove(item.relativePath)
        recentPaths.removeAll { $0 == item.relativePath }
        saveMetadata()
        refreshPDFList()
    }

    /// Installs a PDF streamed from Google Drive into `<vaultRoot>/<relativePath>`, creating any missing subfolders
    /// and falling back cleanly from NSFileCoordinator to direct atomic copy if running inside LiveContainer.
    func installDownloadedPDF(from tempURL: URL, relativePath: String, modifiedAt: Date? = nil) throws -> URL {
        ensureSecurityScopeActive()
        guard let root = vaultURL else {
            throw NSError(domain: "VaultManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Select a vault folder first."])
        }
        let cleanRel = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let dest = root.appendingPathComponent(cleanRel, isDirectory: false)
        let parentDir = dest.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        var coordError: NSError?
        var copyError: Error?
        var didCopy = false
        NSFileCoordinator().coordinate(writingItemAt: dest, options: .forReplacing, error: &coordError) { coordURL in
            do {
                if FileManager.default.fileExists(atPath: coordURL.path) {
                    try FileManager.default.removeItem(at: coordURL)
                }
                try FileManager.default.copyItem(at: tempURL, to: coordURL)
                didCopy = true
            } catch {
                copyError = error
            }
        }
        if !didCopy || copyError != nil || coordError != nil {
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: tempURL, to: dest)
            } catch {
                throw copyError ?? coordError ?? error
            }
        }
        if let mod = modifiedAt {
            try? FileManager.default.setAttributes([.modificationDate: mod], ofItemAtPath: dest.path)
        }
        try? FileManager.default.removeItem(at: tempURL)
        return dest
    }

    private func writeCoordinated(data: Data, to url: URL) throws {
        ensureSecurityScopeActive()
        let parentDir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        var coordError: NSError?
        var writeError: Error?
        var didWrite = false
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { coordURL in
            do {
                try data.write(to: coordURL, options: .atomic)
                didWrite = true
            } catch {
                writeError = error
            }
        }
        if !didWrite || writeError != nil || coordError != nil {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                throw writeError ?? coordError ?? error
            }
        }
    }
}
