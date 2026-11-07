import Foundation
import Security
import SQLite3

private let cursorSafePrefix = "cursor-safe-storage:v1:"
private let cursorOAuthClientID = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB"
private let codexOAuthClientID = "app_EMoamEEZ73f0CkXaXp7hrann"

enum ServiceError: Error, CustomStringConvertible {
    case message(String)
    var description: String { switch self { case .message(let text): return text } }
}

struct UsageService {
    var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    func fetch() async -> [ProviderReading] {
        async let codex = fetchCodex()
        async let kimi = fetchKimi()
        let secrets = loadCursorSecrets()
        async let cursor = fetchCursor(secrets)
        async let grok = fetchGrok(secrets)
        return await [cursor, grok, codex, kimi]
    }

    // MARK: Cursor + Grok Bot

    private func fetchCursor(_ secrets: Result<CursorSecrets, ServiceError>) async -> ProviderReading {
        do {
            let token = try await usableCursorAccessToken(secrets)
            let (status, data) = try await get(
                "https://cursor.com/api/usage-summary",
                headers: ["Cookie": cursorCookie(token), "Accept": "application/json"])
            guard status == 200, let json = JSONValue.object(data) else {
                return .failed("Cursor", status == 401 ? "登录已失效，请在 Cursor 里重新登录" : "用量接口暂时不可用（\(status)）")
            }
            return UsageParsers.cursorSummary(json)
        } catch let error as ServiceError {
            return .failed("Cursor", error.description)
        } catch {
            return .failed("Cursor", "网络请求失败")
        }
    }

