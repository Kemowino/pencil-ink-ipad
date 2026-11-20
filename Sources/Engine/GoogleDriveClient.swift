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
    /// Normalized lowercase filenames -> remote PDFs (for smart matching across nested roots).
    let folderIDByPath: [String: String]
}

enum DriveClientError: LocalizedError {
    case notConnected
    case authExpired
    case apiError(status: Int, message: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to Google Drive."
        case .authExpired: return "Google sign-in expired. Please reconnect in Sync Settings."
        case .apiError(let status, let message): return "Drive error (\(status)): \(message)"
        case .invalidResponse: return "Unexpected response from Google Drive."
        }
    }

    var isFatalAuth: Bool {
        if case .authExpired = self { return true }
        if case .notConnected = self { return true }
        return false
    }
}

/// Lightweight native Google Drive v3 client matching Obsidian Pencil Ink's exact OAuth2 PKCE & folder rules.
actor GoogleDriveClient {
    static let scope = "https://www.googleapis.com/auth/drive"
    static let apiBase = "https://www.googleapis.com/drive/v3"
    static let uploadBase = "https://www.googleapis.com/upload/drive/v3"
    static let redirectURI = "http://127.0.0.1:8765"
    static let folderMime = "application/vnd.google-apps.folder"
    static let fields = "id,name,mimeType,md5Checksum,modifiedTime,size,parents,trashed"

    private(set) var config: DriveConfig
    private(set) var bytesUp: Int64 = 0
    private(set) var bytesDown: Int64 = 0

    private var rootFolderIDCache: (spec: String, id: String)?
    private var dirIDCache: [String: String] = [:]
    private var metaCache: [String: DriveFileMeta] = [:]
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 35
        cfg.timeoutIntervalForResource = 90
        return URLSession(configuration: cfg)
    }()
    private var onConfigUpdated: @Sendable (DriveConfig) -> Void

    init(config: DriveConfig, onConfigUpdated: @escaping @Sendable (DriveConfig) -> Void) {
        self.config = config
        self.onConfigUpdated = onConfigUpdated
    }

    func updateConfig(_ newConfig: DriveConfig) {
        if newConfig.driveFolder != config.driveFolder {
            rootFolderIDCache = nil
            dirIDCache.removeAll()
        }
        var merged = newConfig
        // Never overwrite a fresher refreshed access token with a stale cached one!
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

    // MARK: - OAuth2 PKCE (Exact Same Flow as Obsidian Pencil Ink)

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

    // MARK: - Transport with Automatic Retry & Token Refresh

    private func authedRequest(
        url: URL,
        method: String = "GET",
        contentType: String? = nil,
        body: Data? = nil,
        timeout: TimeInterval = 45
    ) async throws -> (Data, Int) {
        var attempt = 0
        while true {
            let token = try await ensureValidToken()
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
            req.httpMethod = method
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            req.setValue("no-cache", forHTTPHeaderField: "Pragma")
            if let ct = contentType {
                req.setValue(ct, forHTTPHeaderField: "Content-Type")
            }
            req.httpBody = body

            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 && attempt < 1 {
                config.expiresAt = 0
                attempt += 1
                continue
            }
            if (status == 429 || status >= 500) && attempt < 3 {
                attempt += 1
                let delayNs = UInt64(600_000_000 * (1 << attempt))
                try? await Task.sleep(nanoseconds: delayNs)
                continue
            }
            if status >= 200 && status < 400 {
                if let b = body { bytesUp += Int64(b.count) }
                bytesDown += Int64(data.count)
            }
            return (data, status)
        }
    }

    // MARK: - Drive Folders & Files

    func resolveRootFolderID() async throws -> String {
        let spec = config.driveFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Obsidian Vault"
            : config.driveFolder.trimmingCharacters(in: .whitespacesAndNewlines)

        if let cached = rootFolderIDCache, cached.spec == spec {
            return cached.id
        }

        // Check if spec is a Drive folder link or raw folder ID
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

    func getFile(id: String) async throws -> DriveFileMeta? {
        if let cached = metaCache[id] { return cached }
        let url = URL(string: "\(Self.apiBase)/files/\(id)?fields=\(Self.fields)")!
        let (data, status) = try await authedRequest(url: url, method: "GET")
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

    /// Searches Google Drive for any non-trashed folders with the exact name (e.g. `Book.pdf.ink.d`).
    func findFoldersNamed(_ name: String) async throws -> [DriveFileMeta] {
        let escName = escapeQuery(name)
        let q = "name = '\(escName)' and mimeType = '\(Self.folderMime)' and trashed=false"
        let results = try await listQuery(q)
        for f in results { metaCache[f.id] = f }
        return results
    }

    /// Walks up `parents` to verify a folder lives inside `rootID`, returning its relative path under `rootID` (or `nil` if outside).
    func resolvePathUnderRoot(folder: DriveFileMeta, rootID: String) async throws -> String? {
        if folder.id == rootID { return "" }
        var segments: [String] = [folder.name]
        var curParent = folder.parents?.first
        var hops = 0
        while let pid = curParent, hops < 12 {
            if pid == rootID {
                return segments.reversed().joined(separator: "/")
            }
            guard let parentMeta = try await getFile(id: pid), parentMeta.trashed != true else {
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
            let (data, status) = try await authedRequest(url: comps.url!)
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
        let (data, status) = try await authedRequest(url: url, method: "POST", contentType: "application/json", body: body)
        guard status >= 200 && status < 300 else {
            throw DriveClientError.apiError(status: status, message: parseErrorMessage(data))
        }
        return try JSONDecoder().decode(DriveFileMeta.self, from: data)
    }

    func download(fileID: String) async throws -> Data {
        let url = URL(string: "\(Self.apiBase)/files/\(fileID)?alt=media")!
        let (data, status) = try await authedRequest(url: url, method: "GET")
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

        let (data, status) = try await authedRequest(
            url: url,
            method: method,
            contentType: "multipart/related; boundary=\(boundary)",
            body: body
        )
        guard status >= 200 && status < 300 else {
            throw DriveClientError.apiError(status: status, message: parseErrorMessage(data))
        }
        return try JSONDecoder().decode(DriveFileMeta.self, from: data)
    }

    func renameFile(fileID: String, newName: String) async throws -> DriveFileMeta {
        let url = URL(string: "\(Self.apiBase)/files/\(fileID)?fields=\(Self.fields)")!
        let payload: [String: Any] = ["name": newName]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (data, status) = try await authedRequest(url: url, method: "PATCH", contentType: "application/json", body: body)
        guard status >= 200 && status < 300 else {
            throw DriveClientError.apiError(status: status, message: parseErrorMessage(data))
        }
        let meta = try JSONDecoder().decode(DriveFileMeta.self, from: data)
        metaCache[fileID] = meta
        return meta
    }

    /// Walks the Google Drive sync root folder via batched BFS to discover ALL remote `.pdf` files
    /// and ALL remote `.ink.d` annotation folders in just 1–3 API calls.
    func listVaultTree(rootID: String) async throws -> RemoteVaultTree {
        let ignoredFolders: Set<String> = [".obsidian", ".trash", ".git", ".stfolder", "__MACOSX"]
        var queue: [(id: String, relDir: String)] = [(rootID, "")]
        var visited = Set<String>([rootID])
        var pdfs: [RemotePDFFile] = []
        var annotatedPDFPaths = Set<String>()
        var folderIDByPath: [String: String] = ["": rootID]

        while !queue.isEmpty {
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
                        // Record the associated PDF relative path (strip `.ink.d`) without descending!
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

        // Deduplicate by lowercase relative path (prefer newest modifiedTime if duplicate on Drive)
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

    /// Streams a Google Drive file directly to a temporary URL on disk (~2 MB RAM even for 250 MB textbooks!).
    func downloadToFile(fileID: String) async throws -> URL {
        let url = URL(string: "\(Self.apiBase)/files/\(fileID)?alt=media")!
        var attempt = 0
        while true {
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
                let delayNs = UInt64(700_000_000 * (1 << attempt))
                try? await Task.sleep(nanoseconds: delayNs)
                continue
            }
            guard status >= 200 && status < 300 else {
                let errData = (try? Data(contentsOf: tempURL)) ?? Data()
                try? FileManager.default.removeItem(at: tempURL)
                throw DriveClientError.apiError(status: status, message: parseErrorMessage(errData))
            }

            // Move out of URLSession's ephemeral download location immediately so iOS doesn't purge it
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

    /// Uploads a local PDF file from disk using Google Drive Resumable Upload (zero 5 MB limit, low RAM!).
    func uploadPDFFile(fileURL: URL, name: String, parentID: String) async throws -> DriveFileMeta {
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attrs[.size] as? Int64) ?? 0

        let initURL = URL(string: "\(Self.uploadBase)/files?uploadType=resumable&fields=\(Self.fields)")!
        let metaObj: [String: Any] = [
            "name": name,
            "mimeType": "application/pdf",
            "parents": [parentID]
        ]
        let metaBody = try JSONSerialization.data(withJSONObject: metaObj)

        var uploadSessionURL: URL? = nil
        var attempt = 0
        while uploadSessionURL == nil {
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
            guard status >= 200 && status < 300,
                  let locStr = http?.value(forHTTPHeaderField: "Location"),
                  let locURL = URL(string: locStr) else {
                throw DriveClientError.apiError(status: status, message: parseErrorMessage(data))
            }
            uploadSessionURL = locURL
        }

        let putURL = uploadSessionURL!
        let token = try await ensureValidToken()
        var putReq = URLRequest(url: putURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 300)
        putReq.httpMethod = "PUT"
        putReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        putReq.setValue("application/pdf", forHTTPHeaderField: "Content-Type")
        putReq.setValue("\(fileSize)", forHTTPHeaderField: "Content-Length")

        let (respData, resp) = try await session.upload(for: putReq, fromFile: fileURL)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status >= 200 && status < 300 else {
            throw DriveClientError.apiError(status: status, message: parseErrorMessage(respData))
        }
        bytesUp += fileSize
        return try JSONDecoder().decode(DriveFileMeta.self, from: respData)
    }

    func trash(fileID: String) async throws {
        let url = URL(string: "\(Self.apiBase)/files/\(fileID)?fields=id")!
        let body = Data("{\"trashed\":true}".utf8)
        let (_, status) = try await authedRequest(url: url, method: "PATCH", contentType: "application/json", body: body)
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
