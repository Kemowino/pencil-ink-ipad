import Foundation
import SwiftUI

enum SyncVisualState: String {
    case disconnected
    case ok
    case syncing
    case error
}

struct BookSyncSnapshot: Codable {
    var strokes: [String: String] = [:]     // strokeId -> pageKey
    var blanks: [String: BlankPage] = [:]
    var bookmarks: [String: PageMark] = [:]
    var removed: [String: PageMark] = [:]
    var texts: [String: [InkTextBox]] = [:]

    enum CodingKeys: String, CodingKey { case strokes, blanks, bookmarks, removed, texts }
    init(
        strokes: [String: String] = [:],
        blanks: [String: BlankPage] = [:],
        bookmarks: [String: PageMark] = [:],
        removed: [String: PageMark] = [:],
        texts: [String: [InkTextBox]] = [:]
    ) {
        self.strokes = strokes
        self.blanks = blanks
        self.bookmarks = bookmarks
        self.removed = removed
        self.texts = texts
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        strokes = (try? c.decode([String: String].self, forKey: .strokes)) ?? [:]
        blanks = (try? c.decode([String: BlankPage].self, forKey: .blanks)) ?? [:]
        bookmarks = (try? c.decode([String: PageMark].self, forKey: .bookmarks)) ?? [:]
        removed = (try? c.decode([String: PageMark].self, forKey: .removed)) ?? [:]
        texts = (try? c.decode([String: [InkTextBox]].self, forKey: .texts)) ?? [:]
    }
}

struct RemoteLogEntry: Codable, Sendable {
    var key: String?
    var strokes: [InkStroke]?
    var blanks: [BlankPage]?
    var erased: [String: Int64]?
    var bookmarks: [String: PageMark]?
    var removed: [String: PageMark]?
    var texts: [String: [InkTextBox]]?
}

struct BookLogState: Codable {
    var label: String
    var folderId: String = ""
    var own: [String: [InkStroke]] = [:]
    var ownBlanks: [String: BlankPage] = [:]
    var ownBookmarks: [String: PageMark] = [:]
    var ownRemoved: [String: PageMark] = [:]
    var ownTexts: [String: [InkTextBox]] = [:]
    var erased: [String: Int64] = [:]
    var dirty: [String] = []
    var ids: [String: String] = [:]
    var seenMd5: [String: String] = [:]
    var base: BookSyncSnapshot? = nil

    enum CodingKeys: String, CodingKey {
        case label, folderId, own, ownBlanks, ownBookmarks, ownRemoved, ownTexts, erased, dirty, ids, seenMd5, base
    }

    init(label: String) {
        self.label = label
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = (try? c.decode(String.self, forKey: .label)) ?? "ios"
        folderId = (try? c.decode(String.self, forKey: .folderId)) ?? ""
        own = (try? c.decode([String: [InkStroke]].self, forKey: .own)) ?? [:]
        ownBlanks = (try? c.decode([String: BlankPage].self, forKey: .ownBlanks)) ?? [:]
        ownBookmarks = (try? c.decode([String: PageMark].self, forKey: .ownBookmarks)) ?? [:]
        ownRemoved = (try? c.decode([String: PageMark].self, forKey: .ownRemoved)) ?? [:]
        ownTexts = (try? c.decode([String: [InkTextBox]].self, forKey: .ownTexts)) ?? [:]
        erased = (try? c.decode([String: Int64].self, forKey: .erased)) ?? [:]
        dirty = (try? c.decode([String].self, forKey: .dirty)) ?? []
        ids = (try? c.decode([String: String].self, forKey: .ids)) ?? [:]
        seenMd5 = (try? c.decode([String: String].self, forKey: .seenMd5)) ?? [:]
        base = try? c.decode(BookSyncSnapshot.self, forKey: .base)
    }

    static func pageFile(label: String, key: String) -> String {
        "log_\(label)_p\(key.replacingOccurrences(of: ":", with: "~")).json"
    }
    static func blanksFile(label: String) -> String { "log_\(label)_blanks.json" }
    static func marksFile(label: String) -> String { "log_\(label)_marks.json" }
    static func eraseFile(label: String) -> String { "log_\(label)_erase.json" }
    static func textsFile(label: String) -> String { "txt_\(label).json" }
    static func keyOfFile(_ name: String) -> String {
        guard let r = name.range(of: "_p") else { return "1" }
        var tail = String(name[r.upperBound...])
        if tail.hasSuffix(".json") { tail.removeLast(5) }
        return tail.replacingOccurrences(of: "~", with: ":")
    }

    mutating func markDirty(_ name: String) {
        if !dirty.contains(name) { dirty.append(name) }
    }

    mutating func addOwnStroke(pageKey: String, stroke: InkStroke) {
        var list = own[pageKey] ?? []
        if list.contains(where: { $0.id == stroke.id }) { return }
        list.append(stroke)
        own[pageKey] = list
        markDirty(Self.pageFile(label: label, key: pageKey))
    }

    mutating func pruneOwnStroke(id: String) {
        for key in Array(own.keys) {
            guard var list = own[key], list.contains(where: { $0.id == id }) else { continue }
            list.removeAll { $0.id == id }
            own[key] = list
            markDirty(Self.pageFile(label: label, key: key))
        }
    }

    mutating func eraseOwn(id: String, nowMs: Int64) {
        if erased[id] == nil {
            erased[id] = nowMs
        }
        markDirty(Self.eraseFile(label: label))
        if ownBlanks[id] != nil {
            ownBlanks.removeValue(forKey: id)
            markDirty(Self.blanksFile(label: label))
        }
        let bKey = "b:" + id
        if let bStrokes = own[bKey], !bStrokes.isEmpty {
            own[bKey] = []
            markDirty(Self.pageFile(label: label, key: bKey))
        }
        pruneOwnStroke(id: id)
    }
}

/// Manages fast, bidirectional Google Drive CRDT delta sync for Pencil Ink Native.
/// Fully compatible with Obsidian Pencil Ink's `.ink.d` folder & `log_<device>_*.json` format.
@MainActor
final class DriveSyncManager: ObservableObject {
    @Published var config: DriveConfig
    @Published var visualState: SyncVisualState = .disconnected
    @Published var statusText: String = "Not Connected"
    @Published var lastError: String = ""
    @Published var lastDiagnostic: String = ""
    @Published var lastSyncedAt: Date? = nil
    @Published var sessionBytesUp: Int64 = 0
    @Published var sessionBytesDown: Int64 = 0
    @Published var sessionBooksSynced: Int = 0
    @Published var activeBookName: String = ""