    private func fetchGrok(_ secrets: Result<CursorSecrets, ServiceError>) async -> ProviderReading {
        do {
            let token = try await usableCursorAccessToken(secrets)
            var request = URLRequest(url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus")!)
            request.httpMethod = "POST"
            request.httpBody = Data("{}".utf8)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
            let (status, data) = try await send(request)
            guard status == 200, let json = JSONValue.object(data) else {
                return .failed("Grok Bot", status == 401 ? "登录已失效，请在 Cursor 里重新登录" : "用量接口暂时不可用（\(status)）")
            }
            return UsageParsers.grokBot(json)
        } catch let error as ServiceError {
            return .failed("Grok Bot", error.description)
        } catch {
            return .failed("Grok Bot", "网络请求失败")
        }
    }

    private func usableCursorAccessToken(_ secrets: Result<CursorSecrets, ServiceError>) async throws -> String {
        let loaded = try secrets.get()
        if jwtExpired(loaded.access), let refresh = loaded.refresh {
            return try await refreshCursor(refresh) ?? loaded.access
        }
        return loaded.access
    }

    private func refreshCursor(_ refreshToken: String) async throws -> String? {
        var request = URLRequest(url: URL(string: "https://api2.cursor.sh/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = form([
            "grant_type": "refresh_token",
            "client_id": cursorOAuthClientID,
            "refresh_token": refreshToken,
        ])
        request.httpBody = body
        let (status, data) = try await send(request)
        guard status == 200, let json = JSONValue.object(data) else { return nil }
        return JSONValue.string(json["access_token"])
    }

    // MARK: Codex

    private func fetchCodex() async -> ProviderReading {
        do {
            let auth = try loadCodexAuth()
            var token = auth.access
            if jwtExpired(token), let refresh = auth.refresh, let renewed = try await refreshCodex(refresh) {
                token = renewed
            }
            let reading = try await codexUsage(access: token, account: auth.account)
            if reading.error == nil || auth.refresh == nil { return reading }
            if let renewed = try await refreshCodex(auth.refresh!), renewed != token {
                return try await codexUsage(access: renewed, account: auth.account)
            }
            return reading
        } catch let error as ServiceError {
            return .failed("Codex", error.description)
        } catch {
            return .failed("Codex", "网络请求失败")
        }
    }

    private func codexUsage(access: String, account: String?) async throws -> ProviderReading {
        var headers = [
            "Authorization": "Bearer \(access)",
            "Accept": "application/json",
        ]
        if let account, !account.isEmpty {
            headers["ChatGPT-Account-Id"] = account
        }
        let (status, data) = try await get("https://chatgpt.com/backend-api/wham/usage", headers: headers)
        guard status == 200, let json = JSONValue.object(data) else {
            return .failed("Codex", status == 401 ? "登录已过期，请重新运行 codex 登录" : "用量接口暂时不可用（\(status)）")
        }
        return UsageParsers.codex(json)
    }

    private func refreshCodex(_ refreshToken: String) async throws -> String? {
        var request = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form([
            "grant_type": "refresh_token",
            "client_id": codexOAuthClientID,
            "refresh_token": refreshToken,
        ])
        let (status, data) = try await send(request)
        guard status == 200, let json = JSONValue.object(data) else { return nil }
        return JSONValue.string(json["access_token"])
    }

    // MARK: Local credentials

    private struct CursorSecrets {
        var access: String
        var refresh: String?
    }

    private struct CodexAuth {
        var access: String
        var refresh: String?
        var account: String?
    }

    private func loadCursorSecrets() -> Result<CursorSecrets, ServiceError> {
        do {
            let password = try cursorKeychainPassword()
            let access = try readCursorToken(key: "cursorAuth/accessToken", password: password)
            let refresh = try? readCursorToken(key: "cursorAuth/refreshToken", password: password)
            return .success(CursorSecrets(access: access, refresh: refresh))
        } catch let error as ServiceError {
            return .failure(error)
        } catch {
            return .failure(.message("读取 Cursor 登录失败"))
        }
    }

    private func readCursorToken(key: String, password: String) throws -> String {
        let stored = try readCursorDB(key: key)
        if isJWT(stored) { return stored }
        guard stored.hasPrefix(cursorSafePrefix) else {
            throw ServiceError.message("认不出 Cursor 保存的登录格式")
        }
        guard let cipher = Data(base64Encoded: String(stored.dropFirst(cursorSafePrefix.count))),
              cipher.starts(with: [0x76, 0x31, 0x30]) else {
            throw ServiceError.message("Cursor 登录数据已损坏")
        }
        guard let plain = electronDecrypt(password: password, ciphertext: cipher.dropFirst(3)), isJWT(plain) else {
            throw ServiceError.message("无法解密 Cursor 登录，请在钥匙串提示里选择「始终允许」")
        }
        return plain
    }

    private func readCursorDB(key: String) throws -> String {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw ServiceError.message("没有找到 Cursor 的登录数据，请先打开并登录 Cursor")
        }
        let encoded = path.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path.path
        let uri = "file://\(encoded)?mode=ro"
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else {
            throw ServiceError.message("暂时读不到 Cursor 的登录数据")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3_000)
        var statement: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ServiceError.message("暂时读不到 Cursor 的登录数据")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw ServiceError.message("Cursor 里还没有登录")
        }
        if let text = sqlite3_column_text(statement, 0) {
            return String(cString: text)
        }
        throw ServiceError.message("Cursor 里还没有登录")
    }

    private func cursorKeychainPassword() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Cursor Safe Storage",
            kSecAttrAccount as String: "Cursor Key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
            switch status {
            case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
                throw ServiceError.message("需要允许读取钥匙串里的 Cursor Safe Storage")
            case errSecItemNotFound:
                throw ServiceError.message("找不到 Cursor 的钥匙串项，请先打开并登录 Cursor")
            default:
                throw ServiceError.message("读取钥匙串失败（\(status)）")
            }
        }
        return password.replacingOccurrences(of: "\u{0}", with: "")
    }

    private func loadCodexAuth() throws -> CodexAuth {
        let override = ProcessInfo.processInfo.environment["CODEX_HOME"]
        let home = override.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let url = home.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url), let json = JSONValue.object(data) else {
            throw ServiceError.message("Codex 未登录，先在终端完成 codex 登录")
        }
        let tokens = JSONValue.object(json["tokens"]) ?? [:]
        guard let access = JSONValue.string(tokens["access_token"]), !access.isEmpty else {
            throw ServiceError.message("Codex 未登录，先在终端完成 codex 登录")
        }
        return CodexAuth(
            access: access,
            refresh: JSONValue.string(tokens["refresh_token"]),
            account: JSONValue.string(tokens["account_id"]))
    }

    // MARK: Kimi

    private struct KimiLogin {
        var token: String
        var usageURLs: [String]
        var profileURL: String?
    }

    private func fetchKimi() async -> ProviderReading {
        do {
            let login = try loadKimiLogin()
            var payloads: [[String: Any]] = []
            var sawUnauthorized = false
            for url in login.usageURLs {
                let (status, data) = try await get(url, headers: [
                    "Authorization": "Bearer \(login.token)",
                    "Accept": "application/json",
                ])
                if status == 401 { sawUnauthorized = true }
                if status == 200, let json = JSONValue.object(data) {
                    payloads.append(json)
                }
            }
            guard !payloads.isEmpty else {
                return .failed("Kimi", sawUnauthorized ? "登录已过期，请打开 Kimi 或运行一次 kimi" : "用量接口暂时不可用")
            }
            var planHint: String?
            if let profileURL = login.profileURL {
                let (status, data) = try await get(profileURL, headers: [
                    "Authorization": "Bearer \(login.token)",
                    "Accept": "application/json",
                ])
                if status == 200, let json = JSONValue.object(data) {
                    planHint = JSONValue.string(json["user_level_name"])
                }
            }
            return UsageParsers.kimi(payloads, planHint: planHint)
        } catch let error as ServiceError {
            return .failed("Kimi", error.description)
        } catch {
            return .failed("Kimi", "网络请求失败")
        }
    }

    /// 只读本地登录。不刷新 Kimi 的 refresh token，避免把 CLI 或桌面版的会话轮换掉。
    private func loadKimiLogin() throws -> KimiLogin {
        if let key = ProcessInfo.processInfo.environment["KIMI_CODE_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            return kimiAPIKeyLogin(key, baseURL: nil, region: nil)
        }
        if let cli = freshKimiCLICredential() {
            let base = kimiCodeBase(region: cli.region)
            return KimiLogin(token: cli.token, usageURLs: [base + "/usages"], profileURL: base + "/me")
        }
        if let desktop = kimiDesktopAPIKey() {
            return kimiAPIKeyLogin(desktop.key, baseURL: desktop.baseURL, region: desktop.region)
        }
        if kimiCLICredentialExists() {
            throw ServiceError.message("Kimi Code 登录已过期，打开一次 Kimi 或运行 kimi")
        }
        throw ServiceError.message("Kimi 未登录")
    }

    private func kimiAPIKeyLogin(_ key: String, baseURL: String?, region: String?) -> KimiLogin {
        var urls: [String] = []
        if let baseURL, let usage = kimiUsageURL(baseURL) {
            urls.append(usage)
        }
        let standard = kimiCodeBase(region: region) + "/usages"
        if !urls.contains(standard) { urls.append(standard) }
        return KimiLogin(token: key, usageURLs: urls, profileURL: kimiCodeBase(region: region) + "/me")
    }

    private func freshKimiCLICredential() -> (token: String, region: String?)? {
        guard let json = readJSON(kimiCLICredentialURL()) else { return nil }
        guard let token = JSONValue.string(json["access_token"]), !token.isEmpty else { return nil }
        let expiry = JSONValue.quantity(json["expires_at"]) ?? 0
        guard expiry > Date().timeIntervalSince1970 + 60 else { return nil }
        return (token, JSONValue.string(json["region"]))
    }

    private func kimiCLICredentialExists() -> Bool {
        FileManager.default.fileExists(atPath: kimiCLICredentialURL().path)
    }

    private func kimiCLICredentialURL() -> URL {
        let override = ProcessInfo.processInfo.environment["KIMI_CODE_HOME"]
        let home = override.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code")
        return home.appendingPathComponent("credentials/kimi-code.json")
    }

    private func kimiDesktopAPIKey() -> (key: String, baseURL: String?, region: String?)? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/kimi-desktop")
        guard let json = readJSON(root.appendingPathComponent("daimon-share/daimon/config.json")),
              let credentials = JSONValue.object(json["credentials"]),
              let code = JSONValue.object(credentials["kimiCode"]),
              let key = JSONValue.string(code["apiKey"]), !key.isEmpty else { return nil }
        let region = JSONValue.string(readJSON(root.appendingPathComponent("bridge-store/region.json"))?["lastEffective"])
        return (key, JSONValue.string(code["baseUrl"]), region)
    }

    private func kimiCodeBase(region: String?) -> String {
        let value = (region ?? "").lowercased()
        if value.contains("international") || value.contains("overseas") || value == "global" {
            return "https://api.kimi.ai/coding/v1"
        }
        return "https://api.kimi.com/coding/v1"
    }

    private func kimiUsageURL(_ baseURL: String) -> String? {
        guard let components = URLComponents(string: baseURL),
              let host = components.host?.lowercased(),
              host == "kimi.com" || host.hasSuffix(".kimi.com") || host == "kimi.ai" || host.hasSuffix(".kimi.ai"),
              components.scheme == "https" else { return nil }
        var trimmed = baseURL
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed + "/usages"
    }

    private func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return JSONValue.object(data)
    }

    // MARK: HTTP

    private func get(_ url: String, headers: [String: String]) async throws -> (Int, Data) {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "GET"
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> (Int, Data) {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return (status, data)
    }

    private func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let text = fields.map { key, value in
            let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(key)=\(encoded)"
        }.joined(separator: "&")
        return Data(text.utf8)
    }

    private func cursorCookie(_ accessToken: String) -> String {
        let user = jwtSubject(accessToken)?.split(separator: "|").last.map(String.init) ?? ""
        return "WorkosCursorSessionToken=\(user)%3A%3A\(accessToken)"
    }
}

