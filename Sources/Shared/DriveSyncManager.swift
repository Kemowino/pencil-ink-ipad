import Foundation
import Combine

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
    var lastUploadedMd5: [String: String] = [:]
    var base: BookSyncSnapshot? = nil

    enum CodingKeys: String, CodingKey {
        case label, folderId, own, ownBlanks, ownBookmarks, ownRemoved, ownTexts, erased, dirty, ids, seenMd5, lastUploadedMd5, base
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
        lastUploadedMd5 = (try? c.decode([String: String].self, forKey: .lastUploadedMd5)) ?? [:]
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
struct TrashManifestEntry: Codable, Sendable, Equatable {
    var relativePath: String
    var kind: String // "file" | "folder"
    var deletedAtMs: Int64
    var device: String
}

struct TrashManifest: Codable, Sendable {
    var v: Int = 1
    var entries: [String: TrashManifestEntry] = [:]
}

enum LightChangeCheckResult {
    case noChanges
    case bookChanged
    case vaultStructureChanged
    case failed
}

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
    @Published var syncProgressText: String = ""
    /// Byte-accurate transfer fraction `0.0...1.0`, or `-1.0` for indeterminate scanning.
    @Published var syncProgressFraction: Double = 0.0
    /// Compact inline label displayed directly in iPadOS & macOS chrome (no extra window needed!).
    @Published var syncPhaseLabel: String = ""
    /// Live smoothed transfer rate (e.g. "6.2 MB/s") when chunked transfer is active.
    @Published var syncSpeedText: String = ""
    /// True whenever any Drive upload, download, or vault sync is actively running.
    @Published var isTransferActive: Bool = false
    /// Number of items currently resting in `.PencilInk-Trash` (120-day auto-purge).
    @Published var trashedItemsCount: Int = 0
    @Published var isSyncingVault: Bool = false

    /// Optional callback invoked when a remote deletion from `.PencilInk-Trash` removes a local file/folder.
    var onRemoteDeletedPath: ((_ relativePath: String, _ isFolder: Bool) -> Void)?

    private let changesTokenKey = "pencilink.native.drive.changesToken.v1"
    private let lastTrashPurgeKey = "pencilink.native.drive.lastTrashPurge.v1"
    private var knownRemotePDFPathsLower: Set<String> = []
    private var cachedTrashManifestFileID: String? = nil
    private var cachedTrashManifestMD5: String = ""
    private var cachedTrashManifest: TrashManifest = TrashManifest()
    private var activeSingleUploadTask: Task<Void, Never>? = nil
    private var pendingSingleUploads: [(pdfURL: URL, relativePath: String)] = []
    private var firstDirtyAt: [String: Date] = [:]
    private var isLightChangeCheckRunning: Bool = false
    private var lastProgressPublishAt: TimeInterval = 0
    private var speedWindowStartAt: TimeInterval = 0
    private var speedWindowStartBytes: Int64 = 0

    private static let sharedISOFull: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let sharedISOBasic = ISO8601DateFormatter()

    /// Platform hook controlling whether smart auto-sync is enabled (defaults to iOS AppSettings on iOS, true on macOS).
    var isSmartSyncEnabled: () -> Bool = {
        #if os(iOS)
        return AppSettings.shared.syncMode == .smart
        #else
        return true
        #endif
    }

    private let configKey = "pencilink.native.drive.config.v1"
    private var lastVaultSyncAt: Date? = nil
    private var activeVaultSyncTask: Task<(downloadedPDFs: Int, uploadedPDFs: Int, syncedBooks: Int), Never>? = nil
    private let client: GoogleDriveClient
    private var logStates: [String: BookLogState] = [:]
    private var logSeen: [String: [String: RemoteLogEntry]] = [:]
    private var logCacheLRU: [String] = []
    private let maxInMemoryBookLogs = 12
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
        #if os(macOS) || targetEnvironment(macCatalyst)
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
        cancelActiveTransfer()
        config.accessToken = ""
        config.refreshToken = ""
        config.expiresAt = 0
        lastError = ""
        lastDiagnostic = ""
        clearChangesToken()
        knownRemotePDFPathsLower.removeAll()
        cachedTrashManifestFileID = nil
        cachedTrashManifestMD5 = ""
        cachedTrashManifest = TrashManifest()
        trashedItemsCount = 0
        firstDirtyAt.removeAll()
        saveConfig()
        visualState = .disconnected
        statusText = "Not Connected"
    }

    func cancelActiveTransfer() {
        pendingSingleUploads.removeAll()
        activeVaultSyncTask?.cancel()
        activeSingleUploadTask?.cancel()
        activeSingleUploadTask = nil
    }

    private func changesTokenStorageKey() -> String {
        let folder = config.driveFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(changesTokenKey).\(WireCodec.md5Hex(Data(folder.utf8)))"
    }

    private func savedChangesToken() -> String? {
        let s = UserDefaults.standard.string(forKey: changesTokenStorageKey())
        return (s?.isEmpty == false) ? s : nil
    }

    private func saveChangesToken(_ token: String) {
        guard !token.isEmpty else { return }
        UserDefaults.standard.set(token, forKey: changesTokenStorageKey())
    }

    private func clearChangesToken() {
        UserDefaults.standard.removeObject(forKey: changesTokenStorageKey())
    }

    /// Ultra-lightweight (~300 bytes on reused HTTP/2 socket) Drive Changes check for sub-10s cross-device sync!
    /// Does ZERO Drive folder listing, ZERO file downloads, and ZERO UI updates when nothing changed.
    func checkDriveChangesLightly(forBookRelativePath relativePath: String?) async -> LightChangeCheckResult {
        guard config.isConnected, !isLightChangeCheckRunning, !isSyncingVault, activeSyncTasks.isEmpty else {
            return .noChanges
        }
        isLightChangeCheckRunning = true
        defer { isLightChangeCheckRunning = false }

        await client.updateConfig(config)
        do {
            guard let token = savedChangesToken() else {
                let startTok = try await client.getStartPageToken()
                saveChangesToken(startTok)
                return .noChanges
            }

            let delta = try await client.listChangesSince(pageToken: token, ownDeviceLabel: config.deviceLabel)
            saveChangesToken(delta.newStartPageToken)

            guard delta.hasRelevantChanges else {
                return .noChanges
            }

            if let rel = relativePath {
                let inkRel = rel.hasSuffix(".ink.json") ? rel : (rel + ".ink.json")
                var bookFolderIDs = Set<String>()
                if let fid = logStates[inkRel]?.folderId, !fid.isEmpty {
                    bookFolderIDs.insert(fid)
                }
                if let extras = extraFolderCache[inkRel] {
                    for e in extras { bookFolderIDs.insert(e) }
                }
                if bookFolderIDs.isEmpty || !delta.changedParentIDs.isDisjoint(with: bookFolderIDs) || !delta.changedFileIDs.isDisjoint(with: bookFolderIDs) {
                    return .bookChanged
                }
            }

            return delta.hasVaultStructureChanges ? .vaultStructureChanged : .noChanges
        } catch {
            return .failed
        }
    }

    private func beginTransferProgress(phase: String, fraction: Double = -1.0) {
        isTransferActive = true
        syncPhaseLabel = phase
        syncProgressText = phase
        syncProgressFraction = fraction
        syncSpeedText = ""
        speedWindowStartAt = Date().timeIntervalSinceReferenceDate
        speedWindowStartBytes = 0
        lastProgressPublishAt = 0
    }

    private func updateTransferProgress(
        phase: String,
        completedBytes: Int64,
        totalBytes: Int64,
        forcePublish: Bool = false
    ) {
        let now = Date().timeIntervalSinceReferenceDate
        if !forcePublish && (now - lastProgressPublishAt) < 0.22 {
            return
        }
        lastProgressPublishAt = now

        let frac: Double = totalBytes > 0
            ? max(0.0, min(1.0, Double(completedBytes) / Double(totalBytes)))
            : -1.0
        syncProgressFraction = frac
        syncPhaseLabel = phase
        syncProgressText = phase

        let dt = now - speedWindowStartAt
        if dt >= 0.4 && completedBytes > speedWindowStartBytes {
            let bps = Double(completedBytes - speedWindowStartBytes) / dt
            if bps >= 1_048_576 {
                syncSpeedText = String(format: "%.1f MB/s", bps / 1_048_576.0)
            } else if bps >= 1024 {
                syncSpeedText = String(format: "%.0f KB/s", bps / 1024.0)
            }
            if dt >= 3.0 {
                speedWindowStartAt = now
                speedWindowStartBytes = completedBytes
            }
        }
    }

    private func endTransferProgress() {
        isTransferActive = false
        syncProgressFraction = 0.0
        syncPhaseLabel = ""
        syncProgressText = ""
        syncSpeedText = ""
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
        clearChangesToken()
        knownRemotePDFPathsLower.removeAll()
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
        delaySeconds: TimeInterval = 1.6,
        localDocProvider: @escaping () -> InkDocument,
        onMerged: @escaping (InkDocument) -> Void
    ) {
        guard config.isConnected, config.autoSync, isSmartSyncEnabled() else { return }
        let inkRelPath = relativePath.hasSuffix(".ink.json") ? relativePath : (relativePath + ".ink.json")
        debounceTimers[inkRelPath]?.cancel()

        let now = Date()
        let firstDirty = firstDirtyAt[inkRelPath] ?? now
        if firstDirtyAt[inkRelPath] == nil { firstDirtyAt[inkRelPath] = now }
        let elapsedSinceFirst = now.timeIntervalSince(firstDirty)
        let effectiveDelay: TimeInterval = (elapsedSinceFirst >= 8.0) ? 0.35 : max(0.2, delaySeconds)

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.debounceTimers.removeValue(forKey: inkRelPath)
            self.firstDirtyAt.removeValue(forKey: inkRelPath)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + effectiveDelay, execute: item)
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
        logIOQueue.async { try? FileManager.default.removeItem(at: oldStateURL) }

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
                knownRemotePDFPathsLower.remove(oldRelativePath.lowercased())
                knownRemotePDFPathsLower.insert(newRelativePath.lowercased())
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
        _ = await syncVault(vault: vault, force: true)
    }

    /// Uploads newly created or imported local PDFs sequentially in **8 MB resumable chunks**.
    func uploadNewBookToDrive(pdfURL: URL, relativePath: String) {
        guard config.isConnected, config.autoSync, config.syncPDFs else { return }
        let cleanRel = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !pendingSingleUploads.contains(where: { $0.relativePath.lowercased() == cleanRel.lowercased() }) {
            pendingSingleUploads.append((pdfURL, cleanRel))
        }
        guard activeSingleUploadTask == nil else { return }

        activeSingleUploadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.activeSingleUploadTask = nil }
            while !self.pendingSingleUploads.isEmpty {
                if Task.isCancelled { break }
                let next = self.pendingSingleUploads.removeFirst()
                let currentCfg = self.config
                await self.client.updateConfig(currentCfg)
                let rawDir = (next.relativePath as NSString).deletingLastPathComponent
                let dir = (rawDir == "." || rawDir == "/") ? "" : rawDir
                let fileName = (next.relativePath as NSString).lastPathComponent
                do {
                    self.visualState = .syncing
                    self.statusText = "Uploading…"
                    self.beginTransferProgress(phase: "↑ Uploading \(fileName)…", fraction: 0.0)
                    let parentID = try await self.client.ensureRemoteDir(relativeDir: dir)
                    let existing = try await self.client.findChildren(parentID: parentID, name: fileName)
                    if existing.isEmpty {
                        _ = try await self.client.uploadPDFFileChunked(
                            fileURL: next.pdfURL,
                            name: fileName,
                            parentID: parentID,
                            resumeKey: next.relativePath
                        ) { [weak self] upBytes, totBytes in
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                let label = "↑ \(fileName) · \(self.formatBytes(upBytes)) / \(self.formatBytes(totBytes))"
                                self.updateTransferProgress(phase: label, completedBytes: upBytes, totalBytes: totBytes)
                            }
                        }
                    }
                    self.knownRemotePDFPathsLower.insert(next.relativePath.lowercased())
                    let sidecar = InkDocument.sidecarURL(for: next.pdfURL)
                    if FileManager.default.fileExists(atPath: sidecar.path) {
                        let local = await Task.detached(priority: .utility) { InkDocument.load(for: next.pdfURL) }.value
                        _ = await self.syncBook(pdfURL: next.pdfURL, relativePath: next.relativePath, localDoc: local, forceFolderScan: true)
                    }
                    let totals = await self.client.getTransferTotals()
                    self.sessionBytesUp = totals.up
                    self.sessionBytesDown = totals.down
                    self.lastSyncedAt = Date()
                    self.lastError = ""
                    self.endTransferProgress()
                    self.visualState = .ok
                    self.statusText = "Synced"
                } catch DriveClientError.cancelled {
                    self.pendingSingleUploads.removeAll()
                    self.endTransferProgress()
                    self.visualState = .ok
                    self.statusText = "Paused (Resumable)"
                    break
                } catch is CancellationError {
                    self.pendingSingleUploads.removeAll()
                    self.endTransferProgress()
                    self.visualState = .ok
                    self.statusText = "Paused (Resumable)"
                    break
                } catch {
                    self.endTransferProgress()
                    self.lastError = error.localizedDescription
                    self.visualState = .error
                    self.statusText = "Sync Error"
                }
            }
        }
    }

    // MARK: - `.PencilInk-Trash` 120-Day Deletion Sync (Files, Journals, & Folders)

    private func loadTrashManifest(trashFolderID: String) async throws -> TrashManifest {
        let matches = try await client.findChildren(parentID: trashFolderID, name: ".trash-manifest.json")
        guard let meta = matches.first else {
            cachedTrashManifestFileID = nil
            cachedTrashManifestMD5 = ""
            cachedTrashManifest = TrashManifest()
            return cachedTrashManifest
        }
        cachedTrashManifestFileID = meta.id
        let rev = "\(meta.md5Checksum ?? "")|\(meta.modifiedTime ?? "")"
        if !rev.isEmpty && rev == cachedTrashManifestMD5 {
            return cachedTrashManifest
        }
        let raw = try await client.download(fileID: meta.id)
        let decoded = (try? JSONDecoder().decode(TrashManifest.self, from: raw)) ?? TrashManifest()
        cachedTrashManifest = decoded
        cachedTrashManifestMD5 = rev
        return decoded
    }

    private func saveTrashManifest(_ manifest: TrashManifest, trashFolderID: String) async throws {
        let cutoffMs = Int64(Date().timeIntervalSince1970 * 1000) - Int64(GoogleDriveClient.trashRetentionDays) * 86_400_000
        var pruned = manifest
        pruned.entries = pruned.entries.filter { $0.value.deletedAtMs > cutoffMs }

        let payload = try JSONEncoder().encode(pruned)
        let uploaded = try await client.uploadMultipart(
            fileID: cachedTrashManifestFileID,
            name: ".trash-manifest.json",
            parentID: trashFolderID,
            payload: payload
        )
        cachedTrashManifestFileID = uploaded.id
        cachedTrashManifestMD5 = "\(uploaded.md5Checksum ?? "")|\(uploaded.modifiedTime ?? "")"
        cachedTrashManifest = pruned
    }

    private func cleanupLocalLogState(forPDFRelativePath relPath: String) {
        let inkRel = relPath.hasSuffix(".ink.json") ? relPath : (relPath + ".ink.json")
        debounceTimers[inkRel]?.cancel()
        debounceTimers.removeValue(forKey: inkRel)
        firstDirtyAt.removeValue(forKey: inkRel)
        pendingFollowups.removeValue(forKey: inkRel)
        logStates.removeValue(forKey: inkRel)
        logSeen.removeValue(forKey: inkRel)
        logCacheLRU.removeAll { $0 == inkRel }
        folderCheckAt.removeValue(forKey: inkRel)
        extraFolderCache.removeValue(forKey: inkRel)
        resolvedPathCache.removeValue(forKey: inkRel)
        let stateURL = logStateURL(for: inkRel)
        logIOQueue.async { try? FileManager.default.removeItem(at: stateURL) }
    }

    private func migrateLocalLogState(from oldRelPath: String, to newRelPath: String) {
        let oldInk = oldRelPath.hasSuffix(".ink.json") ? oldRelPath : (oldRelPath + ".ink.json")
        let newInk = newRelPath.hasSuffix(".ink.json") ? newRelPath : (newRelPath + ".ink.json")
        guard oldInk != newInk else { return }
        let oldURL = logStateURL(for: oldInk)
        var state = logStates.removeValue(forKey: oldInk)
        if state == nil, let data = try? Data(contentsOf: oldURL),
           let dec = try? JSONDecoder().decode(BookLogState.self, from: data) {
            state = dec
        }
        if let st = state {
            logStates[newInk] = st
            saveLogState(st, for: newInk)
        }
        logIOQueue.async { try? FileManager.default.removeItem(at: oldURL) }
        if let seen = logSeen.removeValue(forKey: oldInk) { logSeen[newInk] = seen }
        folderCheckAt.removeValue(forKey: oldInk)
        extraFolderCache.removeValue(forKey: oldInk)
        resolvedPathCache.removeValue(forKey: oldInk)
    }

    @discardableResult
    func deleteFileOnDrive(relativePath: String) async -> Bool {
        let cleanRel = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        cleanupLocalLogState(forPDFRelativePath: cleanRel)
        knownRemotePDFPathsLower.remove(cleanRel.lowercased())

        guard config.isConnected else { return false }
        await client.updateConfig(config)
        visualState = .syncing
        statusText = "Moving to Drive Trash…"
        beginTransferProgress(phase: "Moving \((cleanRel as NSString).lastPathComponent) to Trash…", fraction: -1.0)

        let rawDir = (cleanRel as NSString).deletingLastPathComponent
        let dir = (rawDir == "." || rawDir == "/") ? "" : rawDir
        let pdfName = (cleanRel as NSString).lastPathComponent
        let inkFolderName = pdfName + ".ink.d"
        let legacyInkName = pdfName + ".ink.json"
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        do {
            let rootID = try await client.resolveRootFolderID()
            let trashID = try await client.ensureTrashFolderID()
            var movedAny = false

            if let parentID = try await client.lookupRemoteDir(relativeDir: dir) {
                let pdfs = try await client.findChildren(parentID: parentID, name: pdfName)
                for f in pdfs {
                    _ = try await client.moveItemToTrashFolder(
                        fileID: f.id,
                        currentParents: f.parents,
                        trashFolderID: trashID,
                        originalPath: cleanRel,
                        kind: "file",
                        deletedAtMs: nowMs
                    )
                    movedAny = true
                }
                let legacyInks = try await client.findChildren(parentID: parentID, name: legacyInkName)
                for f in legacyInks {
                    _ = try await client.moveItemToTrashFolder(
                        fileID: f.id,
                        currentParents: f.parents,
                        trashFolderID: trashID,
                        originalPath: cleanRel + ".ink.json",
                        kind: "file",
                        deletedAtMs: nowMs
                    )
                    movedAny = true
                }
            }

            let inkFolders = try await client.findFoldersNamed(inkFolderName)
            for f in inkFolders {
                if let resolved = try await client.resolvePathUnderRoot(folder: f, rootID: rootID) {
                    let expectedSuffix = cleanRel + ".ink.d"
                    if resolved.lowercased() == expectedSuffix.lowercased() || resolved.lowercased().hasSuffix("/" + expectedSuffix.lowercased()) || dir.isEmpty {
                        _ = try await client.moveItemToTrashFolder(
                            fileID: f.id,
                            currentParents: f.parents,
                            trashFolderID: trashID,
                            originalPath: resolved,
                            kind: "inkFolder",
                            deletedAtMs: nowMs
                        )
                        movedAny = true
                    }
                }
            }

            var manifest = try await loadTrashManifest(trashFolderID: trashID)
            manifest.entries[cleanRel.lowercased()] = TrashManifestEntry(
                relativePath: cleanRel,
                kind: "file",
                deletedAtMs: nowMs,
                device: config.deviceLabel
            )
            try await saveTrashManifest(manifest, trashFolderID: trashID)
            trashedItemsCount = max(trashedItemsCount + (movedAny ? 1 : 0), manifest.entries.count)

            lastError = ""
            lastSyncedAt = Date()
            endTransferProgress()
            visualState = .ok
            statusText = "Synced"
            return true
        } catch {
            endTransferProgress()
            lastError = error.localizedDescription
            visualState = .error
            statusText = "Sync Error"
            return false
        }
    }

    @discardableResult
    func deleteFolderOnDrive(relativeFolderPath: String, containedPDFRelativePaths: [String]) async -> Bool {
        let cleanDir = relativeFolderPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleanDir.isEmpty else { return false }

        for pdfRel in containedPDFRelativePaths {
            cleanupLocalLogState(forPDFRelativePath: pdfRel)
            knownRemotePDFPathsLower.remove(pdfRel.lowercased())
        }

        guard config.isConnected else { return false }
        await client.updateConfig(config)
        visualState = .syncing
        statusText = "Moving folder to Trash…"
        beginTransferProgress(phase: "Moving folder \((cleanDir as NSString).lastPathComponent) to Trash…", fraction: -1.0)

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        do {
            let trashID = try await client.ensureTrashFolderID()
            if let folderID = try await client.lookupRemoteDir(relativeDir: cleanDir) {
                _ = try await client.moveItemToTrashFolder(
                    fileID: folderID,
                    currentParents: nil,
                    trashFolderID: trashID,
                    originalPath: cleanDir,
                    kind: "folder",
                    deletedAtMs: nowMs
                )
                await client.invalidateFolderCaches()
            }

            var manifest = try await loadTrashManifest(trashFolderID: trashID)
            manifest.entries["folder:\(cleanDir.lowercased())"] = TrashManifestEntry(
                relativePath: cleanDir,
                kind: "folder",
                deletedAtMs: nowMs,
                device: config.deviceLabel
            )
            for pdfRel in containedPDFRelativePaths {
                let c = pdfRel.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                manifest.entries[c.lowercased()] = TrashManifestEntry(
                    relativePath: c,
                    kind: "file",
                    deletedAtMs: nowMs,
                    device: config.deviceLabel
                )
            }
            try await saveTrashManifest(manifest, trashFolderID: trashID)
            trashedItemsCount = max(trashedItemsCount + 1, manifest.entries.count)

            lastError = ""
            lastSyncedAt = Date()
            endTransferProgress()
            visualState = .ok
            statusText = "Synced"
            return true
        } catch {
            endTransferProgress()
            lastError = error.localizedDescription
            visualState = .error
            statusText = "Sync Error"
            return false
        }
    }

    @discardableResult
    func purgeExpiredDriveTrash(force: Bool = false) async -> (purged: Int, remaining: Int) {
        guard config.isConnected else { return (0, 0) }
        let lastRun = UserDefaults.standard.double(forKey: lastTrashPurgeKey)
        let nowSec = Date().timeIntervalSince1970
        if !force && lastRun > 0 && (nowSec - lastRun) < 86_400 {
            return (0, trashedItemsCount)
        }
        await client.updateConfig(config)
        do {
            let res = try await client.purgeExpiredTrash(retentionDays: GoogleDriveClient.trashRetentionDays)
            UserDefaults.standard.set(nowSec, forKey: lastTrashPurgeKey)
            trashedItemsCount = res.remaining
            return res
        } catch {
            return (0, trashedItemsCount)
        }
    }

    @discardableResult
    func emptyDriveTrashNow() async -> Int {
        guard config.isConnected else { return 0 }
        await client.updateConfig(config)
        visualState = .syncing
        statusText = "Emptying Drive Trash…"
        beginTransferProgress(phase: "Emptying Drive Trash…", fraction: -1.0)
        do {
            let removed = try await client.emptyTrashFolder()
            trashedItemsCount = 0
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastTrashPurgeKey)
            endTransferProgress()
            visualState = .ok
            statusText = "Synced"
            return removed
        } catch {
            endTransferProgress()
            lastError = error.localizedDescription
            visualState = .error
            statusText = "Sync Error"
            return 0
        }
    }

    @discardableResult
    func syncVault(
        vault: VaultManager,
        force: Bool = false
    ) async -> (downloadedPDFs: Int, uploadedPDFs: Int, syncedBooks: Int) {
        guard config.isConnected, vault.vaultURL != nil else {
            return (0, 0, 0)
        }
        if !force {
            guard config.autoSync, isSmartSyncEnabled() else {
                return (0, 0, 0)
            }
            let minInterval: TimeInterval = ProcessInfo.processInfo.isLowPowerModeEnabled ? 120.0 : 45.0
            if let last = lastVaultSyncAt, Date().timeIntervalSince(last) < minInterval {
                return (0, 0, 0)
            }
        }
        if let existingTask = activeVaultSyncTask {
            return await existingTask.value
        }

        let task = Task<(downloadedPDFs: Int, uploadedPDFs: Int, syncedBooks: Int), Never> { @MainActor [weak self] in
            guard let self else { return (0, 0, 0) }
            self.isSyncingVault = true
            self.visualState = .syncing
            self.statusText = "Checking Drive…"
            self.beginTransferProgress(phase: "Checking Google Drive…", fraction: -1.0)
            self.lastError = ""
            defer {
                self.isSyncingVault = false
                self.endTransferProgress()
                self.lastVaultSyncAt = Date()
            }

            var downloadedCount = 0
            var uploadedCount = 0
            var syncedAnnotationsCount = 0

            do {
                try Task.checkCancellation()
                await self.client.updateConfig(self.config)

                if !force, let savedToken = self.savedChangesToken(), !self.knownRemotePDFPathsLower.isEmpty {
                    let hasUntrackedLocalPDF = self.config.syncPDFs && vault.pdfs.contains {
                        !self.knownRemotePDFPathsLower.contains($0.relativePath.lowercased())
                    }
                    if !hasUntrackedLocalPDF {
                        if let delta = try? await self.client.listChangesSince(pageToken: savedToken, ownDeviceLabel: self.config.deviceLabel) {
                            self.saveChangesToken(delta.newStartPageToken)
                            if !delta.hasRelevantChanges {
                                _ = await self.purgeExpiredDriveTrash(force: false)
                                self.lastSyncedAt = Date()
                                self.visualState = .ok
                                self.statusText = "Synced"
                                return (0, 0, 0)
                            }
                        }
                    }
                }

                try Task.checkCancellation()
                self.statusText = "Scanning Drive…"
                self.beginTransferProgress(phase: "Scanning vault on Google Drive…", fraction: -1.0)

                let freshStartToken = try? await self.client.getStartPageToken()
                let rootID = try await self.client.resolveRootFolderID()
                let tree = try await self.client.listVaultTree(rootID: rootID)
                await vault.refreshPDFListAsync()

                let alignment = self.detectRootPrefixAlignment(localPDFs: vault.pdfs, remotePDFs: tree.pdfs)

                func remoteToLocalRel(_ remoteRel: String) -> String {
                    let trimmed = remoteRel.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    if !alignment.remoteStripPrefix.isEmpty && trimmed.lowercased().hasPrefix(alignment.remoteStripPrefix.lowercased()) {
                        return String(trimmed.dropFirst(alignment.remoteStripPrefix.count))
                    }
                    if !alignment.localExtraPrefix.isEmpty {
                        return alignment.localExtraPrefix + trimmed
                    }
                    return trimmed
                }

                func localToRemoteRel(_ localRel: String) -> String {
                    let trimmed = localRel.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    if !alignment.localExtraPrefix.isEmpty && trimmed.lowercased().hasPrefix(alignment.localExtraPrefix.lowercased()) {
                        return String(trimmed.dropFirst(alignment.localExtraPrefix.count))
                    }
                    if !alignment.remoteStripPrefix.isEmpty {
                        return alignment.remoteStripPrefix + trimmed
                    }
                    return trimmed
                }

                // 0a. Apply remote `.PencilInk-Trash` tombstones using aligned paths
                if let trashID = try await self.client.findExistingTrashFolderID() {
                    let manifest = try await self.loadTrashManifest(trashFolderID: trashID)
                    var removedLocally = false
                    for entry in manifest.entries.values {
                        if entry.device == self.config.deviceLabel { continue }
                        let alignedLocalRel = remoteToLocalRel(entry.relativePath)
                        let candidates = Set([entry.relativePath, alignedLocalRel])
                        if entry.kind == "folder" {
                            for dirCand in candidates where !dirCand.isEmpty {
                                let prefix = dirCand.lowercased() + "/"
                                let matchingLocal = vault.pdfs.filter {
                                    $0.relativeFolder.lowercased() == dirCand.lowercased()
                                        || $0.relativePath.lowercased().hasPrefix(prefix)
                                }
                                let newestLocalMs = matchingLocal.map { Int64($0.modifiedAt.timeIntervalSince1970 * 1000) }.max() ?? 0
                                if newestLocalMs <= entry.deletedAtMs {
                                    self.onRemoteDeletedPath?(dirCand, true)
                                    if vault.removeLocalFolderSilently(relativeFolder: dirCand) {
                                        removedLocally = true
                                    }
                                }
                            }
                        } else if entry.kind == "file" {
                            let candLower = Set(candidates.map { $0.lowercased() })
                            if let localItem = vault.pdfs.first(where: { candLower.contains($0.relativePath.lowercased()) }) {
                                let localMs = Int64(localItem.modifiedAt.timeIntervalSince1970 * 1000)
                                if localMs <= entry.deletedAtMs {
                                    self.onRemoteDeletedPath?(localItem.relativePath, false)
                                    if vault.removeLocalFileSilently(relativePath: localItem.relativePath) {
                                        self.cleanupLocalLogState(forPDFRelativePath: localItem.relativePath)
                                        removedLocally = true
                                    }
                                }
                            }
                        }
                    }
                    if removedLocally {
                        await vault.refreshPDFListAsync()
                    }
                }

                let purgeRes = await self.purgeExpiredDriveTrash(force: false)
                if purgeRes.remaining > 0 {
                    self.trashedItemsCount = purgeRes.remaining
                }

                // 0b. Mirror exact folder hierarchy from Drive <-> Local (including empty & nested subfolders!)
                var createdLocalFolders = 0
                for remoteDir in tree.folderIDByPath.keys.sorted() where !remoteDir.isEmpty {
                    let localDir = remoteToLocalRel(remoteDir)
                    if !localDir.isEmpty && vault.ensureLocalFolderExists(relativePath: localDir) {
                        createdLocalFolders += 1
                    }
                }
                for localFolder in vault.allFolders {
                    let remDir = localToRemoteRel(localFolder.relativePath)
                    if !remDir.isEmpty && tree.folderIDByPath[remDir] == nil {
                        _ = try? await self.client.ensureRemoteDir(relativeDir: remDir)
                    }
                }

                // 0c. Zero-Bandwidth Move Detection: mirror folder reorganizations locally without re-downloading!
                var movedLocallyCount = 0
                if self.config.syncPDFs {
                    let localLowerSet0 = Set(vault.pdfs.map { $0.relativePath.lowercased() })
                    let remoteLowerSet0 = Set(tree.pdfs.map { remoteToLocalRel($0.relativePath).lowercased() })

                    let localOnly = vault.pdfs.filter { !remoteLowerSet0.contains($0.relativePath.lowercased()) }
                    let remoteOnly = tree.pdfs.filter { !localLowerSet0.contains(remoteToLocalRel($0.relativePath).lowercased()) }

                    if !localOnly.isEmpty && !remoteOnly.isEmpty {
                        var localBySig: [String: [PDFItem]] = [:]
                        for loc in localOnly {
                            let sz = ((try? FileManager.default.attributesOfItem(atPath: loc.url.path))?[.size] as? NSNumber)?.int64Value ?? -1
                            guard sz > 0 else { continue }
                            let sig = "\(loc.url.lastPathComponent.lowercased())|\(sz)"
                            localBySig[sig, default: []].append(loc)
                        }
                        var remoteBySig: [String: [RemotePDFFile]] = [:]
                        for rem in remoteOnly where rem.sizeBytes > 0 {
                            let sig = "\(rem.meta.name.lowercased())|\(rem.sizeBytes)"
                            remoteBySig[sig, default: []].append(rem)
                        }
                        for (sig, locGroup) in localBySig where locGroup.count == 1 {
                            if let remGroup = remoteBySig[sig], remGroup.count == 1 {
                                let locItem = locGroup[0]
                                let targetLocalRel = remoteToLocalRel(remGroup[0].relativePath)
                                if vault.moveLocalPDFSilently(from: locItem.relativePath, to: targetLocalRel) {
                                    self.migrateLocalLogState(from: locItem.relativePath, to: targetLocalRel)
                                    movedLocallyCount += 1
                                }
                            }
                        }
                    }
                }
                if createdLocalFolders > 0 || movedLocallyCount > 0 {
                    await vault.refreshPDFListAsync()
                }

                var updatedKnownRemote = Set(tree.pdfs.map { remoteToLocalRel($0.relativePath).lowercased() })

                // 1. Download missing PDFs in 8 MB resumable chunks (smallest first)
                if self.config.syncPDFs {
                    var localLowerSet = Set(vault.pdfs.map { $0.relativePath.lowercased() })
                    let missingRemote = tree.pdfs
                        .filter { !localLowerSet.contains(remoteToLocalRel($0.relativePath).lowercased()) }
                        .sorted { $0.sizeBytes < $1.sizeBytes }

                    let totalDownloadBytes = missingRemote.reduce(Int64(0)) { $0 + max(0, $1.sizeBytes) }
                    var finishedDownloadBytes: Int64 = 0
                    let isoFull = Self.sharedISOFull
                    let isoBasic = Self.sharedISOBasic

                    for (idx, remote) in missingRemote.enumerated() {
                        try Task.checkCancellation()
                        let localRel = remoteToLocalRel(remote.relativePath)
                        let shortName = remote.meta.name
                        let baseDone = finishedDownloadBytes
                        self.statusText = "Downloading \(idx + 1)/\(missingRemote.count)…"
                        self.updateTransferProgress(
                            phase: "↓ \(idx + 1)/\(missingRemote.count) \(shortName)",
                            completedBytes: baseDone,
                            totalBytes: max(totalDownloadBytes, remote.sizeBytes),
                            forcePublish: true
                        )
                        do {
                            let tempFile = try await self.client.downloadFileChunked(
                                meta: remote.meta,
                                expectedSize: remote.sizeBytes
                            ) { [weak self] fileDone, fileTotal in
                                Task { @MainActor [weak self] in
                                    guard let self else { return }
                                    let aggDone = baseDone + fileDone
                                    let aggTot = max(totalDownloadBytes, baseDone + fileTotal)
                                    let lbl = "↓ \(idx + 1)/\(missingRemote.count) \(shortName) · \(self.formatBytes(fileDone)) / \(self.formatBytes(fileTotal))"
                                    self.updateTransferProgress(phase: lbl, completedBytes: aggDone, totalBytes: aggTot)
                                }
                            }
                            let modDate: Date? = remote.meta.modifiedTime.flatMap {
                                isoFull.date(from: $0) ?? isoBasic.date(from: $0)
                            }
                            _ = try vault.installDownloadedPDF(from: tempFile, relativePath: localRel, modifiedAt: modDate)
                            localLowerSet.insert(localRel.lowercased())
                            finishedDownloadBytes += max(0, remote.sizeBytes)
                            downloadedCount += 1
                            if downloadedCount % 4 == 0 {
                                await vault.refreshPDFListAsync()
                            }
                        } catch DriveClientError.cancelled {
                            throw DriveClientError.cancelled
                        } catch {
                            self.lastError = "Failed downloading \(shortName): \(error.localizedDescription)"
                        }
                    }

                    if downloadedCount > 0 && downloadedCount % 4 != 0 {
                        await vault.refreshPDFListAsync()
                    }

                    // 2. Upload local PDFs missing on Drive in 8 MB resumable chunks
                    let remoteLowerSet = Set(tree.pdfs.map { $0.relativePath.lowercased() })
                    let missingOnDrive = vault.pdfs.filter { item in
                        let remRel = localToRemoteRel(item.relativePath)
                        return !remoteLowerSet.contains(remRel.lowercased())
                    }

                    let uploadSizes: [Int64] = missingOnDrive.map { item in
                        ((try? FileManager.default.attributesOfItem(atPath: item.url.path))?[.size] as? NSNumber)?.int64Value ?? 0
                    }
                    let totalUploadBytes = uploadSizes.reduce(Int64(0), +)
                    var finishedUploadBytes: Int64 = 0

                    for (idx, item) in missingOnDrive.enumerated() {
                        try Task.checkCancellation()
                        let remRel = localToRemoteRel(item.relativePath)
                        let rawDir = (remRel as NSString).deletingLastPathComponent
                        let dir = (rawDir == "." || rawDir == "/") ? "" : rawDir
                        let fileName = (remRel as NSString).lastPathComponent
                        let fileSz = uploadSizes[idx]
                        let baseUp = finishedUploadBytes
                        self.statusText = "Uploading \(idx + 1)/\(missingOnDrive.count)…"
                        self.updateTransferProgress(
                            phase: "↑ \(idx + 1)/\(missingOnDrive.count) \(fileName)",
                            completedBytes: baseUp,
                            totalBytes: max(totalUploadBytes, fileSz),
                            forcePublish: true
                        )
                        do {
                            vault.ensureSecurityScopeActive()
                            let parentID = try await self.client.ensureRemoteDir(relativeDir: dir)
                            let doubleCheck = try await self.client.findChildren(parentID: parentID, name: fileName)
                            if doubleCheck.isEmpty {
                                _ = try await self.client.uploadPDFFileChunked(
                                    fileURL: item.url,
                                    name: fileName,
                                    parentID: parentID,
                                    resumeKey: remRel
                                ) { [weak self] upBytes, totBytes in
                                    Task { @MainActor [weak self] in
                                        guard let self else { return }
                                        let aggUp = baseUp + upBytes
                                        let aggTot = max(totalUploadBytes, baseUp + totBytes)
                                        let lbl = "↑ \(idx + 1)/\(missingOnDrive.count) \(fileName) · \(self.formatBytes(upBytes)) / \(self.formatBytes(totBytes))"
                                        self.updateTransferProgress(phase: lbl, completedBytes: aggUp, totalBytes: aggTot)
                                    }
                                }
                                uploadedCount += 1
                            }
                            updatedKnownRemote.insert(item.relativePath.lowercased())
                            finishedUploadBytes += fileSz
                        } catch DriveClientError.cancelled {
                            throw DriveClientError.cancelled
                        } catch {
                            self.lastError = "Failed uploading \(fileName): \(error.localizedDescription)"
                        }
                    }
                }

                // 3. Sync annotations for EVERY local book that EITHER has local ink OR has a remote `.ink.d` folder
                let remoteAnnotatedLower = Set(tree.annotatedPDFPaths.map { remoteToLocalRel($0).lowercased() })
                let remoteAnnotatedNames = Set(tree.annotatedPDFPaths.map { ($0 as NSString).lastPathComponent.lowercased() })
                let booksToSync = vault.pdfs.filter { item in
                    item.hasInk
                        || remoteAnnotatedLower.contains(item.relativePath.lowercased())
                        || remoteAnnotatedNames.contains(item.url.lastPathComponent.lowercased())
                }

                for (idx, item) in booksToSync.enumerated() {
                    try Task.checkCancellation()
                    let frac = Double(idx) / Double(max(1, booksToSync.count))
                    self.syncProgressFraction = frac
                    self.syncPhaseLabel = "Syncing notes \(idx + 1)/\(booksToSync.count): \(item.name)"
                    self.syncProgressText = self.syncPhaseLabel
                    let bookURL = item.url
                    let local = await Task.detached(priority: .utility) { InkDocument.load(for: bookURL) }.value
                    if let (merged, changed) = await self.syncBook(
                        pdfURL: bookURL,
                        relativePath: item.relativePath,
                        localDoc: local,
                        forceFolderScan: force || downloadedCount > 0
                    ) {
                        if changed {
                            await Task.detached(priority: .utility) { try? merged.save(for: bookURL) }.value
                        }
                        syncedAnnotationsCount += 1
                    }
                }

                if downloadedCount > 0 || syncedAnnotationsCount > 0 {
                    await vault.refreshPDFListAsync()
                }

                self.knownRemotePDFPathsLower = updatedKnownRemote
                if let tok = freshStartToken {
                    self.saveChangesToken(tok)
                }

                let totals = await self.client.getTransferTotals()
                self.sessionBytesUp = totals.up
                self.sessionBytesDown = totals.down
                self.lastSyncedAt = Date()
                if self.lastError.isEmpty {
                    self.visualState = .ok
                    self.statusText = "Synced"
                } else {
                    self.visualState = .error
                    self.statusText = "Sync Error"
                }
                self.lastDiagnostic = "Vault: \(tree.pdfs.count) on Drive · ↓\(downloadedCount) PDFs · ↑\(uploadedCount) uploaded · \(syncedAnnotationsCount) notes"
            } catch DriveClientError.cancelled {
                self.visualState = .ok
                self.statusText = "Paused (Resumable)"
            } catch is CancellationError {
                self.visualState = .ok
                self.statusText = "Paused (Resumable)"
            } catch {
                self.lastError = error.localizedDescription
                if let de = error as? DriveClientError, de.isFatalAuth {
                    self.visualState = .disconnected
                    self.statusText = "Sign-In Expired"
                } else {
                    self.visualState = .error
                    self.statusText = "Sync Error"
                }
            }
            return (downloadedCount, uploadedCount, syncedAnnotationsCount)
        }

        activeVaultSyncTask = task
        let res = await task.value
        activeVaultSyncTask = nil
        return res
    }

    /// Detects if the Drive folder has one extra wrapper directory (or local does) by comparing existing local PDFs with Drive PDFs.
    private func detectRootPrefixAlignment(
        localPDFs: [PDFItem],
        remotePDFs: [RemotePDFFile]
    ) -> (remoteStripPrefix: String, localExtraPrefix: String) {
        guard !localPDFs.isEmpty, !remotePDFs.isEmpty else { return ("", "") }
        let localSet = Set(localPDFs.map { $0.relativePath.lowercased() })
        let remoteSet = Set(remotePDFs.map { $0.relativePath.lowercased() })

        if !localSet.isDisjoint(with: remoteSet) {
            return ("", "")
        }

        var remotePrefixVotes: [String: Int] = [:]
        for rem in remotePDFs {
            let rLow = rem.relativePath.lowercased()
            for loc in localPDFs {
                let lLow = loc.relativePath.lowercased()
                if rLow.hasSuffix("/" + lLow) {
                    let prefLen = rem.relativePath.count - loc.relativePath.count
                    let pref = String(rem.relativePath.prefix(prefLen))
                    remotePrefixVotes[pref, default: 0] += 1
                }
            }
        }
        if let best = remotePrefixVotes.max(by: { $0.value < $1.value }), best.value > 0 {
            return (best.key, "")
        }

        var localPrefixVotes: [String: Int] = [:]
        for loc in localPDFs {
            let lLow = loc.relativePath.lowercased()
            for rem in remotePDFs {
                let rLow = rem.relativePath.lowercased()
                if lLow.hasSuffix("/" + rLow) {
                    let prefLen = loc.relativePath.count - rem.relativePath.count
                    let pref = String(loc.relativePath.prefix(prefLen))
                    localPrefixVotes[pref, default: 0] += 1
                }
            }
        }
        if let best = localPrefixVotes.max(by: { $0.value < $1.value }), best.value > 0 {
            return ("", best.key)
        }

        return ("", "")
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

        var st = await loadLogStateAsync(for: inkRelPath)
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
                    st.lastUploadedMd5.removeAll()
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

        // Prune any of our own strokes & text boxes that a remote device erased
        if let rv = remoteView {
            for key in Array(st.own.keys) {
                if let ss = st.own[key], ss.contains(where: { rv.deleted[$0.id] != nil }) {
                    st.own[key] = ss.filter { rv.deleted[$0.id] == nil }
                    st.markDirty(BookLogState.pageFile(label: st.label, key: key))
                }
            }
            for key in Array(st.ownTexts.keys) {
                if let tbs = st.ownTexts[key], tbs.contains(where: { rv.deleted[$0.id] != nil }) {
                    st.ownTexts[key] = tbs.filter { rv.deleted[$0.id] == nil }
                    st.markDirty(BookLogState.textsFile(label: st.label))
                }
            }
        }

        // 4. Derive merged document & upload ONLY our dirty log files CONCURRENTLY!
        let merged = deriveDoc(st: st, seen: seen, name: localDoc.name)

        let dirtyFiles = st.dirty
        var actualUploadedCount = 0
        if !dirtyFiles.isEmpty {
            var prepared: [(name: String, existingID: String?, payload: Data, md5: String)] = []
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
                let md5 = WireCodec.md5Hex(payload)
                if st.ids[name] != nil && st.lastUploadedMd5[name] == md5 {
                    st.dirty.removeAll { $0 == name }
                    continue
                }
                prepared.append((name, st.ids[name], payload, md5))
            }

            if !prepared.isEmpty {
                let clientRef = self.client
                let primaryID = folderID
                let uploadedTriples: [(String, String, String)] = try await withThrowingTaskGroup(of: (String, String, String).self) { groupTask in
                    for item in prepared {
                        groupTask.addTask {
                            let meta = try await clientRef.uploadMultipart(
                                fileID: item.existingID,
                                name: item.name,
                                parentID: primaryID,
                                payload: item.payload
                            )
                            return (item.name, meta.id, item.md5)
                        }
                    }
                    var out: [(String, String, String)] = []
                    for try await triple in groupTask { out.append(triple) }
                    return out
                }

                for (name, newID, md5) in uploadedTriples {
                    st.ids[name] = newID
                    st.lastUploadedMd5[name] = md5
                    st.dirty.removeAll { $0 == name }
                }
                actualUploadedCount = uploadedTriples.count
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
        touchBookLogLRU(inkRelPath)
        saveLogState(st, for: inkRelPath)

        let uploadedCount = actualUploadedCount
        let ownCount = st.ids.count
        let remoteCount = remoteGroups.count
        let didTransfer = (downloadedCount > 0 || uploadedCount > 0)
        lastDiagnostic = "\(resolvedPath) · \(remoteCount) remote · \(ownCount) own"
            + (downloadedCount > 0 ? " (↓\(downloadedCount))" : "")
            + (uploadedCount > 0 ? " (↑\(uploadedCount))" : "")
            + (parseFailures > 0 ? " · ⚠️ \(parseFailures) decode err" : "")

        let changedLocally = !sameContent(merged, localDoc)
        if changedLocally {
            let docToSave = merged
            await Task.detached(priority: .utility) { try? docToSave.save(for: pdfURL) }.value
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
        if a.pages.count != b.pages.count { return false }
        for (k, listA) in a.pages {
            guard let listB = b.pages[k], listA.count == listB.count else { return false }
            var orderMatch = true
            for i in 0..<listA.count {
                if listA[i].id != listB[i].id {
                    orderMatch = false
                    break
                }
            }
            if !orderMatch {
                if Set(listA.map { $0.id }) != Set(listB.map { $0.id }) { return false }
            }
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

    private func loadLogStateAsync(for inkRelPath: String) async -> BookLogState {
        if let cached = logStates[inkRelPath] {
            touchBookLogLRU(inkRelPath)
            return cached
        }
        let url = logStateURL(for: inkRelPath)
        let decoded: BookLogState? = await withCheckedContinuation { cont in
            logIOQueue.async {
                if let data = try? Data(contentsOf: url),
                   let st = try? JSONDecoder().decode(BookLogState.self, from: data) {
                    cont.resume(returning: st)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
        if let decoded {
            logStates[inkRelPath] = decoded
            touchBookLogLRU(inkRelPath)
            return decoded
        }
        let fresh = BookLogState(label: config.deviceLabel)
        logStates[inkRelPath] = fresh
        touchBookLogLRU(inkRelPath)
        return fresh
    }


    private func touchBookLogLRU(_ inkRelPath: String) {
        if let idx = logCacheLRU.firstIndex(of: inkRelPath) {
            logCacheLRU.remove(at: idx)
        }
        logCacheLRU.append(inkRelPath)
        while logCacheLRU.count > maxInMemoryBookLogs {
            let victim = logCacheLRU.removeFirst()
            if activeSyncTasks[victim] == nil {
                logStates.removeValue(forKey: victim)
                logSeen.removeValue(forKey: victim)
            }
        }
    }

    /// Releases cached in-memory CRDT log tables for inactive books (all persisted on disk in `sync-logs/`).
    func trimInMemoryCaches(keeping activeRelativePath: String? = nil) {
        let keepInk: String? = activeRelativePath.map {
            $0.hasSuffix(".ink.json") ? $0 : ($0 + ".ink.json")
        }
        for key in Array(logStates.keys) where key != keepInk && activeSyncTasks[key] == nil {
            logStates.removeValue(forKey: key)
            logSeen.removeValue(forKey: key)
        }
        logCacheLRU.removeAll { logStates[$0] == nil }
    }

    private let logIOQueue = DispatchQueue(label: "com.pencilink.synclog.io", qos: .utility)

    private func saveLogState(_ st: BookLogState, for inkRelPath: String) {
        let url = logStateURL(for: inkRelPath)
        logIOQueue.async {
            if let data = try? JSONEncoder().encode(st) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
