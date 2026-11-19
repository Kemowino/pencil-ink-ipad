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
    var deviceLabel: String = ""

    var isConnected: Bool { !refreshToken.isEmpty }
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
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 35
        cfg.timeoutIntervalForResource = 90
        return URLSession(configuration: cfg)
    }()
    private let onConfigUpdated: @Sendable (DriveConfig) -> Void

    init(config: DriveConfig, onConfigUpdated: @escaping @Sendable (DriveConfig) -> Void) {
        self.config = config
        self.onConfigUpdated = onConfigUpdated
    }

    func updateConfig(_ newConfig: DriveConfig) {
        if newConfig.driveFolder != config.driveFolder {
            rootFolderIDCache = nil
            dirIDCache.removeAll()
        }
        self.config = newConfig
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

    func findChildren(parentID: String, name: String, mimeType: String? = nil) async throws -> [DriveFileMeta] {
        let escName = escapeQuery(name)
        var q = "'\(parentID)' in parents and name = '\(escName)' and trashed=false"
        if let m = mimeType { q += " and mimeType = '\(m)'" }
        return try await listQuery(q)
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
