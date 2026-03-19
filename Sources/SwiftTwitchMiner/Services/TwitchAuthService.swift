import Foundation

/// Manages Twitch OAuth2 authentication using device code flow
public actor TwitchAuthService {
    /// Twitch's own Android app client ID — same one used by TwitchDropsMiner.
    /// Using this is required for the device flow to return a token accepted by GQL.
    public static let twitchAndroidClientId = "kd1unb4b3q4t58fwlpcbzcbnm76a8fp"

    private let clientId: String
    private let tokenURL = URL(string: "https://id.twitch.tv/oauth2/token")!
    private let deviceCodeURL = URL(string: "https://id.twitch.tv/oauth2/device")!
    private let validateURL = URL(string: "https://id.twitch.tv/oauth2/validate")!

    /// Android User-Agent that matches the Android client ID.
    private static let androidUserAgent =
        "Dalvik/2.1.0 (Linux; U; Android 16; SM-S911B Build/TP1A.220624.014) " +
        "tv.twitch.android.app/25.3.0/2503006"

    /// Generate a random 32-char lowercase hex string (matches Twitch's "unique_id" cookie format).
    private static func randomDeviceId() -> String {
        (0..<32).map { _ in String(format: "%x", Int.random(in: 0...15)) }.joined()
    }

    private var currentAccount: Account?
    private var refreshTask: Task<String, Error>?
    
    /// Callback fired when the token is successfully refreshed
    public var onTokenRefresh: (@Sendable (String) -> Void)?
    
    public func setTokenRefreshHandler(_ handler: (@Sendable (String) -> Void)?) {
        self.onTokenRefresh = handler
    }

    public init(clientId: String) {
        self.clientId = clientId
    }

    // MARK: - Device Code Flow

    /// Initiates device code flow and returns the device code info for user to authorize.
    /// Uses empty scopes — Twitch's web client ID works without any OAuth scopes.
    public func initiateDeviceFlow() async throws -> DeviceCodeResponse {
        var request = URLRequest(url: deviceCodeURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.androidUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.twitch.tv", forHTTPHeaderField: "Referer")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        // Random 32-char hex device ID (same as Twitch web app's "unique_id" cookie)
        request.setValue(Self.randomDeviceId(), forHTTPHeaderField: "X-Device-Id")

        // Use standard scopes from reference miner
        let scopes = [
            "user:read:email",
            "user:read:follows",
            "chat:read",
            "chat:edit",
            "channel:read:subscriptions"
        ].joined(separator: " ")

        let bodyParams = [
            "client_id": clientId,
            "scopes": scopes
        ]
        request.httpBody = bodyParams.percentEncoded()

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TwitchMinerError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            // Debug logging
            print("[TwitchAuthService] ERROR: status=\(httpResponse.statusCode)")
            print("[TwitchAuthService] Request body: client_id=\(clientId.prefix(6))... scopes=''")
            print("[TwitchAuthService] Response: \(message)")
            throw TwitchMinerError.apiError(statusCode: httpResponse.statusCode, message: message)
        }

        return try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
    }

    /// Polls for token after user authorizes the device code
    public func pollForToken(deviceCode: String, interval: Int) async throws -> Account {
        let intervalDuration = UInt64(interval) * 1_000_000_000 // Convert to nanoseconds
        print("[TwitchAuthService] Starting token polling, interval: \(interval)s")

        while true {
            try await Task.sleep(nanoseconds: intervalDuration)
            print("[TwitchAuthService] Polling for token...")

            do {
                let account = try await requestToken(deviceCode: deviceCode)
                print("[TwitchAuthService] Token received! User: \(account.username)")
                try await KeychainStorage.save(account: account)
                self.currentAccount = account
                return account
            } catch let error as TwitchMinerError {
                if case .apiError(let statusCode, let message) = error {
                    print("[TwitchAuthService] Poll error: status=\(statusCode), message=\(message)")
                    // authorization_pending means user hasn't authorized yet, continue polling
                    if message.contains("authorization_pending") {
                        print("[TwitchAuthService] Authorization pending, continuing...")
                        continue
                    }
                    // slow_down means we need to increase interval
                    if message.contains("slow_down") {
                        print("[TwitchAuthService] Rate limited, slowing down...")
                        try await Task.sleep(nanoseconds: intervalDuration)
                        continue
                    }
                }
                throw error
            }
        }
    }

    private func requestToken(deviceCode: String) async throws -> Account {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyParams = [
            "client_id": clientId,
            "device_code": deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
        ]
        request.httpBody = bodyParams.percentEncoded()

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TwitchMinerError.networkError("Invalid response")
        }

        if httpResponse.statusCode != 200 {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TwitchMinerError.apiError(statusCode: httpResponse.statusCode, message: message)
        }

        // Debug: print raw response
        let responseString = String(data: data, encoding: .utf8) ?? "<invalid utf8>"
        print("[TwitchAuthService] Token response: \(responseString)")
        
        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        print("[TwitchAuthService] Token decoded successfully")

        // Validate token to get user info
        let userInfo = try await validateToken(tokenResponse.accessToken)

        // expiresIn may be 0 when using Twitch's web client ID — default to 30 days
        let expirySeconds = tokenResponse.expiresIn > 0
            ? TimeInterval(tokenResponse.expiresIn)
            : 30 * 24 * 3600
        let account = Account(
            id: userInfo.userId,
            username: userInfo.login,
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            tokenExpiry: Date().addingTimeInterval(expirySeconds),
            scopes: tokenResponse.scope
        )

        return account
    }

    // MARK: - Token Refresh

    public func refreshTokenIfNeeded() async throws -> String {
        guard let account = currentAccount else {
            throw TwitchMinerError.sessionNotStarted
        }

        if account.isTokenValid {
            return account.accessToken
        }

        // If there's already a refresh in progress, wait for it
        if let refreshTask = refreshTask {
            return try await refreshTask.value
        }

        // Start new refresh task
        let task = Task<String, Error> {
            defer { self.refreshTask = nil }
            return try await performRefresh(account: account)
        }

        refreshTask = task
        return try await task.value
    }

    private func performRefresh(account: Account) async throws -> String {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyParams = [
            "client_id": clientId,
            "refresh_token": account.refreshToken,
            "grant_type": "refresh_token"
        ]
        request.httpBody = bodyParams.percentEncoded()

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw TwitchMinerError.tokenExpired
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)

        let refreshedAccount = Account(
            id: account.id,
            username: account.username,
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            tokenExpiry: Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn)),
            scopes: tokenResponse.scope
        )

        try await KeychainStorage.save(account: refreshedAccount)
        self.currentAccount = refreshedAccount
        
        onTokenRefresh?(refreshedAccount.accessToken)

        return refreshedAccount.accessToken
    }

    /// Validates an OAuth token and returns user info.
    public func validateToken(_ token: String) async throws -> (userId: String, login: String) {
        let response = try await validateTokenInternal(token)
        return (userId: response.userId, login: response.login)
    }

    /// Import a session from TDM cookies (auth-token).
    /// Validates the token and saves it to secure storage.
    public func importTDMSession(token: String) async throws -> Account {
        print("[TwitchAuthService] Importing TDM session, token prefix: \(token.prefix(10))... len=\(token.count)")

        // 1. Validate the token to get user info
        let userInfo = try await validateTokenInternal(token)
        print("[TwitchAuthService] Token validated for \(userInfo.login)")

        // 2. Create account (TDM sessions don't have refresh tokens, so we default to 30d expiry)
        let account = Account(
            id: userInfo.userId,
            username: userInfo.login,
            accessToken: token,
            refreshToken: "", // TDM cookies usually don't have this
            tokenExpiry: Date().addingTimeInterval(30 * 24 * 3600),
            scopes: userInfo.scopes
        )

        // 3. Save to secure storage
        try await KeychainStorage.save(account: account)
        return account
    }

    // MARK: - Token Validation

    private func validateTokenInternal(_ token: String) async throws -> TokenValidationResponse {
        var request = URLRequest(url: validateURL)
        request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TwitchMinerError.authenticationFailed("Token validation failed: no HTTP response")
        }
        let responseBody = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        print("[TwitchAuthService] Validate response: status=\(httpResponse.statusCode) body=\(responseBody.prefix(200))")
        guard httpResponse.statusCode == 200 else {
            throw TwitchMinerError.authenticationFailed("Token validation failed: HTTP \(httpResponse.statusCode) — \(responseBody.prefix(120))")
        }

        return try JSONDecoder().decode(TokenValidationResponse.self, from: data)
    }

    // MARK: - Account Management

    /// Directly set the current account (used when account is already known from a fresh auth flow).
    public func setCurrentAccount(_ account: Account) {
        self.currentAccount = account
    }

    public func loadSavedAccount() async throws -> Account? {
        if let account = try await KeychainStorage.loadFirstAccount() {
            self.currentAccount = account
            return account
        }
        return nil
    }
    
    /// Loads all accounts saved in the keychain.
    public func loadAllAccounts() async throws -> [Account] {
        return try await KeychainStorage.loadAllAccounts()
    }

    public func logout(accountId: String? = nil) async throws {
        if let id = accountId {
            try await KeychainStorage.deleteAccount(id: id)
            if currentAccount?.id == id {
                currentAccount = nil
            }
        } else if let account = currentAccount {
            try await KeychainStorage.deleteAccount(id: account.id)
            currentAccount = nil
        }
    }

    public var isAuthenticated: Bool {
        currentAccount?.isTokenValid == true
    }

    // MARK: - Response Models

    private struct TokenValidationResponse: Codable {
        let clientId: String
        let login: String
        let scopes: [String]
        let userId: String
        let expiresIn: Int

        enum CodingKeys: String, CodingKey {
            case clientId = "client_id"
            case login
            case scopes
            case userId = "user_id"
            case expiresIn = "expires_in"
        }
    }
}

