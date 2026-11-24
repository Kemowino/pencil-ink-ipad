import Foundation
import CryptoKit

struct DriveFileMeta: Codable, Sendable {
    let id: String
    let name: String
    let mimeType: String?
    let md5Checksum: String?
    let modifiedTime: String?
    let size: String?
    let parents: [String]?
    let trashed: Bool?
    let appProperties: [String: String]?
}

struct DriveConfig: Codable, Sendable {
    var clientId: String = ""
    var clientSecret: String = ""
    var accessToken: String = ""
    var refreshToken: String = ""
    var expiresAt: Double = 0       // Unix ms
    var driveFolder: String = "Obsidian Vault"
    var autoSync: Bool = true
    var syncPDFs: Bool = true
    var deviceLabel: String = ""

    var isConnected: Bool { !refreshToken.isEmpty }

    enum CodingKeys: String, CodingKey {
        case clientId, clientSecret, accessToken, refreshToken, expiresAt, driveFolder, autoSync, syncPDFs, deviceLabel
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clientId = (try? c.decode(String.self, forKey: .clientId)) ?? ""
        clientSecret = (try? c.decode(String.self, forKey: .clientSecret)) ?? ""
        accessToken = (try? c.decode(String.self, forKey: .accessToken)) ?? ""
        refreshToken = (try? c.decode(String.self, forKey: .refreshToken)) ?? ""
        expiresAt = (try? c.decode(Double.self, forKey: .expiresAt)) ?? 0
        driveFolder = (try? c.decode(String.self, forKey: .driveFolder)) ?? "Obsidian Vault"
        autoSync = (try? c.decode(Bool.self, forKey: .autoSync)) ?? true
        syncPDFs = (try? c.decode(Bool.self, forKey: .syncPDFs)) ?? true
        deviceLabel = (try? c.decode(String.self, forKey: .deviceLabel)) ?? ""
    }
}

struct RemotePDFFile: Sendable {
    let meta: DriveFileMeta
    let relativePath: String
    let sizeBytes: Int64
}

struct RemoteVaultTree: Sendable {
    let pdfs: [RemotePDFFile]
    /// Relative paths (without `.ink.d`, e.g. `Folder/Book.pdf`) that have a remote `.ink.d` folder on Drive.
    let annotatedPDFPaths: Set<String>
    let folderIDByPath: [String: String]
}

struct DriveChangeDelta: Sendable {
    let hasRelevantChanges: Bool
    let hasVaultStructureChanges: Bool
    let changedFileIDs: Set<String>
    let changedParentIDs: Set<String>
    let newStartPageToken: String
}

enum DriveClientError: LocalizedError {
    case notConnected
    case authExpired
    case apiError(status: Int, message: String)
    case invalidResponse
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to Google Drive."
        case .authExpired: return "Google sign-in expired. Please reconnect in Sync Settings."
        case .apiError(let status, let message): return "Drive error (\(status)): \(message)"
        case .invalidResponse: return "Unexpected response from Google Drive."
        case .cancelled: return "Sync paused. Progress saved for instant resume."
        }
    }

    var isFatalAuth: Bool {
        if case .authExpired = self { return true }
        if case .notConnected = self { return true }
        return false
    }
}

private struct UploadCheckpoint: Codable {
    var uploadURI: String
    var fileSize: Int64
    var fileMtimeSec: Int64
    var name: String
    var parentID: String
    var createdAtMs: Int64
}

private struct DownloadCheckpoint: Codable {
    var fileID: String
    var md5Checksum: String
    var modifiedTime: String
    var totalBytes: Int64
}