    private let configKey = "pencilink.native.drive.config.v1"
    private let client: GoogleDriveClient
    private var logStates: [String: BookLogState] = [:]
    private var logSeen: [String: [String: RemoteLogEntry]] = [:]
    private struct PendingFollowup {
        let pdfURL: URL
        let relativePath: String
        let localDocProvider: () -> InkDocument
        let onMerged: (InkDocument) -> Void
    }

    private var folderCheckAt: [String: Date] = [:]
    private var extraFolderCache: [String: [String]] = [:]
    private var resolvedPathCache: [String: String] = [:]
    private var activeSyncTasks: [String: Task<(InkDocument, Bool, Bool), Error>] = [:]
    private var pendingFollowups: [String: PendingFollowup] = [:]
    private var debounceTimers: [String: DispatchWorkItem] = [:]

    init() {
        var loaded: DriveConfig
        if let data = UserDefaults.standard.data(forKey: "pencilink.native.drive.config.v1"),
           let decoded = try? JSONDecoder().decode(DriveConfig.self, from: data) {
            loaded = decoded
        } else {
            loaded = DriveConfig()
        }
        if loaded.deviceLabel.isEmpty {
            loaded.deviceLabel = DriveSyncManager.generateDeviceLabel()
        }
        self.config = loaded
        self.client = GoogleDriveClient(config: loaded) { updated in
            if let encoded = try? JSONEncoder().encode(updated) {
                UserDefaults.standard.set(encoded, forKey: "pencilink.native.drive.config.v1")
            }
        }
        self.visualState = loaded.isConnected ? .ok : .disconnected
        self.statusText = loaded.isConnected ? "Synced" : "Not Connected"
        Task { [weak self] in
            guard let self else { return }
            await self.client.setOnConfigUpdated { [weak self] updated in
                if let encoded = try? JSONEncoder().encode(updated) {
                    UserDefaults.standard.set(encoded, forKey: "pencilink.native.drive.config.v1")
                }
                Task { @MainActor [weak self] in
                    guard let self, self.config.refreshToken == updated.refreshToken else { return }
                    self.config.accessToken = updated.accessToken
                    self.config.expiresAt = updated.expiresAt
                }
            }
        }
    }