func electronDecrypt(password: String, ciphertext: Data) -> String? {
    let outCap = ciphertext.count + 32
    var output = [UInt8](repeating: 0, count: outCap)
    var outLen: size_t = 0
    let rc: Int32 = password.withCString { passwordPointer in
        ciphertext.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return Int32(-1) }
            return decrypt_electron_v10(passwordPointer, base, ciphertext.count, &output, outCap, &outLen)
        }
    }
    guard rc == 0, outLen > 0 else { return nil }
    return String(bytes: output.prefix(Int(outLen)), encoding: .utf8)
}

func electronEncrypt(password: String, plaintext: String) -> Data? {
    let plain = Array(plaintext.utf8)
    let outCap = plain.count + 32
    var output = [UInt8](repeating: 0, count: outCap)
    var outLen: size_t = 0
    let rc: Int32 = password.withCString { passwordPointer in
        plain.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return Int32(-1) }
            return encrypt_electron_v10(passwordPointer, base, plain.count, &output, outCap, &outLen)
        }
    }
    guard rc == 0, outLen > 0 else { return nil }
    return Data(output.prefix(Int(outLen)))
}

private func isJWT(_ value: String) -> Bool {
    value.split(separator: ".").count == 3 && value.hasPrefix("eyJ")
}

private func jwtSubject(_ token: String) -> String? {
    jwtPayload(token)?["sub"] as? String
}

private func jwtExpired(_ token: String) -> Bool {
    guard let exp = jwtPayload(token)?["exp"] as? Double ?? (jwtPayload(token)?["exp"] as? Int).map(Double.init) else {
        return false
    }
    return Date().timeIntervalSince1970 > exp - 60
}

private func jwtPayload(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var text = String(parts[1])
    text += String(repeating: "=", count: (4 - text.count % 4) % 4)
    guard let data = Data(base64Encoded: text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")) else {
        return nil
    }
    return JSONValue.object(data)
}
