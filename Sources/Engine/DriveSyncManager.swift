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
}

struct RemoteLogEntry: Codable, Sendable {
    var key: String?
    var strokes: [InkStroke]?
    var blanks: [BlankPage]?
    var erased: [String: Int64]?
    var bookmarks: [String: PageMark]?
    var removed: [String: PageMark]?
}

struct BookLogState: Codable {
    var label: String
    var folderId: String = ""
    var own: [String: [InkStroke]] = [:]
    var ownBlanks: [String: BlankPage] = [:]
    var ownBookmarks: [String: PageMark] = [:]
    var ownRemoved: [String: PageMark] = [:]
    var erased: [String: Int64] = [:]
    var dirty: [String] = []
    var ids: [String: String] = [:]
    var seenMd5: [String: String] = [:]
    var base: BookSyncSnapshot? = nil

    static func pageFile(label: String, key: String) -> String {
        "log_\(label)_p\(key.replacingOccurrences(of: ":", with: "~")).json"
    }
    static func blanksFile(label: String) -> String { "log_\(label)_blanks.json" }
    static func marksFile(label: String) -> String { "log_\(label)_marks.json" }
    static func eraseFile(label: String) -> String { "log_\(label)_erase.json" }
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
    private var folderCheckAt: [String: Date] = [:]
    private var extraFolderCache: [String: [String]] = [:]
    private var activeSyncTasks: [String: Task<(InkDocument, Bool), Error>] = [:]
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
            Task { @MainActor in
                if let encoded = try? JSONEncoder().encode(updated) {
                    UserDefaults.standard.set(encoded, forKey: "pencilink.native.drive.config.v1")
                }
            }
        }
        self.visualState = loaded.isConnected ? .ok : .disconnected
        self.statusText = loaded.isConnected ? "Synced" : "Not Connected"
    }

    private static func generateDeviceLabel() -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return "ios" + String((0..<6).map { _ in chars.randomElement()! })
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

    func scheduleBookSync(
        pdfURL: URL,
        relativePath: String,
        localDocProvider: @escaping () -> InkDocument,
        onMerged: @escaping (InkDocument) -> Void
    ) {
        guard config.isConnected, config.autoSync else { return }
        let key = relativePath
        debounceTimers[key]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.debounceTimers.removeValue(forKey: key)
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
        debounceTimers[key] = item
        // Fast 0.55s debounce so strokes leave the iPad in <1 second!
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: item)
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
            return try? await running.value
        }

        visualState = .syncing
        activeBookName = pdfURL.deletingPathExtension().lastPathComponent
        statusText = "Syncing \(activeBookName)…"

        let currentCfg = config
        let task = Task<(InkDocument, Bool), Error> { [weak self] in
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
            sessionBooksSynced += 1
            lastSyncedAt = Date()
            lastError = ""
            if activeSyncTasks.isEmpty {
                activeBookName = ""
                visualState = .ok
                statusText = "Synced"
            }
            return result
        } catch {
            activeSyncTasks.removeValue(forKey: inkRelPath)
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
    ) async throws -> (InkDocument, Bool) {
        let dir = (inkRelPath as NSString).deletingLastPathComponent
        let fileName = (inkRelPath as NSString).lastPathComponent
        let folderName = fileName.hasSuffix(".json")
            ? String(fileName.dropLast(5)) + ".d"
            : fileName + ".d"

        var st = loadLogState(for: inkRelPath)
        var seen = logSeen[inkRelPath] ?? [:]

        // 1. Resolve ALL matching `<Book.pdf.ink.d>` folders on Drive (prevents split-folder one-way sync!)
        let needFolderScan = forceFolderScan
            || st.folderId.isEmpty
            || (folderCheckAt[inkRelPath].map { Date().timeIntervalSince($0) > 25 } ?? true)

        var folderID = st.folderId
        var extraFolderIDs = extraFolderCache[inkRelPath] ?? []

        if needFolderScan {
            let parentID = try await client.ensureRemoteDir(relativeDir: dir)
            let folders = try await client.findChildren(
                parentID: parentID,
                name: folderName,
                mimeType: GoogleDriveClient.folderMime
            ).sorted { $0.id < $1.id }

            if let first = folders.first {
                // Always adopt the smallest-ID folder as canonical primary (matching Obsidian!)
                if !folderID.isEmpty && folderID != first.id {
                    // Reset our own uploaded file IDs if primary folder changed so dirty files upload to canonical folder
                    st.ids.removeAll()
                    for key in st.own.keys { st.markDirty(BookLogState.pageFile(label: st.label, key: key)) }
                    if !st.erased.isEmpty { st.markDirty(BookLogState.eraseFile(label: st.label)) }
                    if !st.ownBlanks.isEmpty { st.markDirty(BookLogState.blanksFile(label: st.label)) }
                    if !st.ownBookmarks.isEmpty || !st.ownRemoved.isEmpty { st.markDirty(BookLogState.marksFile(label: st.label)) }
                }
                folderID = first.id
                extraFolderIDs = folders.dropFirst().map { $0.id }
            } else {
                let made = try await client.createFolder(name: folderName, parentID: parentID)
                folderID = made.id
                extraFolderIDs = []
            }
            st.folderId = folderID
            extraFolderCache[inkRelPath] = extraFolderIDs
            folderCheckAt[inkRelPath] = Date()
        }

        let allFolderIDs = [folderID] + extraFolderIDs
        let listing = try await client.listChildren(parentIDs: allFolderIDs)
        let hadFormat = listing.contains { $0.name == "format.json" }

        // Map our own existing log files inside canonical primary folder & flag duplicates
        var duplicateIDs: [String] = []
        for f in listing where f.name.hasPrefix("log_\(st.label)_") {
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
            if !f.name.hasPrefix("log_") || f.name.hasPrefix("log_\(st.label)_") { continue }
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

        let remoteCount = remoteGroups.count
        let folderCount = allFolderIDs.count
        let diagPath = dir.isEmpty ? folderName : "\(dir)/\(folderName)"
        lastDiagnostic = "\(diagPath) · \(folderCount) folder\(folderCount == 1 ? "" : "s") · \(remoteCount) remote shard\(remoteCount == 1 ? "" : "s")"
            + (downloadedCount > 0 ? " (↓\(downloadedCount))" : "")
            + (parseFailures > 0 ? " · ⚠️ \(parseFailures) decode err" : "")

        let changedLocally = !sameContent(merged, localDoc)
        if changedLocally {
            try? merged.save(for: pdfURL)
        }
        return (merged, changedLocally)
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
            removed: doc.removed
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

        var doc = InkDocument.empty(name: name)
        doc.pages = pages
        doc.blanks = blanks
        doc.bookmarks = bookmarks
        doc.removed = removed
        doc.deleted = erased
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
        return out
    }

    private func sameContent(_ a: InkDocument, _ b: InkDocument) -> Bool {
        if a.blanks != b.blanks || a.bookmarks != b.bookmarks || a.removed != b.removed { return false }
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