// MARK: - Account Storage (Encrypted, File-based)
//
// Stores accounts as AES-256-GCM encrypted JSON in Application Support.
// Uses the macOS hardware UUID to derive a stable encryption key via HKDF,
// so no secret needs to be stored separately. The file is also chmod 0600.
//
// Why not Keychain? The traditional macOS keychain ties item access to the
// app's code-signing identity, which changes on every ad-hoc rebuild —
// causing accounts to "disappear" after each Xcode build.

import CryptoKit

private actor KeychainStorage {
    private static let directoryName = "com.swifttwitchminer"
    private static let fileName = "accounts.enc"

    private static var storageDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var storageURL: URL {
        storageDir.appendingPathComponent(fileName)
    }

    // MARK: - Encryption key (derived from hardware UUID)

    private static var encryptionKey: SymmetricKey {
        let uuid = hardwareUUID()
        let inputKey = SymmetricKey(data: Data(uuid.utf8))
        // HKDF-SHA256 derive a proper 256-bit key
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: Data("com.swifttwitchminer.accounts".utf8),
            info: Data("aes-256-gcm".utf8),
            outputByteCount: 32
        )
        return derived
    }

    private static func hardwareUUID() -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        guard let uuidData = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0),
              let uuid = uuidData.takeRetainedValue() as? String else {
            // Fallback — still stable per-machine
            return ProcessInfo.processInfo.hostName
        }
        return uuid
    }

    // MARK: - Read / Write helpers

    private static func readAll() -> [Account] {
        guard let encrypted = try? Data(contentsOf: storageURL) else { return [] }
        do {
            let box = try AES.GCM.SealedBox(combined: encrypted)
            let plaintext = try AES.GCM.open(box, using: encryptionKey)
            return try JSONDecoder().decode([Account].self, from: plaintext)
        } catch {
            print("[AccountStorage] Decryption failed: \(error.localizedDescription)")
            return []
        }
    }

    private static func writeAll(_ accounts: [Account]) throws {
        let plaintext = try JSONEncoder().encode(accounts)
        let sealed = try AES.GCM.seal(plaintext, using: encryptionKey)
        guard let combined = sealed.combined else {
            throw TwitchMinerError.authenticationFailed("Encryption failed")
        }
        try combined.write(to: storageURL, options: .atomic)
        // Restrict file to owner-only read/write
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
    }

    // MARK: - Public API

    static func save(account: Account) async throws {
        var accounts = readAll()
        accounts.removeAll { $0.id == account.id }
        accounts.append(account)
        try writeAll(accounts)
        print("[AccountStorage] Saved account \(account.username) (\(accounts.count) total)")
    }

    static func loadFirstAccount() async throws -> Account? {
        let accounts = readAll()
        print("[AccountStorage] loadFirstAccount: \(accounts.count) stored")
        return accounts.first
    }

    static func loadAllAccounts() async throws -> [Account] {
        let accounts = readAll()
        print("[AccountStorage] loadAllAccounts: \(accounts.count) stored")
        return accounts
    }

    static func deleteAccount(id: String) async throws {
        var accounts = readAll()
        accounts.removeAll { $0.id == id }
        try writeAll(accounts)
        print("[AccountStorage] Deleted account \(id), \(accounts.count) remaining")
    }
}

// MARK: - URL Encoding Helper

private extension Dictionary where Key == String, Value == String {
    func percentEncoded() -> Data {
        map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        .joined(separator: "&")
        .data(using: .utf8)!
    }
}