    private static func generateDeviceLabel() -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        #if targetEnvironment(macCatalyst)
        let prefix = "mac"
        #else
        let prefix = "ios"
        #endif
        return prefix + String((0..<6).map { _ in chars.randomElement()! })
    }

    func saveConfig() {
        if config.deviceLabel.isEmpty {
            config.deviceLabel = Self.generateDeviceLabel()
        }
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: configKey)
        }
        let cfg = config
        Task {
            await client.updateConfig(cfg)
        }
        if !config.isConnected {
            visualState = .disconnected
            statusText = "Not Connected"
        } else if visualState == .disconnected {
            visualState = .ok
            statusText = "Synced"
        }
    }

    func disconnect() {
        config.accessToken = ""
        config.refreshToken = ""
        config.expiresAt = 0
        lastError = ""
        lastDiagnostic = ""
        saveConfig()
        visualState = .disconnected
        statusText = "Not Connected"
    }

    // MARK: - Device Key Codec (100% Compatible with Obsidian Pencil Ink `PENCIL-INK-DEVICE:...`)

    static let deviceKeyPrefix = "PENCIL-INK-DEVICE:"

    private struct DeviceKeyPayload: Codable {
        var v: Int?
        var clientId: String
        var clientSecret: String
        var refreshToken: String?
        var accessToken: String?
        var expiresAt: Double?
        var driveFolder: String?
    }

    func encodeDeviceKey() -> String? {
        let cid = config.clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let csec = config.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cid.isEmpty, !csec.isEmpty else { return nil }
        let payload = DeviceKeyPayload(
            v: 1,
            clientId: cid,
            clientSecret: csec,
            refreshToken: config.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines),
            accessToken: config.accessToken.trimmingCharacters(in: .whitespacesAndNewlines),
            expiresAt: config.expiresAt,
            driveFolder: config.driveFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Obsidian Vault"
                : config.driveFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard let jsonData = try? JSONEncoder().encode(payload) else { return nil }
        return Self.deviceKeyPrefix + jsonData.base64EncodedString()
    }

    func applyDeviceKey(_ raw: String) -> (ok: Bool, message: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(Self.deviceKeyPrefix) else {
            return (false, "Invalid Device Key. Make sure it starts with PENCIL-INK-DEVICE:")
        }
        let b64 = String(trimmed.dropFirst(Self.deviceKeyPrefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
              let parsed = try? JSONDecoder().decode(DeviceKeyPayload.self, from: data) else {
            return (false, "Could not decode Device Key. Copy the entire key again from Obsidian.")
        }
        let cid = parsed.clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let csec = parsed.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cid.isEmpty, !csec.isEmpty else {
            return (false, "Device Key is missing Client ID or Client Secret.")
        }

        config.clientId = cid
        config.clientSecret = csec
        if let rt = parsed.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines), !rt.isEmpty {
            config.refreshToken = rt
            config.accessToken = (parsed.accessToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            config.expiresAt = parsed.expiresAt ?? 0
        }
        if let df = parsed.driveFolder?.trimmingCharacters(in: .whitespacesAndNewlines), !df.isEmpty {
            config.driveFolder = df
        }
        lastError = ""
        folderCheckAt.removeAll()
        extraFolderCache.removeAll()
        resolvedPathCache.removeAll()
        saveConfig()
        if config.isConnected {
            visualState = .ok
            statusText = "Connected"
            return (true, "Device linked & Google Drive connected! Folder: \(config.driveFolder)")
        } else {
            return (true, "Google app credentials imported! Tap Open Google Sign-In below to finish connecting.")
        }
    }

    func verifyDriveConnection() async -> (ok: Bool, message: String) {
        guard config.isConnected else {
            return (false, "Not signed in to Google Drive yet.")
        }
        await client.updateConfig(config)
        visualState = .syncing
        statusText = "Checking Drive…"
        do {
            _ = try await client.resolveRootFolderID()
            lastError = ""
            visualState = .ok
            statusText = "Synced"
            return (true, "Connected to Google Drive folder \"\(config.driveFolder)\"!")
        } catch {
            lastError = error.localizedDescription
            if let de = error as? DriveClientError, de.isFatalAuth {
                visualState = .disconnected
                statusText = "Sign-In Expired"
            } else {
                visualState = .error
                statusText = "Sync Error"
            }
            return (false, "Connection check failed: \(error.localizedDescription)")
        }
    }

    func beginOAuth() -> (url: URL, verifier: String)? {
        saveConfig()
        guard !config.clientId.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return GoogleDriveClient.beginAuth(clientId: config.clientId)
    }

    func finishOAuth(pasted: String, verifier: String) async throws {
        saveConfig()
        let updated = try await client.finishAuth(pasted: pasted, verifier: verifier)
        config = updated
        lastError = ""
        saveConfig()
        visualState = .ok
        statusText = "Synced"
    }

    func formatBytes(_ bytes: Int64) -> String {
        let b = max(0, Double(bytes))
        if b < 1024 { return "\(Int(b)) B" }
        if b < 1024 * 1024 { return String(format: "%.1f KB", b / 1024.0) }
        return String(format: "%.2f MB", b / 1_048_576.0)
    }

    // MARK: - Fast Debounced Auto-Push & Live Book Sync

    func cancelScheduledSync(for relativePath: String) {
        let inkRelPath = relativePath.hasSuffix(".ink.json") ? relativePath : (relativePath + ".ink.json")
        debounceTimers[inkRelPath]?.cancel()
        debounceTimers.removeValue(forKey: inkRelPath)
    }

    func scheduleBookSync(
        pdfURL: URL,
        relativePath: String,
        delaySeconds: TimeInterval = 4.0,
        localDocProvider: @escaping () -> InkDocument,
        onMerged: @escaping (InkDocument) -> Void
    ) {
        guard config.isConnected, config.autoSync, AppSettings.shared.syncMode == .smart else { return }
        let inkRelPath = relativePath.hasSuffix(".ink.json") ? relativePath : (relativePath + ".ink.json")
        debounceTimers[inkRelPath]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.debounceTimers.removeValue(forKey: inkRelPath)
            if self.activeSyncTasks[inkRelPath] != nil {
                self.pendingFollowups[inkRelPath] = PendingFollowup(
                    pdfURL: pdfURL,
                    relativePath: relativePath,
                    localDocProvider: localDocProvider,
                    onMerged: onMerged
                )
                return
            }
            let localDoc = localDocProvider()
            Task { @MainActor in
                if let (merged, changed) = await self.syncBook(
                    pdfURL: pdfURL,
                    relativePath: relativePath,
                    localDoc: localDoc,
                    forceFolderScan: false
                ), changed {
                    onMerged(merged)
                }
            }
        }
        debounceTimers[inkRelPath] = item
        // Smart idle debounce (4s default): batches continuous writing/typing into ONE clean upload!
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.2, delaySeconds), execute: item)
    }

    /// Translates a local PDF rename to Google Drive (renaming `<Book.pdf.ink.d>`, `<Book.pdf>`, and `<Book.pdf.ink.json>` if present)
    /// and migrates the local CRDT log state so other devices & Obsidian seamlessly follow the rename without duplicating strokes.
    @discardableResult
    func renameBookOnDrive(oldRelativePath: String, newRelativePath: String) async -> Bool {
        let oldInk = oldRelativePath.hasSuffix(".ink.json") ? oldRelativePath : (oldRelativePath + ".ink.json")
        let newInk = newRelativePath.hasSuffix(".ink.json") ? newRelativePath : (newRelativePath + ".ink.json")
        if oldInk == newInk { return true }

        // 1. Cancel any pending timers for the old path & migrate local CRDT log state file
        debounceTimers[oldInk]?.cancel()
        debounceTimers.removeValue(forKey: oldInk)
        pendingFollowups.removeValue(forKey: oldInk)

        let oldStateURL = logStateURL(for: oldInk)
        let newStateURL = logStateURL(for: newInk)
        var migratedState = logStates.removeValue(forKey: oldInk)
        if migratedState == nil,
           let data = try? Data(contentsOf: oldStateURL),
           let decoded = try? JSONDecoder().decode(BookLogState.self, from: data) {
            migratedState = decoded
        }
        if let st = migratedState {
            logStates[newInk] = st
            saveLogState(st, for: newInk)
        }
        try? FileManager.default.removeItem(at: oldStateURL)

        if let seen = logSeen.removeValue(forKey: oldInk) {
            logSeen[newInk] = seen
        }
        if let extra = extraFolderCache.removeValue(forKey: oldInk) {
            extraFolderCache[newInk] = extra
        }
        folderCheckAt.removeValue(forKey: oldInk)
        resolvedPathCache.removeValue(forKey: oldInk)

        guard config.isConnected else { return false }

        let oldPDFName = (oldRelativePath as NSString).lastPathComponent
        let newPDFName = (newRelativePath as NSString).lastPathComponent
        let oldInkName = (oldInk as NSString).lastPathComponent
        let newInkName = (newInk as NSString).lastPathComponent
        let oldFolderName = oldInkName.hasSuffix(".json") ? String(oldInkName.dropLast(5)) + ".d" : oldInkName + ".d"
        let newFolderName = newInkName.hasSuffix(".json") ? String(newInkName.dropLast(5)) + ".d" : newInkName + ".d"
        let dir = (oldRelativePath as NSString).deletingLastPathComponent
        let cleanDir = (dir == "." || dir == "/") ? "" : dir

        await client.updateConfig(config)
        visualState = .syncing
        statusText = "Renaming on Drive…"

        do {
            let rootID = try await client.resolveRootFolderID()
            var parentIDs = Set<String>()
            var renamedAny = false

            // Rename all matching `<OldBook.pdf.ink.d>` folders under sync root
            var folderIDsToRename = Set<String>()
            if let cachedID = migratedState?.folderId, !cachedID.isEmpty {
                folderIDsToRename.insert(cachedID)
            }
            let foundFolders = try await client.findFoldersNamed(oldFolderName)
            for f in foundFolders {
                if let _ = try await client.resolvePathUnderRoot(folder: f, rootID: rootID) {
                    folderIDsToRename.insert(f.id)
                    if let pid = f.parents?.first { parentIDs.insert(pid) }
                }
            }
            for fid in folderIDsToRename {
                if let meta = try? await client.getFile(id: fid), let pid = meta.parents?.first {
                    parentIDs.insert(pid)
                }
                _ = try await client.renameFile(fileID: fid, newName: newFolderName)
                renamedAny = true
            }

            // Also resolve parent directory by path in case the PDF exists on Drive even without an `.ink.d` folder yet
            if parentIDs.isEmpty {
                if cleanDir.isEmpty {
                    parentIDs.insert(rootID)
                } else {
                    let segments = cleanDir.split(separator: "/").map(String.init)
                    var cur = rootID
                    var ok = true
                    for seg in segments {
                        let matches = try await client.findChildren(parentID: cur, name: seg, mimeType: GoogleDriveClient.folderMime)
                        if let first = matches.sorted(by: { $0.id < $1.id }).first {
                            cur = first.id
                        } else {
                            ok = false
                            break
                        }
                    }
                    if ok { parentIDs.insert(cur) }
                }
            }

            // Rename `<OldBook.pdf>` and legacy `<OldBook.pdf.ink.json>` inside the Drive parent directory
            for pid in parentIDs {
                let pdfMatches = try await client.findChildren(parentID: pid, name: oldPDFName)
                for f in pdfMatches {
                    _ = try await client.renameFile(fileID: f.id, newName: newPDFName)
                    renamedAny = true
                }
                let legacyInkMatches = try await client.findChildren(parentID: pid, name: oldInkName)
                for f in legacyInkMatches {
                    _ = try await client.renameFile(fileID: f.id, newName: newInkName)
                    renamedAny = true
                }
            }

            lastError = ""
            visualState = .ok
            statusText = "Synced"
            if renamedAny {
                lastSyncedAt = Date()
            }
            return renamedAny
        } catch {
            lastError = error.localizedDescription
            visualState = .error
            statusText = "Sync Error"
            return false
        }
    }

    func syncBook(
        pdfURL: URL,
        relativePath: String,
        localDoc: InkDocument,
        forceFolderScan: Bool = false
    ) async -> (InkDocument, Bool)? {
        guard config.isConnected else { return nil }
        let inkRelPath = relativePath.hasSuffix(".ink.json") ? relativePath : (relativePath + ".ink.json")
        if let running = activeSyncTasks[inkRelPath] {
            if let res = try? await running.value {
                return (res.0, res.1)
            }
            return nil
        }

        visualState = .syncing
        activeBookName = pdfURL.deletingPathExtension().lastPathComponent
        statusText = "Syncing \(activeBookName)…"

        let currentCfg = config
        let task = Task<(InkDocument, Bool, Bool), Error> { [weak self] in
            guard let self else { throw DriveClientError.notConnected }
            await self.client.updateConfig(currentCfg)
            return try await self.performBookSync(
                pdfURL: pdfURL,
                inkRelPath: inkRelPath,
                localDoc: localDoc,
                forceFolderScan: forceFolderScan
            )
        }
        activeSyncTasks[inkRelPath] = task

        do {
            let result = try await task.value
            activeSyncTasks.removeValue(forKey: inkRelPath)
            let totals = await client.getTransferTotals()
            sessionBytesUp = totals.up
            sessionBytesDown = totals.down
            if result.2 {
                sessionBooksSynced += 1
            }
            lastSyncedAt = Date()
            lastError = ""
            if activeSyncTasks.isEmpty {
                activeBookName = ""
                visualState = .ok
                statusText = "Synced"
            }
            // If new strokes arrived while this sync was in flight, push them immediately!
            if let next = pendingFollowups.removeValue(forKey: inkRelPath) {
                Task { @MainActor in
                    let latestDoc = next.localDocProvider()
                    if let (merged, changed) = await self.syncBook(
                        pdfURL: next.pdfURL,
                        relativePath: next.relativePath,
                        localDoc: latestDoc,
                        forceFolderScan: false
                    ), changed {
                        next.onMerged(merged)
                    }
                }
            }
            return (result.0, result.1)
        } catch {
            activeSyncTasks.removeValue(forKey: inkRelPath)
            pendingFollowups.removeValue(forKey: inkRelPath)
            lastError = error.localizedDescription
            activeBookName = ""
            if let de = error as? DriveClientError, de.isFatalAuth {
                visualState = .disconnected
                statusText = "Sign-In Expired"
            } else {
                visualState = .error
                statusText = "Sync Error"
            }
            return nil
        }
    }

    func syncAllAnnotatedBooks(vault: VaultManager) async {
        guard config.isConnected, let root = vault.vaultURL else { return }
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let annotated = vault.pdfs.filter { $0.hasInk }
        guard !annotated.isEmpty else {
            lastSyncedAt = Date()
            visualState = .ok
            statusText = "Synced"
            return
        }
        for item in annotated {
            let itemPath = item.url.standardizedFileURL.resolvingSymlinksInPath().path
            let rel: String
            if itemPath.hasPrefix(rootPath) {
                rel = String(itemPath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            } else {
                rel = item.url.lastPathComponent
            }
            let local = InkDocument.load(for: item.url)
            if let (merged, changed) = await syncBook(pdfURL: item.url, relativePath: rel, localDoc: local, forceFolderScan: true), changed {
                try? merged.save(for: item.url)
            }
        }
    }

    // MARK: - Core Bidirectional CRDT Sync (Exact Match to Obsidian `src/logs.ts` & `src/sync.ts`)

    private func performBookSync(
        pdfURL: URL,
        inkRelPath: String,
        localDoc: InkDocument,
        forceFolderScan: Bool
    ) async throws -> (InkDocument, Bool, Bool) {
        let rawDir = (inkRelPath as NSString).deletingLastPathComponent
        let dir = (rawDir == "." || rawDir == "/") ? "" : rawDir
        let fileName = (inkRelPath as NSString).lastPathComponent
        let folderName = fileName.hasSuffix(".json")
            ? String(fileName.dropLast(5)) + ".d"
            : fileName + ".d"
        let expectedDrivePath = dir.isEmpty ? folderName : "\(dir)/\(folderName)"

        var st = loadLogState(for: inkRelPath)
        var seen = logSeen[inkRelPath] ?? [:]

        // 1. Smart Folder Discovery under Drive sync root:
        //    Finds ALL `<Book.pdf.ink.d>` folders under `rootID` — automatically matching MacBook's
        //    existing folder even if the iPad vault root had an extra parent folder (like `My Notes/`)!
        let needFolderScan = forceFolderScan
            || st.folderId.isEmpty
            || (folderCheckAt[inkRelPath].map { Date().timeIntervalSince($0) > 25 } ?? true)

        var folderID = st.folderId
        var extraFolderIDs = extraFolderCache[inkRelPath] ?? []
        var resolvedPath = resolvedPathCache[inkRelPath] ?? expectedDrivePath
        var preloadedListing: [DriveFileMeta]? = nil

        if needFolderScan {
            let rootID = try await client.resolveRootFolderID()
            let allNamed = try await client.findFoldersNamed(folderName)
            var byPath: [String: [DriveFileMeta]] = [:]
            for f in allNamed {
                if let rel = try await client.resolvePathUnderRoot(folder: f, rootID: rootID) {
                    byPath[rel, default: []].append(f)
                }
            }
            for k in byPath.keys {
                byPath[k]?.sort { $0.id < $1.id }
            }

            var chosenPath: String? = nil
            var chosenFolders: [DriveFileMeta] = []

            if byPath.count == 1, let only = byPath.first {
                // Only one matching book folder exists under Drive root -> ALWAYS use it!
                chosenPath = only.key
                chosenFolders = only.value
            } else if byPath.count > 1 {
                // Multiple paths exist (e.g. MacBook's `Anesthesia/...` AND a stray `My Notes/Anesthesia/...`).
                // Pick the path that actually has remote shards from another device, preferring exact match on tie!
                var bestPath = ""
                var bestScore = -1
                var bestListing: [DriveFileMeta]? = nil
                for (path, group) in byPath {
                    let ids = group.map { $0.id }
                    let kids = try await client.listChildren(parentIDs: ids)
                    let remoteShards = kids.filter { $0.name.hasPrefix("log_") && !$0.name.hasPrefix("log_\(st.label)_") }.count
                    let exactBonus = (path == expectedDrivePath) ? 2 : 0
                    let shorterBonus = (path.count < expectedDrivePath.count && expectedDrivePath.hasSuffix("/" + path)) ? 1 : 0
                    let score = remoteShards * 100 + exactBonus + shorterBonus
                    if score > bestScore {
                        bestScore = score
                        bestPath = path
                        chosenFolders = group
                        bestListing = kids
                    }
                }
                chosenPath = bestPath
                preloadedListing = bestListing
            }

            if let first = chosenFolders.first {
                if !folderID.isEmpty && folderID != first.id {
                    // Switched from an isolated/stray folder to the real MacBook folder!
                    // Re-upload our own local strokes & marks into the canonical folder cleanly.
                    st.ids.removeAll()
                    seen.removeAll()
                    st.seenMd5.removeAll()
                    for key in st.own.keys { st.markDirty(BookLogState.pageFile(label: st.label, key: key)) }
                    if !st.erased.isEmpty { st.markDirty(BookLogState.eraseFile(label: st.label)) }
                    if !st.ownBlanks.isEmpty { st.markDirty(BookLogState.blanksFile(label: st.label)) }
                    if !st.ownBookmarks.isEmpty || !st.ownRemoved.isEmpty { st.markDirty(BookLogState.marksFile(label: st.label)) }
                    if !st.ownTexts.isEmpty { st.markDirty(BookLogState.textsFile(label: st.label)) }
                }
                folderID = first.id
                extraFolderIDs = chosenFolders.dropFirst().map { $0.id }
                resolvedPath = chosenPath ?? expectedDrivePath
            } else {
                // Brand new book never synced before -> create at expectedDrivePath
                let parentID = try await client.ensureRemoteDir(relativeDir: dir)
                let made = try await client.createFolder(name: folderName, parentID: parentID)
                folderID = made.id
                extraFolderIDs = []
                resolvedPath = expectedDrivePath
            }

            st.folderId = folderID
            extraFolderCache[inkRelPath] = extraFolderIDs
            resolvedPathCache[inkRelPath] = resolvedPath
            folderCheckAt[inkRelPath] = Date()
        }

        let allFolderIDs = [folderID] + extraFolderIDs
        let listing: [DriveFileMeta]
        if let pre = preloadedListing {
            listing = pre
        } else {
            listing = try await client.listChildren(parentIDs: allFolderIDs)
        }
        let hadFormat = listing.contains { $0.name == "format.json" }

        // Map our own existing log files inside canonical primary folder & flag duplicates
        var duplicateIDs: [String] = []
        let ownTextsFileName = BookLogState.textsFile(label: st.label)
        for f in listing where f.name.hasPrefix("log_\(st.label)_") || f.name == ownTextsFileName {
            let inPrimary = (f.parents?.contains(folderID) ?? true)
            if inPrimary {
                if st.ids[f.name] == nil {
                    st.ids[f.name] = f.id
                } else if st.ids[f.name] != f.id {
                    duplicateIDs.append(f.id)
                }
            }
        }

        // 2. Pull ALL other devices' changed `log_*` files across ALL matching folders in parallel!
        var remoteGroups: [String: [DriveFileMeta]] = [:]
        for f in listing {
            let isRemoteLog = f.name.hasPrefix("log_") && !f.name.hasPrefix("log_\(st.label)_")
            let isRemoteTxt = f.name.hasPrefix("txt_") && f.name.hasSuffix(".json") && f.name != ownTextsFileName
            if !isRemoteLog && !isRemoteTxt { continue }
            remoteGroups[f.name, default: []].append(f)
        }

        if forceFolderScan {
            st.seenMd5.removeAll()
        }

        var toDownload: [(name: String, group: [DriveFileMeta])] = []
        for (name, group) in remoteGroups {
            if group.count == 1, seen[name] != nil {
                let rev = "\(group[0].md5Checksum ?? "")|\(group[0].modifiedTime ?? "")"
                if !rev.isEmpty && st.seenMd5[name] == rev {
                    continue
                }
            }
            toDownload.append((name, group))
        }

        var parseFailures = 0
        var downloadedCount = 0

        if !toDownload.isEmpty {
            let clientRef = self.client
            let results: [(String, RemoteLogEntry?, String?, Bool)] = try await withThrowingTaskGroup(
                of: (String, RemoteLogEntry?, String?, Bool).self
            ) { groupTask in
                for item in toDownload {
                    groupTask.addTask {
                        var combined: RemoteLogEntry? = nil
                        var unreadable = false
                        for f in item.group {
                            let bytes = try await clientRef.download(fileID: f.id)
                            if let parsed = DriveSyncManager.parseRemoteEntryStatic(name: item.name, bytes: bytes) {
                                combined = DriveSyncManager.combineRemoteEntriesStatic(combined, parsed)
                            } else {
                                unreadable = true
                            }
                        }
                        let rev: String? = (item.group.count == 1 && !unreadable)
                            ? "\(item.group[0].md5Checksum ?? "")|\(item.group[0].modifiedTime ?? "")"
                            : nil
                        return (item.name, combined, rev, unreadable)
                    }
                }
                var collected: [(String, RemoteLogEntry?, String?, Bool)] = []
                for try await r in groupTask {
                    collected.append(r)
                }
                return collected
            }

            for (name, entry, rev, unreadable) in results {
                downloadedCount += 1
                if unreadable { parseFailures += 1 }
                if let e = entry {
                    seen[name] = e
                    if let r = rev, !r.isEmpty {
                        st.seenMd5[name] = r
                    } else {
                        st.seenMd5.removeValue(forKey: name)
                    }
                }
            }
        }

        // Remove any deleted remote files from `seen`
        for name in Array(seen.keys) where remoteGroups[name] == nil {
            seen.removeValue(forKey: name)
            st.seenMd5.removeValue(forKey: name)
        }

        // 3. Diff local document into our device's append-only CRDT log
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let remoteView = seen.isEmpty ? nil : deriveDoc(st: BookLogState(label: st.label), seen: seen, name: localDoc.name)
        let isJoining = (st.base == nil)

        if isJoining {
            let currentView = deriveDoc(st: st, seen: seen, name: localDoc.name)
            joinLocal(st: &st, local: localDoc, view: currentView, nowMs: nowMs)
            st.base = snapshot(of: localDoc)
        } else {
            recordLocalChanges(st: &st, local: localDoc, nowMs: nowMs, remoteView: remoteView)
        }

        // Prune any of our own strokes that a remote device erased
        if let rv = remoteView {
            for key in Array(st.own.keys) {
                if let ss = st.own[key], ss.contains(where: { rv.deleted[$0.id] != nil }) {
                    st.own[key] = ss.filter { rv.deleted[$0.id] == nil }
                    st.markDirty(BookLogState.pageFile(label: st.label, key: key))
                }
            }
        }

        // 4. Derive merged document & upload ONLY our dirty log files CONCURRENTLY!
        let merged = deriveDoc(st: st, seen: seen, name: localDoc.name)

        let dirtyFiles = st.dirty
        if !dirtyFiles.isEmpty {
            var prepared: [(name: String, existingID: String?, payload: Data)] = []
            for name in dirtyFiles {
                let payload: Data
                if name.hasSuffix("_erase.json") {
                    payload = try JSONEncoder().encode(WireCodec.EraseLogPayload(v: 1, erased: st.erased))
                } else if name.hasSuffix("_blanks.json") {
                    payload = try JSONEncoder().encode(WireCodec.BlanksLogPayload(v: 1, blanks: Array(st.ownBlanks.values)))
                } else if name.hasSuffix("_marks.json") {
                    payload = try JSONEncoder().encode(WireCodec.MarksLogPayload(v: 1, bookmarks: st.ownBookmarks, removed: st.ownRemoved))
                } else if name.hasPrefix("txt_") && name.hasSuffix(".json") {
                    payload = try JSONEncoder().encode(WireCodec.TextBoxesLogPayload(v: 1, texts: st.ownTexts))
                } else {
                    let pageKey = BookLogState.keyOfFile(name)
                    payload = try WireCodec.encodePageShard(key: pageKey, strokes: st.own[pageKey] ?? [])
                }
                prepared.append((name, st.ids[name], payload))
            }

            let clientRef = self.client
            let primaryID = folderID
            let uploadedPairs: [(String, String)] = try await withThrowingTaskGroup(of: (String, String).self) { groupTask in
                for item in prepared {
                    groupTask.addTask {
                        let meta = try await clientRef.uploadMultipart(
                            fileID: item.existingID,
                            name: item.name,
                            parentID: primaryID,
                            payload: item.payload
                        )
                        return (item.name, meta.id)
                    }
                }
                var out: [(String, String)] = []
                for try await pair in groupTask { out.append(pair) }
                return out
            }

            for (name, newID) in uploadedPairs {
                st.ids[name] = newID
                st.dirty.removeAll { $0 == name }
            }
        }

        if isJoining && !hadFormat {
            _ = try? await client.uploadMultipart(
                fileID: nil,
                name: "format.json",
                parentID: folderID,
                payload: Data("{\"format\":2}".utf8)
            )
        }

        for dupID in duplicateIDs {
            try? await client.trash(fileID: dupID)
        }

        st.base = snapshot(of: merged)
        logStates[inkRelPath] = st
        logSeen[inkRelPath] = seen
        saveLogState(st, for: inkRelPath)

        let uploadedCount = dirtyFiles.count
        let ownCount = st.ids.count
        let remoteCount = remoteGroups.count
        let didTransfer = (downloadedCount > 0 || uploadedCount > 0)
        lastDiagnostic = "\(resolvedPath) · \(remoteCount) remote · \(ownCount) own"
            + (downloadedCount > 0 ? " (↓\(downloadedCount))" : "")
            + (uploadedCount > 0 ? " (↑\(uploadedCount))" : "")
            + (parseFailures > 0 ? " · ⚠️ \(parseFailures) decode err" : "")

        let changedLocally = !sameContent(merged, localDoc)
        if changedLocally {
            try? merged.save(for: pdfURL)
        }
        return (merged, changedLocally, didTransfer)
    }

    // MARK: - CRDT Helpers

    private func snapshot(of doc: InkDocument) -> BookSyncSnapshot {
        var strokesMap: [String: String] = [:]
        for (key, list) in doc.pages {
            for s in list { strokesMap[s.id] = key }
        }
        return BookSyncSnapshot(
            strokes: strokesMap,
            blanks: doc.blanks,
            bookmarks: doc.bookmarks,
            removed: doc.removed,
            texts: doc.texts
        )
    }

    private func strokeIDSet(in pages: [String: [InkStroke]]) -> Set<String> {
        var set = Set<String>()
        for list in pages.values {
            for s in list { set.insert(s.id) }
        }
        return set
    }

    private func joinLocal(st: inout BookLogState, local: InkDocument, view: InkDocument, nowMs: Int64) {
        let viewIDs = strokeIDSet(in: view.pages)
        var ownIDs = strokeIDSet(in: st.own)

        for (key, list) in local.pages {
            for s in list {
                if view.deleted[s.id] != nil || st.erased[s.id] != nil { continue }
                if viewIDs.contains(s.id) || ownIDs.contains(s.id) { continue }
                st.addOwnStroke(pageKey: key, stroke: s)
                ownIDs.insert(s.id)
            }
        }
        for (id, b) in local.blanks {
            if view.deleted[id] != nil || st.erased[id] != nil || view.blanks[id] != nil || st.ownBlanks[id] != nil {
                continue
            }
            st.ownBlanks[id] = b
            st.markDirty(BookLogState.blanksFile(label: st.label))
        }
        for (id, t) in local.deleted {
            if view.deleted[id] == nil {
                st.eraseOwn(id: id, nowMs: min(nowMs, t))
            }
        }
        for (k, m) in local.bookmarks {
            if let have = view.bookmarks[k], m.t <= have.t { continue }
            st.ownBookmarks[k] = m
            st.markDirty(BookLogState.marksFile(label: st.label))
        }
        for (k, m) in local.removed {
            if let have = view.removed[k], m.t <= have.t { continue }
            st.ownRemoved[k] = m
            st.markDirty(BookLogState.marksFile(label: st.label))
        }
        for (pageKey, list) in local.texts {
            let remoteById = Dictionary(uniqueKeysWithValues: (view.texts[pageKey] ?? []).map { ($0.id, $0) })
            for tb in list {
                if view.deleted[tb.id] != nil || st.erased[tb.id] != nil { continue }
                if let rtb = remoteById[tb.id], rtb.t >= tb.t { continue }
                var cur = st.ownTexts[pageKey] ?? []
                cur.removeAll { $0.id == tb.id }
                cur.append(tb)
                st.ownTexts[pageKey] = cur
                st.markDirty(BookLogState.textsFile(label: st.label))
            }
        }
    }

    private func recordLocalChanges(st: inout BookLogState, local: InkDocument, nowMs: Int64, remoteView: InkDocument?) {
        guard var base = st.base else { return }
        var localStrokes: [String: (key: String, stroke: InkStroke)] = [:]
        for (key, list) in local.pages {
            for s in list { localStrokes[s.id] = (key, s) }
        }
        let remoteIDs = remoteView.map { strokeIDSet(in: $0.pages) }

        for (id, item) in localStrokes {
            if base.strokes[id] == nil && st.erased[id] == nil {
                if item.key.hasPrefix("b:") {
                    let bid = String(item.key.dropFirst(2))
                    if st.erased[bid] != nil || remoteView?.deleted[bid] != nil { continue }
                }
                if let rv = remoteView, rv.deleted[id] != nil || (remoteIDs?.contains(id) == true) {
                    if rv.deleted[id] == nil { base.strokes[id] = item.key }
                    continue
                }
                st.addOwnStroke(pageKey: item.key, stroke: item.stroke)
                base.strokes[id] = item.key
            }
        }
        for id in Array(base.strokes.keys) {
            if localStrokes[id] == nil {
                st.eraseOwn(id: id, nowMs: nowMs)
                base.strokes.removeValue(forKey: id)
            }
        }
        for (id, b) in local.blanks {
            if base.blanks[id] == nil && st.erased[id] == nil {
                if let rv = remoteView, rv.deleted[id] != nil || rv.blanks[id] != nil {
                    if rv.deleted[id] == nil { base.blanks[id] = b }
                    continue
                }
                st.ownBlanks[id] = b
                base.blanks[id] = b
                st.markDirty(BookLogState.blanksFile(label: st.label))
            }
        }
        for id in Array(base.blanks.keys) {
            if local.blanks[id] == nil {
                st.eraseOwn(id: id, nowMs: nowMs)
                base.blanks.removeValue(forKey: id)
            }
        }
        for (k, m) in local.bookmarks {
            let was = base.bookmarks[k]
            if was == nil || was!.on != m.on || was!.t != m.t || (was!.title ?? "") != (m.title ?? "") {
                if let rm = remoteView?.bookmarks[k], rm.t >= m.t && rm.on == m.on {
                    base.bookmarks[k] = m
                    continue
                }
                st.ownBookmarks[k] = m
                base.bookmarks[k] = m
                st.markDirty(BookLogState.marksFile(label: st.label))
            }
        }
        for (k, m) in local.removed {
            let was = base.removed[k]
            if was == nil || was!.on != m.on || was!.t != m.t {
                if let rm = remoteView?.removed[k], rm.t >= m.t && rm.on == m.on {
                    base.removed[k] = m
                    continue
                }
                st.ownRemoved[k] = m
                base.removed[k] = m
                st.markDirty(BookLogState.marksFile(label: st.label))
            }
        }
        // Diff text boxes (supports additions, inline edits/moves via higher `t`, and deletions via tombstone)
        var localTextById: [String: (pageKey: String, box: InkTextBox)] = [:]
        for (pk, list) in local.texts {
            for tb in list { localTextById[tb.id] = (pk, tb) }
        }
        var baseTextById: [String: (pageKey: String, box: InkTextBox)] = [:]
        for (pk, list) in base.texts {
            for tb in list { baseTextById[tb.id] = (pk, tb) }
        }
        var remoteTextById: [String: InkTextBox] = [:]
        if let rv = remoteView {
            for list in rv.texts.values {
                for tb in list { remoteTextById[tb.id] = tb }
            }
        }
        for (id, item) in localTextById {
            let was = baseTextById[id]?.box
            if was == nil || was != item.box {
                if let rtb = remoteTextById[id], rtb.t >= item.box.t && rtb == item.box {
                    continue
                }
                if remoteView?.deleted[id] != nil { continue }
                var cur = st.ownTexts[item.pageKey] ?? []
                cur.removeAll { $0.id == id }
                cur.append(item.box)
                st.ownTexts[item.pageKey] = cur
                st.markDirty(BookLogState.textsFile(label: st.label))
            }
        }
        for (id, _) in baseTextById where localTextById[id] == nil {
            st.eraseOwn(id: id, nowMs: nowMs)
            for pk in Array(st.ownTexts.keys) {
                if var list = st.ownTexts[pk], list.contains(where: { $0.id == id }) {
                    list.removeAll { $0.id == id }
                    st.ownTexts[pk] = list
                    st.markDirty(BookLogState.textsFile(label: st.label))
                }
            }
        }
        base.texts = local.texts
        st.base = base
    }

    private func deriveDoc(st: BookLogState, seen: [String: RemoteLogEntry], name: String) -> InkDocument {
        var erased = st.erased
        var blanks: [String: BlankPage] = [:]
        var pages: [String: [InkStroke]] = [:]
        var bookmarks: [String: PageMark] = [:]
        var removed: [String: PageMark] = [:]
        var seenStrokeIDs = Set<String>()

        func mergeMark(_ into: inout [String: PageMark], _ k: String, _ m: PageMark) {
            if let cur = into[k], cur.t >= m.t { return }
            into[k] = m
        }
        func addBlank(_ b: BlankPage) {
            if blanks[b.id] == nil { blanks[b.id] = b }
        }
        func addStroke(_ key: String, _ s: InkStroke) {
            guard !seenStrokeIDs.contains(s.id) else { return }
            seenStrokeIDs.insert(s.id)
            pages[key, default: []].append(s)
        }

        for b in st.ownBlanks.values { addBlank(b) }
        for (k, m) in st.ownBookmarks { mergeMark(&bookmarks, k, m) }
        for (k, m) in st.ownRemoved { mergeMark(&removed, k, m) }
        for (key, ss) in st.own {
            for s in ss { addStroke(key, s) }
        }

        for entry in seen.values {
            if let er = entry.erased {
                for (id, t) in er where erased[id] == nil { erased[id] = t }
            }
            if let bs = entry.blanks {
                for b in bs { addBlank(b) }
            }
            if let bms = entry.bookmarks {
                for (k, m) in bms { mergeMark(&bookmarks, k, m) }
            }
            if let rms = entry.removed {
                for (k, m) in rms { mergeMark(&removed, k, m) }
            }
            if let key = entry.key, let ss = entry.strokes {
                for s in ss { addStroke(key, s) }
            }
        }

        for id in erased.keys { blanks.removeValue(forKey: id) }
        for key in Array(pages.keys) {
            if key.hasPrefix("b:") && blanks[String(key.dropFirst(2))] == nil {
                pages.removeValue(forKey: key)
                continue
            }
            let filtered = (pages[key] ?? [])
                .filter { erased[$0.id] == nil }
                .sorted { $0.t != $1.t ? $0.t < $1.t : $0.id < $1.id }
            if filtered.isEmpty { pages.removeValue(forKey: key) }
            else { pages[key] = filtered }
        }

        // Merge text boxes LWW by timestamp `t` across ownTexts + remote entries, filtering tombstones
        var textsById: [String: (pageKey: String, box: InkTextBox)] = [:]
        func mergeText(_ pageKey: String, _ tb: InkTextBox) {
            guard erased[tb.id] == nil else { return }
            if let cur = textsById[tb.id], cur.box.t >= tb.t { return }
            textsById[tb.id] = (pageKey, tb)
        }
        for (pk, list) in st.ownTexts {
            for tb in list { mergeText(pk, tb) }
        }
        for entry in seen.values {
            if let tMap = entry.texts {
                for (pk, list) in tMap {
                    for tb in list { mergeText(pk, tb) }
                }
            }
        }
        var mergedTexts: [String: [InkTextBox]] = [:]
        for (_, item) in textsById {
            if item.pageKey.hasPrefix("b:") && blanks[String(item.pageKey.dropFirst(2))] == nil { continue }
            mergedTexts[item.pageKey, default: []].append(item.box)
        }
        for pk in mergedTexts.keys {
            mergedTexts[pk]?.sort { $0.t != $1.t ? $0.t < $1.t : $0.id < $1.id }
        }

        var doc = InkDocument.empty(name: name)
        doc.pages = pages
        doc.blanks = blanks
        doc.bookmarks = bookmarks
        doc.removed = removed
        doc.deleted = erased
        doc.texts = mergedTexts
        doc.layoutBlanks()
        return doc
    }

    nonisolated static func parseRemoteEntryStatic(name: String, bytes: Data) -> RemoteLogEntry? {
        if name.hasSuffix("_erase.json") {
            let raw = WireCodec.isGzip(bytes) ? ((try? WireCodec.gzipDecompress(bytes)) ?? bytes) : bytes
            guard let p = try? JSONDecoder().decode(WireCodec.EraseLogPayload.self, from: raw) else { return nil }
            return RemoteLogEntry(erased: p.erased)
        }
        if name.hasSuffix("_blanks.json") {
            let raw = WireCodec.isGzip(bytes) ? ((try? WireCodec.gzipDecompress(bytes)) ?? bytes) : bytes
            guard let p = try? JSONDecoder().decode(WireCodec.BlanksLogPayload.self, from: raw) else { return nil }
            return RemoteLogEntry(blanks: p.blanks)
        }
        if name.hasSuffix("_marks.json") {
            let raw = WireCodec.isGzip(bytes) ? ((try? WireCodec.gzipDecompress(bytes)) ?? bytes) : bytes
            guard let p = try? JSONDecoder().decode(WireCodec.MarksLogPayload.self, from: raw) else { return nil }
            return RemoteLogEntry(bookmarks: p.bookmarks, removed: p.removed)
        }
        if name.hasPrefix("txt_") && name.hasSuffix(".json") {
            let raw = WireCodec.isGzip(bytes) ? ((try? WireCodec.gzipDecompress(bytes)) ?? bytes) : bytes
            guard let p = try? JSONDecoder().decode(WireCodec.TextBoxesLogPayload.self, from: raw) else { return nil }
            return RemoteLogEntry(texts: p.texts)
        }
        guard let shard = WireCodec.decodePageShard(bytes) else { return nil }
        return RemoteLogEntry(key: shard.key, strokes: shard.strokes)
    }

    nonisolated static func combineRemoteEntriesStatic(_ a: RemoteLogEntry?, _ b: RemoteLogEntry) -> RemoteLogEntry {
        guard var out = a else { return b }
        if let k = b.key { out.key = k }
        if let bs = b.strokes {
            let have = Set((out.strokes ?? []).map { $0.id })
            out.strokes = (out.strokes ?? []) + bs.filter { !have.contains($0.id) }
        }
        if let bb = b.blanks {
            let have = Set((out.blanks ?? []).map { $0.id })
            out.blanks = (out.blanks ?? []) + bb.filter { !have.contains($0.id) }
        }
        if let ber = b.erased {
            var er = out.erased ?? [:]
            for (k, v) in ber { er[k] = v }
            out.erased = er
        }
        if let bbm = b.bookmarks {
            var bm = out.bookmarks ?? [:]
            for (k, m) in bbm where bm[k] == nil || m.t > bm[k]!.t { bm[k] = m }
            out.bookmarks = bm
        }
        if let brm = b.removed {
            var rm = out.removed ?? [:]
            for (k, m) in brm where rm[k] == nil || m.t > rm[k]!.t { rm[k] = m }
            out.removed = rm
        }
        if let bt = b.texts {
            var merged = out.texts ?? [:]
            for (pk, list) in bt {
                var cur = merged[pk] ?? []
                for tb in list {
                    if let idx = cur.firstIndex(where: { $0.id == tb.id }) {
                        if tb.t > cur[idx].t { cur[idx] = tb }
                    } else {
                        cur.append(tb)
                    }
                }
                merged[pk] = cur
            }
            out.texts = merged
        }
        return out
    }

    private func sameContent(_ a: InkDocument, _ b: InkDocument) -> Bool {
        if a.blanks != b.blanks || a.bookmarks != b.bookmarks || a.removed != b.removed || a.texts != b.texts { return false }
        if Set(a.pages.keys) != Set(b.pages.keys) { return false }
        for (k, listA) in a.pages {
            let listB = b.pages[k] ?? []
            if listA.count != listB.count { return false }
            let idsA = Set(listA.map { $0.id })
            let idsB = Set(listB.map { $0.id })
            if idsA != idsB { return false }
        }
        return true
    }

    // MARK: - Local Log State Persistence

    private func logStateURL(for inkRelPath: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("PencilInkNative/sync-logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let hash = WireCodec.md5Hex(Data(inkRelPath.utf8))
        return dir.appendingPathComponent("\(hash).json")
    }

    private func loadLogState(for inkRelPath: String) -> BookLogState {
        if let cached = logStates[inkRelPath] { return cached }
        let url = logStateURL(for: inkRelPath)
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(BookLogState.self, from: data) {
            logStates[inkRelPath] = decoded
            return decoded
        }
        let fresh = BookLogState(label: config.deviceLabel)
        logStates[inkRelPath] = fresh
        return fresh
    }

    private func saveLogState(_ st: BookLogState, for inkRelPath: String) {
        let url = logStateURL(for: inkRelPath)
        if let data = try? JSONEncoder().encode(st) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