/// Ultra-lean, battery-conscious Google Drive v3 client:
/// - **Exact 8 MB (`8_388_608` B) Chunked Resumable Uploads** with `308 Resume Incomplete` & `Content-Range: bytes */total` fast resume.
/// - **Exact 8 MB (`8_388_608` B) Chunked Byte-Range Downloads** with `.part` disk checkpoints & fast resume.
/// - **Drive Changes API (`changes/startPageToken` + `changes/list`)** for ~300-byte sub-10s delta detection & single-book wake.
/// - **`.PencilInk-Trash` Server-Side Move + 120-Day Automatic Retention Purge** (0 bytes transferred).
/// - **HTTP/2 connection reuse + Gzip JSON responses** for minimum CPU, battery, and internet usage.
actor GoogleDriveClient {
    static let scope = "https://www.googleapis.com/auth/drive"
    static let apiBase = "https://www.googleapis.com/drive/v3"
    static let uploadBase = "https://www.googleapis.com/upload/drive/v3"
    static let redirectURI = "http://127.0.0.1:8765"
    static let folderMime = "application/vnd.google-apps.folder"
    static let trashFolderName = ".PencilInk-Trash"
    static let trashRetentionDays: Int = 120
    /// Exact 8 MB (32 × 256 KB — strictly compliant with Google Drive API v3 resumable chunk rules).
    static let chunkSizeBytes: Int64 = 8 * 1024 * 1024
    static let fields = "id,name,mimeType,md5Checksum,modifiedTime,size,parents,trashed,appProperties"

    private(set) var config: DriveConfig
    private(set) var bytesUp: Int64 = 0
    private(set) var bytesDown: Int64 = 0

    private var rootFolderIDCache: (spec: String, id: String)?
    private var trashFolderIDCache: (rootID: String, id: String)?
    private var dirIDCache: [String: String] = [:]
    private var metaCache: [String: DriveFileMeta] = [:]

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.urlCache = nil
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.timeoutIntervalForRequest = 35
        cfg.timeoutIntervalForResource = 120
        cfg.allowsCellularAccess = true
        cfg.allowsExpensiveNetworkAccess = true
        cfg.allowsConstrainedNetworkAccess = true
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    private var onConfigUpdated: @Sendable (DriveConfig) -> Void

    private static let uploadStateDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("PencilInkNative/transfer-state", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let partialDownloadDir: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = caches.appendingPathComponent("PencilInkPartialDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init(config: DriveConfig, onConfigUpdated: @escaping @Sendable (DriveConfig) -> Void) {
        self.config = config
        self.onConfigUpdated = onConfigUpdated
    }

    func updateConfig(_ newConfig: DriveConfig) {
        if newConfig.driveFolder != config.driveFolder {
            rootFolderIDCache = nil
            trashFolderIDCache = nil
            dirIDCache.removeAll()
        }
        var merged = newConfig
        if !config.refreshToken.isEmpty,
           merged.refreshToken == config.refreshToken,
           !config.accessToken.isEmpty,
           config.expiresAt > merged.expiresAt {
            merged.accessToken = config.accessToken
            merged.expiresAt = config.expiresAt
        }
        self.config = merged
    }

    func setOnConfigUpdated(_ handler: @escaping @Sendable (DriveConfig) -> Void) {
        self.onConfigUpdated = handler
    }

    func getTransferTotals() -> (up: Int64, down: Int64) {
        (bytesUp, bytesDown)
    }

    func invalidateFolderCaches() {
        dirIDCache.removeAll()
        metaCache.removeAll()
    }

    // MARK: - OAuth2 PKCE

    static func beginAuth(clientId: String) -> (url: URL, verifier: String)? {
        var raw = [UInt8](repeating: 0, count: 48)
        for i in 0..<raw.count { raw[i] = UInt8.random(in: 0...255) }
        let verifier = base64URL(Data(raw))
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = base64URL(Data(digest))

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        comps?.queryItems = [
            URLQueryItem(name: "client_id", value: clientId.trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        guard let url = comps?.url else { return nil }
        return (url, verifier)
    }

    func finishAuth(pasted: String, verifier: String) async throws -> DriveConfig {
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        var code = trimmed
        if let url = URL(string: trimmed),
           let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let c = comps.queryItems?.first(where: { $0.name == "code" })?.value {
            code = c
        } else if let range = trimmed.range(of: "code=") {
            let tail = trimmed[range.upperBound...]
            let rawCode = tail.split(separator: "&").first.map(String.init) ?? String(tail)
            code = rawCode.removingPercentEncoding ?? rawCode
        }
        guard !code.isEmpty else {
            throw DriveClientError.apiError(status: 400, message: "Paste the full browser address bar URL first.")
        }

        let body = formEncode([
            "client_id": config.clientId.trimmingCharacters(in: .whitespacesAndNewlines),
            "client_secret": config.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines),
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": Self.redirectURI,
            "grant_type": "authorization_code"
        ])
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(body.utf8)

        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else {
            throw DriveClientError.apiError(status: status, message: parseErrorMessage(data))
        }
        let refresh = (json["refresh_token"] as? String) ?? config.refreshToken
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        config.accessToken = access
        config.refreshToken = refresh
        config.expiresAt = Date().timeIntervalSince1970 * 1000.0 + expiresIn * 1000.0
        onConfigUpdated(config)
        return config
    }

    private func ensureValidToken() async throws -> String {
        guard !config.refreshToken.isEmpty else { throw DriveClientError.notConnected }
        let nowMs = Date().timeIntervalSince1970 * 1000.0
        if !config.accessToken.isEmpty && nowMs < config.expiresAt - 60_000 {
            return config.accessToken
        }
        return try await refreshAccessToken()
    }

    private func refreshAccessToken() async throws -> String {
        let body = formEncode([
            "client_id": config.clientId.trimmingCharacters(in: .whitespacesAndNewlines),
            "client_secret": config.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines),
            "refresh_token": config.refreshToken,
            "grant_type": "refresh_token"
        ])
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(body.utf8)

        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (json["error"] as? String) == "invalid_grant" {
                config.accessToken = ""
                config.refreshToken = ""
                onConfigUpdated(config)
                throw DriveClientError.authExpired
            }
            throw DriveClientError.apiError(status: status, message: parseErrorMessage(data))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else {
            throw DriveClientError.invalidResponse
        }
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        config.accessToken = access
        config.expiresAt = Date().timeIntervalSince1970 * 1000.0 + expiresIn * 1000.0
        onConfigUpdated(config)
        return access
    }

    // MARK: - Transport with Automatic Retry, Gzip JSON & Token Refresh

    private func authedRequest(
        url: URL,
        method: String = "GET",
        contentType: String? = nil,
        body: Data? = nil,
        extraHeaders: [String: String] = [:],
        requestGzip: Bool = true,
        timeout: TimeInterval = 45
    ) async throws -> (Data, Int, HTTPURLResponse?) {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let token = try await ensureValidToken()
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
            req.httpMethod = method
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            req.setValue("no-cache", forHTTPHeaderField: "Pragma")
            if requestGzip {
                req.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
            } else {
                req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            }
            if let ct = contentType {
                req.setValue(ct, forHTTPHeaderField: "Content-Type")
            }
            for (k, v) in extraHeaders {
                req.setValue(v, forHTTPHeaderField: k)
            }
            req.httpBody = body

            do {
                let (data, resp) = try await session.data(for: req)
                let http = resp as? HTTPURLResponse
                let status = http?.statusCode ?? 0
                if status == 401 && attempt < 1 {
                    config.expiresAt = 0
                    attempt += 1
                    continue
                }
                if (status == 429 || status >= 500) && attempt < 3 {
                    attempt += 1
                    let delayNs = UInt64(600_000_000 * (1 << attempt))
                    try await Task.sleep(nanoseconds: delayNs)
                    continue
                }
                if status >= 200 && status < 400 {
                    if let b = body { bytesUp += Int64(b.count) }
                    bytesDown += Int64(data.count)
                }
                return (data, status, http)
            } catch is CancellationError {
                throw DriveClientError.cancelled
            } catch {
                if attempt < 2 && isTransientNetworkError(error) {
                    attempt += 1
                    let delayNs = UInt64(700_000_000 * (1 << attempt))
                    try await Task.sleep(nanoseconds: delayNs)
                    continue
                }
                throw error
            }
        }
    }

    private func isTransientNetworkError(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        switch ns.code {
        case NSURLErrorTimedOut,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorNotConnectedToInternet,
             NSURLErrorInternationalRoamingOff:
            return true
        default:
            return false
        }
    }

    // MARK: - Drive Changes API (~300-Byte Delta Check & Instant Single-Book Wake!)

    func getStartPageToken() async throws -> String {
        struct StartTokenResp: Codable { let startPageToken: String }
        let url = URL(string: "\(Self.apiBase)/changes/startPageToken")!
        let (data, status, _) = try await authedRequest(url: url, method: "GET")
        guard status >= 200 && status < 300,
              let decoded = try? JSONDecoder().decode(StartTokenResp.self, from: data) else {
            throw DriveClientError.apiError(status: status, message: parseErrorMessage(data))
        }
        return decoded.startPageToken
    }

    func listChangesSince(pageToken: String, ownDeviceLabel: String = "") async throws -> DriveChangeDelta {
        struct ChangeEntry: Codable {
            let fileId: String?
            let removed: Bool?
            let file: DriveFileMeta?
        }
        struct ChangesResp: Codable {
            let nextPageToken: String?
            let newStartPageToken: String?
            let changes: [ChangeEntry]?
        }

        let ownLogPrefix = ownDeviceLabel.isEmpty ? "" : "log_\(ownDeviceLabel.lowercased())_"
        let ownTxtName = ownDeviceLabel.isEmpty ? "" : "txt_\(ownDeviceLabel.lowercased()).json"

        var token = pageToken
        var latestStartToken = pageToken
        var changedIDs = Set<String>()
        var changedParentIDs = Set<String>()
        var hasChanges = false
        var hasStructureChanges = false
        var pagesFetched = 0

        while pagesFetched < 10 {
            pagesFetched += 1
            var comps = URLComponents(string: "\(Self.apiBase)/changes")!
            comps.queryItems = [
                URLQueryItem(name: "pageToken", value: token),
                URLQueryItem(name: "pageSize", value: "200"),
                URLQueryItem(name: "restrictToMyDrive", value: "true"),
                URLQueryItem(name: "fields", value: "nextPageToken,newStartPageToken,changes(fileId,removed,file(id,name,mimeType,trashed,parents))")
            ]
            let (data, status, _) = try await authedRequest(url: comps.url!, method: "GET")
            guard status >= 200 && status < 300,
                  let decoded = try? JSONDecoder().decode(ChangesResp.self, from: data) else {
                throw DriveClientError.apiError(status: status, message: parseErrorMessage(data))
            }
            if let list = decoded.changes, !list.isEmpty {
                for c in list {
                    if let f = c.file {
                        metaCache[f.id] = f
                        let nm = f.name.lowercased()
                        // Ignore our own device's shard echoes so we don't trigger self-pulls!
                        if (!ownLogPrefix.isEmpty && nm.hasPrefix(ownLogPrefix)) || (!ownTxtName.isEmpty && nm == ownTxtName) {
                            continue
                        }
                        if let fid = c.fileId { changedIDs.insert(fid) }
                        if let ps = f.parents {
                            for p in ps { changedParentIDs.insert(p) }
                        }
                        if nm.hasPrefix("log_") || nm.hasPrefix("txt_") {
                            hasChanges = true
                        } else if f.mimeType == Self.folderMime
                            || nm.hasSuffix(".pdf")
                            || nm == ".trash-manifest.json"
                            || f.trashed == true {
                            hasChanges = true
                            hasStructureChanges = true
                        }
                    } else if c.removed == true {
                        if let fid = c.fileId { changedIDs.insert(fid) }
                        hasChanges = true
                        hasStructureChanges = true
                    }
                }
            }
            if let nst = decoded.newStartPageToken, !nst.isEmpty {
                latestStartToken = nst
            }
            if let next = decoded.nextPageToken, !next.isEmpty {
                token = next
            } else {
                break
            }
        }
        return DriveChangeDelta(
            hasRelevantChanges: hasChanges,
            hasVaultStructureChanges: hasStructureChanges,
            changedFileIDs: changedIDs,
            changedParentIDs: changedParentIDs,
            newStartPageToken: latestStartToken
        )
    }

    // MARK: - Drive Folders & Files

    func resolveRootFolderID() async throws -> String {
        let spec = config.driveFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Obsidian Vault"
            : config.driveFolder.trimmingCharacters(in: .whitespacesAndNewlines)

        if let cached = rootFolderIDCache, cached.spec == spec {
            return cached.id
        }

        if let linkRange = spec.range(of: #"folders/([A-Za-z0-9_-]{10,})"#, options: .regularExpression) {
            let sub = String(spec[linkRange]).replacingOccurrences(of: "folders/", with: "")
            rootFolderIDCache = (spec, sub)
            return sub
        }
        if spec.range(of: #"^[A-Za-z0-9_-]{25,}$"#, options: .regularExpression) != nil {
            rootFolderIDCache = (spec, spec)
            return spec
        }

        let found = try await findChildren(parentID: "root", name: spec, mimeType: Self.folderMime)
        if let first = found.sorted(by: { $0.id < $1.id }).first {
            rootFolderIDCache = (spec, first.id)
            return first.id
        }
        let created = try await createFolder(name: spec, parentID: "root")
        rootFolderIDCache = (spec, created.id)
        return created.id
    }

    func ensureTrashFolderID() async throws -> String {
        let rootID = try await resolveRootFolderID()
        if let cached = trashFolderIDCache, cached.rootID == rootID {
            return cached.id
        }
        let found = try await findChildren(parentID: rootID, name: Self.trashFolderName, mimeType: Self.folderMime)
        if let existing = found.sorted(by: { $0.id < $1.id }).first {
            trashFolderIDCache = (rootID, existing.id)
            return existing.id
        }
        let made = try await createFolder(name: Self.trashFolderName, parentID: rootID)
        trashFolderIDCache = (rootID, made.id)
        return made.id
    }

    func findExistingTrashFolderID() async throws -> String? {
        let rootID = try await resolveRootFolderID()
        if let cached = trashFolderIDCache, cached.rootID == rootID {
            return cached.id
        }
        let found = try await findChildren(parentID: rootID, name: Self.trashFolderName, mimeType: Self.folderMime)
        if let existing = found.sorted(by: { $0.id < $1.id }).first {
            trashFolderIDCache = (rootID, existing.id)
            return existing.id
        }
        return nil
    }

    func ensureRemoteDir(relativeDir: String) async throws -> String {
        let rootID = try await resolveRootFolderID()
        let clean = relativeDir.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if clean.isEmpty { return rootID }
        if let cached = dirIDCache[clean] { return cached }

        let segments = clean.split(separator: "/").map(String.init)
        var currentParent = rootID
        var accPath = ""
        for seg in segments {
            accPath = accPath.isEmpty ? seg : "\(accPath)/\(seg)"
            if let cached = dirIDCache[accPath] {
                currentParent = cached
                continue
            }
            let found = try await findChildren(parentID: currentParent, name: seg, mimeType: Self.folderMime)
            if let existing = found.sorted(by: { $0.id < $1.id }).first {
                dirIDCache[accPath] = existing.id
                currentParent = existing.id
            } else {
                let made = try await createFolder(name: seg, parentID: currentParent)
                dirIDCache[accPath] = made.id
                currentParent = made.id
            }
        }
        return currentParent
    }

    func lookupRemoteDir(relativeDir: String) async throws -> String? {
        let rootID = try await resolveRootFolderID()
        let clean = relativeDir.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if clean.isEmpty { return rootID }
        if let cached = dirIDCache[clean] { return cached }

        let segments = clean.split(separator: "/").map(String.init)
        var currentParent = rootID
        var accPath = ""
        for seg in segments {
            accPath = accPath.isEmpty ? seg : "\(accPath)/\(seg)"
            if let cached = dirIDCache[accPath] {
                currentParent = cached
                continue
            }
            let found = try await findChildren(parentID: currentParent, name: seg, mimeType: Self.folderMime)
            guard let existing = found.sorted(by: { $0.id < $1.id }).first else {
                return nil
            }
            dirIDCache[accPath] = existing.id
            currentParent = existing.id
        }
        return currentParent
    }

    func getFile(id: String, bypassCache: Bool = false) async throws -> DriveFileMeta? {
        if !bypassCache, let cached = metaCache[id] { return cached }
        let url = URL(string: "\(Self.apiBase)/files/\(id)?fields=\(Self.fields)")!
        let (data, status, _) = try await authedRequest(url: url, method: "GET")
        if status == 404 { return nil }
        guard status >= 200 && status < 300 else {
            throw DriveClientError.apiError(status: status, message: parseErrorMessage(data))
        }
        let meta = try JSONDecoder().decode(DriveFileMeta.self, from: data)
        metaCache[id] = meta
        return meta
    }

    func findChildren(parentID: String, name: String, mimeType: String? = nil) async throws -> [DriveFileMeta] {
        let escName = escapeQuery(name)
        var q = "'\(parentID)' in parents and name = '\(escName)' and trashed=false"
        if let m = mimeType { q += " and mimeType = '\(m)'" }
        let results = try await listQuery(q)
        for f in results { metaCache[f.id] = f }
        return results
    }

    func findFoldersNamed(_ name: String) async throws -> [DriveFileMeta] {
        let escName = escapeQuery(name)
        let q = "name = '\(escName)' and mimeType = '\(Self.folderMime)' and trashed=false"
        let results = try await listQuery(q)
        for f in results { metaCache[f.id] = f }
        return results
    }

    func resolvePathUnderRoot(folder: DriveFileMeta, rootID: String) async throws -> String? {
        if folder.id == rootID { return "" }
        var segments: [String] = [folder.name]
        var curParent = folder.parents?.first
        var hops = 0
        while let pid = curParent, hops < 12 {
            if pid == rootID {
                let rel = segments.reversed().joined(separator: "/")
                if rel == Self.trashFolderName || rel.hasPrefix(Self.trashFolderName + "/") {
                    return nil
                }
                return rel
            }
            guard let parentMeta = try await getFile(id: pid), parentMeta.trashed != true else {
                return nil
            }
            if parentMeta.name == Self.trashFolderName {
                return nil
            }
            segments.append(parentMeta.name)
            curParent = parentMeta.parents?.first
            hops += 1
        }
        return nil
    }

    func listChildren(parentIDs: [String]) async throws -> [DriveFileMeta] {
        guard !parentIDs.isEmpty else { return [] }
        let clause = parentIDs.map { "'\($0)' in parents" }.joined(separator: " or ")
        let q = "(\(clause)) and trashed=false"
        return try await listQuery(q)
    }

    private func listQuery(_ query: String) async throws -> [DriveFileMeta] {
        struct ListResponse: Codable {
            let files: [DriveFileMeta]?
            let nextPageToken: String?
        }
        var out: [DriveFileMeta] = []
        var pageToken: String? = nil
        repeat {
            var comps = URLComponents(string: "\(Self.apiBase)/files")!
            var items = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "fields", value: "nextPageToken,files(\(Self.fields))")
            ]
            if let pt = pageToken { items.append(URLQueryItem(name: "pageToken", value: pt)) }
            comps.queryItems = items
            let (data, status, _) = try await authedRequest(url: comps.url!)
            guard status >= 200 && status < 300 else {
                throw DriveClientError.apiError(status: status, message: parseErrorMessage(data))
            }
            let decoded = try JSONDecoder().decode(ListResponse.self, from: data)
            if let files = decoded.files { out.append(contentsOf: files) }
            pageToken = decoded.nextPageToken
        } while pageToken != nil && !(pageToken?.isEmpty ?? true)
        return out
    }

    func createFolder(name: String, parentID: String) async throws -> DriveFileMeta {
        let url = URL(string: "\(Self.apiBase)/files?fields=\(Self.fields)")!
        let meta: [String: Any] = [
            "name": name,
            "mimeType": Self.folderMime,
            "parents": [parentID]
        ]
        let body = try JSONSerialization.data(withJSONObject: meta)
        let (data, status, _) = try await authedRequest(url: url, method: "POST", contentType: "application/json", body: body)
        guard status >= 200 && status < 300 else {
            throw DriveClientError.apiError(status: status, message: parseErrorMessage(data))
        }
        let decoded = try JSONDecoder().decode(DriveFileMeta.self, from: data)
        metaCache[decoded.id] = decoded
        return decoded
    }

    func download(fileID: String) async throws -> Data {
        let url = URL(string: "\(Self.apiBase)/files/\(fileID)?alt=media")!
        let (data, status, _) = try await authedRequest(url: url, method: "GET", requestGzip: false)
        guard status >= 200 && status < 300 else {
            throw DriveClientError.apiError(status: status, message: parseErrorMessage(data))
        }
        return data
    }

    func uploadMultipart(fileID: String?, name: String, parentID: String, payload: Data) async throws -> DriveFileMeta {
        let boundary = "pink" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        let method = fileID != nil ? "PATCH" : "POST"
        let baseStr = fileID != nil ? "\(Self.uploadBase)/files/\(fileID!)" : "\(Self.uploadBase)/files"
        let url = URL(string: "\(baseStr)?uploadType=multipart&fields=\(Self.fields)")!

        let metaObj: [String: Any] = fileID != nil ? [:] : ["name": name, "parents": [parentID]]
        let metaData = try JSONSerialization.data(withJSONObject: metaObj)
        let metaStr = String(data: metaData, encoding: .utf8) ?? "{}"

        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n\(metaStr)\r\n--\(boundary)\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(payload)
        body.append(Data("\r\n--\(boundary)--".utf8))

        let (data, status, _) = try await authedRequest(
            url: url,
            method: method,
            contentType: "multipart/related; boundary=\(boundary)",
            body: body
        )
        if status == 404 && fileID != nil {
            return try await uploadMultipart(fileID: nil, name: name, parentID: parentID, payload: payload)
        }
        guard status >= 200 && status < 300 else {
            throw DriveClientError.apiError(status: status, message: parseErrorMessage(data))
        }
        let decoded = try JSONDecoder().decode(DriveFileMeta.self, from: data)
        metaCache[decoded.id] = decoded
        return decoded
    }

    func renameFile(fileID: String, newName: String) async throws -> DriveFileMeta {
        let url = URL(string: "\(Self.apiBase)/files/\(fileID)?fields=\(Self.fields)")!
        let payload: [String: Any] = ["name": newName]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (data, status, _) = try await authedRequest(url: url, method: "PATCH", contentType: "application/json", body: body)
        guard status >= 200 && status < 300 else {
            throw DriveClientError.apiError(status: status, message: parseErrorMessage(data))
        }
        let meta = try JSONDecoder().decode(DriveFileMeta.self, from: data)
        metaCache[fileID] = meta
        return meta
    }

    // MARK: - `.PencilInk-Trash` 120-Day Server-Side Move & Auto-Purge

    func moveItemToTrashFolder(
        fileID: String,
        currentParents: [String]? = nil,
        trashFolderID: String,
        originalPath: String,
        kind: String,
        deletedAtMs: Int64
    ) async throws -> DriveFileMeta? {
        var oldParents = currentParents ?? []
        if oldParents.isEmpty, let meta = try await getFile(id: fileID, bypassCache: true) {
            oldParents = meta.parents ?? []
        }
        if oldParents.contains(trashFolderID) && oldParents.count == 1 {
            return metaCache[fileID]
        }
        let removeClause = oldParents.filter { $0 != trashFolderID }.joined(separator: ",")
        var comps = URLComponents(string: "\(Self.apiBase)/files/\(fileID)")!
        var qItems = [
            URLQueryItem(name: "addParents", value: trashFolderID),
            URLQueryItem(name: "fields", value: Self.fields)
        ]
        if !removeClause.isEmpty {
            qItems.append(URLQueryItem(name: "removeParents", value: removeClause))
        }
        comps.queryItems = qItems

        let safeOrigPath = String(originalPath.prefix(96))
        let payload: [String: Any] = [
            "appProperties": [
                "pinkDelMs": String(deletedAtMs),
                "pinkKind": kind,
                "pinkPath": safeOrigPath
            ]
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (data, status, _) = try await authedRequest(
            url: comps.url!,
            method: "PATCH",
            contentType: "application/json",
            body: body
        )
        if status == 404 { return nil }
        guard status >= 200 && status < 300 else {
            throw DriveClientError.apiError(status: status, message: parseErrorMessage(data))
        }
        let decoded = try JSONDecoder().decode(DriveFileMeta.self, from: data)
        metaCache[fileID] = decoded
        return decoded
    }

    func permanentlyDeleteFile(fileID: String) async throws {
        let url = URL(string: "\(Self.apiBase)/files/\(fileID)")!
        let (data, status, _) = try await authedRequest(url: url, method: "DELETE")
        metaCache.removeValue(forKey: fileID)
        if status == 404 || status == 204 || (status >= 200 && status < 300) {
            return
        }
        throw DriveClientError.apiError(status: status, message: parseErrorMessage(data))
    }

    func purgeExpiredTrash(retentionDays: Int = GoogleDriveClient.trashRetentionDays) async throws -> (purged: Int, remaining: Int) {
        Self.pruneStaleTransferCheckpoints()
        guard let trashID = try await findExistingTrashFolderID() else {
            return (0, 0)
        }
        let items = try await listChildren(parentIDs: [trashID])
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let cutoffMs = nowMs - Int64(retentionDays) * 86_400_000
        let isoFull = ISO8601DateFormatter()
        isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()

        var purged = 0
        var remaining = 0
        for item in items {
            if item.name == ".trash-manifest.json" { continue }
            let delMs: Int64
            if let s = item.appProperties?["pinkDelMs"], let parsed = Int64(s) {
                delMs = parsed
            } else if let mt = item.modifiedTime,
                      let d = isoFull.date(from: mt) ?? isoBasic.date(from: mt) {
                delMs = Int64(d.timeIntervalSince1970 * 1000)
            } else {
                delMs = nowMs
            }

            if delMs <= cutoffMs {
                try await permanentlyDeleteFile(fileID: item.id)
                purged += 1
            } else {
                remaining += 1
            }
        }
        return (purged, remaining)
    }

    private static func pruneStaleTransferCheckpoints() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        for dir in [partialDownloadDir, uploadStateDir] {
            guard let urls = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for u in urls {
                if let mtime = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                   mtime < cutoff {
                    try? fm.removeItem(at: u)
                }
            }
        }
    }

    func emptyTrashFolder() async throws -> Int {
        guard let trashID = try await findExistingTrashFolderID() else { return 0 }
        let items = try await listChildren(parentIDs: [trashID])
        var deleted = 0
        for item in items {
            if item.name == ".trash-manifest.json" { continue }
            try await permanentlyDeleteFile(fileID: item.id)
            deleted += 1
        }
        return deleted
    }

    func listVaultTree(rootID: String) async throws -> RemoteVaultTree {
        let ignoredFolders: Set<String> = [".obsidian", ".trash", ".git", ".stfolder", "__MACOSX", Self.trashFolderName]
        var queue: [(id: String, relDir: String)] = [(rootID, "")]
        var visited = Set<String>([rootID])
        var pdfs: [RemotePDFFile] = []
        var annotatedPDFPaths = Set<String>()
        var folderIDByPath: [String: String] = ["": rootID]

        while !queue.isEmpty {
            try Task.checkCancellation()
            let batchCount = min(15, queue.count)
            let batch = Array(queue.prefix(batchCount))
            queue.removeFirst(batchCount)

            var relByID: [String: String] = [:]
            for b in batch { relByID[b.id] = b.relDir }

            let children = try await listChildren(parentIDs: batch.map { $0.id })
            for child in children {
                if child.trashed == true { continue }
                let parentID = child.parents?.first(where: { relByID[$0] != nil }) ?? batch[0].id
                let parentRel = relByID[parentID] ?? ""
                let childRel = parentRel.isEmpty ? child.name : "\(parentRel)/\(child.name)"

                if child.mimeType == Self.folderMime {
                    if child.name.hasSuffix(".ink.d") {
                        let pdfRel = String(childRel.dropLast(6))
                        annotatedPDFPaths.insert(pdfRel)
                        continue
                    }
                    if child.name.hasPrefix(".") || ignoredFolders.contains(child.name) {
                        continue
                    }
                    if !visited.contains(child.id) {
                        visited.insert(child.id)
                        folderIDByPath[childRel] = child.id
                        dirIDCache[childRel] = child.id
                        queue.append((child.id, childRel))
                    }
                } else if child.name.lowercased().hasSuffix(".pdf") || child.mimeType == "application/pdf" {
                    let sz = Int64(child.size ?? "0") ?? 0
                    pdfs.append(RemotePDFFile(meta: child, relativePath: childRel, sizeBytes: sz))
                }
            }
        }

        var dedup: [String: RemotePDFFile] = [:]
        for item in pdfs {
            let key = item.relativePath.lowercased()
            if let existing = dedup[key] {
                if (item.meta.modifiedTime ?? "") > (existing.meta.modifiedTime ?? "") {
                    dedup[key] = item
                }
            } else {
                dedup[key] = item
            }
        }
        let sortedPDFs = dedup.values.sorted {
            $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending
        }
        return RemoteVaultTree(
            pdfs: sortedPDFs,
            annotatedPDFPaths: annotatedPDFPaths,
            folderIDByPath: folderIDByPath
        )
    }

    // MARK: - 8 MB Chunked Byte-Range Download with Fast Resume!

    func downloadFileChunked(
        meta: DriveFileMeta,
        expectedSize: Int64,
        onProgress: @escaping @Sendable (_ downloadedBytes: Int64, _ totalBytes: Int64) -> Void
    ) async throws -> URL {
        let fileID = meta.id
        let totalBytes = expectedSize > 0 ? expectedSize : (Int64(meta.size ?? "0") ?? 0)
        guard totalBytes > 0 else {
            return try await downloadToFileLegacy(fileID: fileID)
        }

        let partURL = Self.partialDownloadDir.appendingPathComponent("\(fileID).part")
        let ckptURL = Self.partialDownloadDir.appendingPathComponent("\(fileID).meta.json")
        let fm = FileManager.default
        let curMD5 = meta.md5Checksum ?? ""
        let curMod = meta.modifiedTime ?? ""

        var offset: Int64 = 0
        if fm.fileExists(atPath: partURL.path),
           let ckData = try? Data(contentsOf: ckptURL),
           let ck = try? JSONDecoder().decode(DownloadCheckpoint.self, from: ckData),
           ck.fileID == fileID,
           ck.totalBytes == totalBytes,
           ck.md5Checksum == curMD5,
           ck.modifiedTime == curMod {
            let existingSize = ((try? fm.attributesOfItem(atPath: partURL.path))?[.size] as? NSNumber)?.int64Value ?? 0
            if existingSize > 0 && existingSize <= totalBytes {
                offset = existingSize
            } else {
                try? fm.removeItem(at: partURL)
                try? fm.removeItem(at: ckptURL)
            }
        } else {
            try? fm.removeItem(at: partURL)
            try? fm.removeItem(at: ckptURL)
        }

        if !fm.fileExists(atPath: partURL.path) {
            fm.createFile(atPath: partURL.path, contents: nil)
        }
        let ck = DownloadCheckpoint(fileID: fileID, md5Checksum: curMD5, modifiedTime: curMod, totalBytes: totalBytes)
        if let ckData = try? JSONEncoder().encode(ck) {
            try? ckData.write(to: ckptURL, options: .atomic)
        }

        onProgress(offset, totalBytes)

        let url = URL(string: "\(Self.apiBase)/files/\(fileID)?alt=media")!
        let handle = try FileHandle(forUpdating: partURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))

        var didReset416 = false
        while offset < totalBytes {
            try Task.checkCancellation()
            let chunkEnd = min(totalBytes - 1, offset + Self.chunkSizeBytes - 1)
            let rangeHeader = "bytes=\(offset)-\(chunkEnd)"
            let (chunkData, status, _) = try await authedRequest(
                url: url,
                method: "GET",
                extraHeaders: ["Range": rangeHeader],
                requestGzip: false,
                timeout: 90
            )

            if status == 416 && !didReset416 {
                didReset416 = true
                offset = 0
                try handle.truncate(atOffset: 0)
                try handle.seek(toOffset: 0)
                continue
            }
            guard status == 206 || status == 200 else {
                throw DriveClientError.apiError(status: status, message: parseErrorMessage(chunkData))
            }
            if status == 200 && offset > 0 {
                try handle.truncate(atOffset: 0)
                try handle.seek(toOffset: 0)
                offset = 0
            }
            guard !chunkData.isEmpty else {
                throw DriveClientError.invalidResponse
            }

            try autoreleasepool {
                try handle.write(contentsOf: chunkData)
            }
            offset += Int64(chunkData.count)
            onProgress(min(offset, totalBytes), totalBytes)

            if status == 200 {
                break
            }
        }

        try? handle.close()
        try? fm.removeItem(at: ckptURL)

        let stableTemp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pink-dl-\(UUID().uuidString).pdf")
        try? fm.removeItem(at: stableTemp)
        try fm.moveItem(at: partURL, to: stableTemp)
        return stableTemp
    }

    private func downloadToFileLegacy(fileID: String) async throws -> URL {
        let url = URL(string: "\(Self.apiBase)/files/\(fileID)?alt=media")!
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let token = try await ensureValidToken()
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 300)
            req.httpMethod = "GET"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (tempURL, resp) = try await session.download(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 && attempt < 1 {
                try? FileManager.default.removeItem(at: tempURL)
                config.expiresAt = 0
                attempt += 1
                continue
            }
            if (status == 429 || status >= 500) && attempt < 3 {
                try? FileManager.default.removeItem(at: tempURL)
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(700_000_000 * (1 << attempt)))
                continue
            }
            guard status >= 200 && status < 300 else {
                let errData = (try? Data(contentsOf: tempURL)) ?? Data()
                try? FileManager.default.removeItem(at: tempURL)
                throw DriveClientError.apiError(status: status, message: parseErrorMessage(errData))
            }

            let stableTemp = FileManager.default.temporaryDirectory
                .appendingPathComponent("pink-dl-\(UUID().uuidString).pdf")
            try? FileManager.default.removeItem(at: stableTemp)
            try FileManager.default.moveItem(at: tempURL, to: stableTemp)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: stableTemp.path),
               let fileSize = attrs[.size] as? Int64 {
                bytesDown += fileSize
            }
            return stableTemp
        }
    }

    // MARK: - 8 MB Chunked Resumable Upload with Fast Resume (`308 Resume Incomplete`)!

    private func uploadCheckpointURL(for key: String) -> URL {
        let hash = WireCodec.md5Hex(Data(key.utf8))
        return Self.uploadStateDir.appendingPathComponent("up_\(hash).json")
    }

    func uploadPDFFileChunked(
        fileURL: URL,
        name: String,
        parentID: String,
        resumeKey: String,
        onProgress: @escaping @Sendable (_ uploadedBytes: Int64, _ totalBytes: Int64) -> Void
    ) async throws -> DriveFileMeta {
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtimeSec = Int64(((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0).rounded())

        if fileSize == 0 {
            let meta = try await uploadMultipart(fileID: nil, name: name, parentID: parentID, payload: Data())
            onProgress(0, 0)
            return meta
        }

        let ckURL = uploadCheckpointURL(for: resumeKey)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        var uploadURI: URL? = nil
        var offset: Int64 = 0

        if let ckData = try? Data(contentsOf: ckURL),
           let ck = try? JSONDecoder().decode(UploadCheckpoint.self, from: ckData),
           ck.fileSize == fileSize,
           ck.fileMtimeSec == mtimeSec,
           ck.name == name,
           ck.parentID == parentID,
           (nowMs - ck.createdAtMs) < 6 * 86_400_000,
           let savedURL = URL(string: ck.uploadURI) {
            let probe = try await probeResumableOffset(uploadURL: savedURL, totalSize: fileSize)
            switch probe {
            case .completed(let meta):
                try? FileManager.default.removeItem(at: ckURL)
                onProgress(fileSize, fileSize)
                metaCache[meta.id] = meta
                return meta
            case .resumeAt(let nextByte):
                uploadURI = savedURL
                offset = min(fileSize, max(0, nextByte))
            case .expired:
                try? FileManager.default.removeItem(at: ckURL)
            }
        }

        if uploadURI == nil {
            let freshURL = try await initiateResumableUpload(name: name, parentID: parentID, fileSize: fileSize)
            uploadURI = freshURL
            offset = 0
            let ck = UploadCheckpoint(
                uploadURI: freshURL.absoluteString,
                fileSize: fileSize,
                fileMtimeSec: mtimeSec,
                name: name,
                parentID: parentID,
                createdAtMs: nowMs
            )
            if let encoded = try? JSONEncoder().encode(ck) {
                try? encoded.write(to: ckURL, options: .atomic)
            }
        }

        guard var activeUploadURL = uploadURI else {
            throw DriveClientError.invalidResponse
        }

        onProgress(offset, fileSize)

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var sessionRestarts = 0
        while offset < fileSize {
            try Task.checkCancellation()
            let remaining = fileSize - offset
            let chunkLen = min(Self.chunkSizeBytes, remaining)

            let chunkData: Data = try autoreleasepool {
                try handle.seek(toOffset: UInt64(offset))
                return try handle.read(upToCount: Int(chunkLen)) ?? Data()
            }
            guard !chunkData.isEmpty else {
                throw DriveClientError.invalidResponse
            }

            let actualEnd = offset + Int64(chunkData.count) - 1
            let contentRange = "bytes \(offset)-\(actualEnd)/\(fileSize)"
            var chunkAttempt = 0
            var chunkAccepted = false

            while !chunkAccepted {
                try Task.checkCancellation()
                let token = try await ensureValidToken()
                var putReq = URLRequest(url: activeUploadURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 90)
                putReq.httpMethod = "PUT"
                putReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                putReq.setValue("application/pdf", forHTTPHeaderField: "Content-Type")
                putReq.setValue("\(chunkData.count)", forHTTPHeaderField: "Content-Length")
                putReq.setValue(contentRange, forHTTPHeaderField: "Content-Range")
                putReq.httpBody = chunkData

                do {
                    let (respData, resp) = try await session.data(for: putReq)
                    let http = resp as? HTTPURLResponse
                    let status = http?.statusCode ?? 0

                    if status == 200 || status == 201 {
                        bytesUp += Int64(chunkData.count)
                        try? FileManager.default.removeItem(at: ckURL)
                        onProgress(fileSize, fileSize)
                        let meta = try JSONDecoder().decode(DriveFileMeta.self, from: respData)
                        metaCache[meta.id] = meta
                        return meta
                    }

                    if status == 308 {
                        bytesUp += Int64(chunkData.count)
                        if let rangeStr = http?.value(forHTTPHeaderField: "Range"),
                           let serverNext = Self.parseRangeNextByte(rangeStr) {
                            offset = min(fileSize, serverNext)
                        } else {
                            offset = actualEnd + 1
                        }
                        onProgress(offset, fileSize)
                        chunkAccepted = true
                        continue
                    }

                    if status == 401 && chunkAttempt < 1 {
                        config.expiresAt = 0
                        chunkAttempt += 1
                        continue
                    }

                    if (status == 404 || status == 410) && sessionRestarts < 1 {
                        sessionRestarts += 1
                        try? FileManager.default.removeItem(at: ckURL)
                        activeUploadURL = try await initiateResumableUpload(name: name, parentID: parentID, fileSize: fileSize)
                        offset = 0
                        let ck = UploadCheckpoint(
                            uploadURI: activeUploadURL.absoluteString,
                            fileSize: fileSize,
                            fileMtimeSec: mtimeSec,
                            name: name,
                            parentID: parentID,
                            createdAtMs: Int64(Date().timeIntervalSince1970 * 1000)
                        )
                        if let encoded = try? JSONEncoder().encode(ck) {
                            try? encoded.write(to: ckURL, options: .atomic)
                        }
                        chunkAccepted = true
                        break
                    }

                    if (status == 429 || status >= 500) && chunkAttempt < 3 {
                        chunkAttempt += 1
                        try await Task.sleep(nanoseconds: UInt64(700_000_000 * (1 << chunkAttempt)))
                        if case .resumeAt(let nextByte) = try? await probeResumableOffset(uploadURL: activeUploadURL, totalSize: fileSize),
                           nextByte > offset {
                            offset = min(fileSize, nextByte)
                            onProgress(offset, fileSize)
                            chunkAccepted = true
                            break
                        }
                        continue
                    }

                    throw DriveClientError.apiError(status: status, message: parseErrorMessage(respData))
                } catch is CancellationError {
                    throw DriveClientError.cancelled
                } catch {
                    if chunkAttempt < 3 && isTransientNetworkError(error) {
                        chunkAttempt += 1
                        try await Task.sleep(nanoseconds: UInt64(800_000_000 * (1 << chunkAttempt)))
                        if let probe = try? await probeResumableOffset(uploadURL: activeUploadURL, totalSize: fileSize) {
                            switch probe {
                            case .completed(let meta):
                                try? FileManager.default.removeItem(at: ckURL)
                                onProgress(fileSize, fileSize)
                                metaCache[meta.id] = meta
                                return meta
                            case .resumeAt(let nextByte) where nextByte > offset:
                                offset = min(fileSize, nextByte)
                                onProgress(offset, fileSize)
                                chunkAccepted = true
                                continue
                            default:
                                break
                            }
                        }
                        continue
                    }
                    throw error
                }
            }
        }

        if case .completed(let meta) = try await probeResumableOffset(uploadURL: activeUploadURL, totalSize: fileSize) {
            try? FileManager.default.removeItem(at: ckURL)
            onProgress(fileSize, fileSize)
            metaCache[meta.id] = meta
            return meta
        }
        throw DriveClientError.invalidResponse
    }

    private enum ResumableProbeResult {
        case completed(DriveFileMeta)
        case resumeAt(Int64)
        case expired
    }

    private func probeResumableOffset(uploadURL: URL, totalSize: Int64) async throws -> ResumableProbeResult {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let token = try await ensureValidToken()
            var req = URLRequest(url: uploadURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
            req.httpMethod = "PUT"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("0", forHTTPHeaderField: "Content-Length")
            req.setValue("bytes */\(totalSize)", forHTTPHeaderField: "Content-Range")

            let (data, resp) = try await session.data(for: req)
            let http = resp as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if status == 401 && attempt < 1 {
                config.expiresAt = 0
                attempt += 1
                continue
            }
            if status == 200 || status == 201 {
                if let meta = try? JSONDecoder().decode(DriveFileMeta.self, from: data) {
                    return .completed(meta)
                }
                return .expired
            }
            if status == 308 {
                if let rangeStr = http?.value(forHTTPHeaderField: "Range"),
                   let next = Self.parseRangeNextByte(rangeStr) {
                    return .resumeAt(next)
                }
                return .resumeAt(0)
            }
            return .expired
        }
    }

    private func initiateResumableUpload(name: String, parentID: String, fileSize: Int64) async throws -> URL {
        let initURL = URL(string: "\(Self.uploadBase)/files?uploadType=resumable&fields=\(Self.fields)")!
        let metaObj: [String: Any] = [
            "name": name,
            "mimeType": "application/pdf",
            "parents": [parentID]
        ]
        let metaBody = try JSONSerialization.data(withJSONObject: metaObj)

        var attempt = 0
        while true {
            try Task.checkCancellation()
            let token = try await ensureValidToken()
            var initReq = URLRequest(url: initURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 45)
            initReq.httpMethod = "POST"
            initReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            initReq.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            initReq.setValue("application/pdf", forHTTPHeaderField: "X-Upload-Content-Type")
            initReq.setValue("\(fileSize)", forHTTPHeaderField: "X-Upload-Content-Length")
            initReq.httpBody = metaBody

            let (data, resp) = try await session.data(for: initReq)
            let http = resp as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if status == 401 && attempt < 1 {
                config.expiresAt = 0
                attempt += 1
                continue
            }
            if (status == 429 || status >= 500) && attempt < 3 {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(600_000_000 * (1 << attempt)))
                continue
            }
            guard status >= 200 && status < 300,
                  let locStr = http?.value(forHTTPHeaderField: "Location"),
                  let locURL = URL(string: locStr) else {
                throw DriveClientError.apiError(status: status, message: parseErrorMessage(data))
            }
            return locURL
        }
    }

    private static func parseRangeNextByte(_ header: String) -> Int64? {
        guard let dashIdx = header.lastIndex(of: "-") else { return nil }
        let tail = header[header.index(after: dashIdx)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastByte = Int64(tail), lastByte >= 0 else { return nil }
        return lastByte + 1
    }

    func trash(fileID: String) async throws {
        let url = URL(string: "\(Self.apiBase)/files/\(fileID)?fields=id")!
        let body = Data("{\"trashed\":true}".utf8)
        let (_, status, _) = try await authedRequest(url: url, method: "PATCH", contentType: "application/json", body: body)
        metaCache.removeValue(forKey: fileID)
        if status == 404 { return }
    }

    // MARK: - Utilities

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func formEncode(_ dict: [String: String]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=/")
        return dict.map { k, v in
            let ek = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
            return "\(ek)=\(ev)"
        }.joined(separator: "&")
    }

    private func escapeQuery(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    private func parseErrorMessage(_ data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let desc = json["error_description"] as? String { return String(desc.prefix(160)) }
            if let errObj = json["error"] as? [String: Any], let msg = errObj["message"] as? String {
                return String(msg.prefix(160))
            }
            if let errStr = json["error"] as? String { return String(errStr.prefix(160)) }
        }
        return String((String(data: data, encoding: .utf8) ?? "Network error").prefix(160))
    }
}
