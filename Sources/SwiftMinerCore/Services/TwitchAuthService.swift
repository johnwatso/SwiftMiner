import Foundation

/// Manages Twitch OAuth2 authentication using device code flow
public actor TwitchAuthService {
    /// Twitch's own Android app client ID — same one used by TwitchDropsMiner.
    /// Using this is required for the device flow to return a token accepted by GQL.
    public static let twitchAndroidClientId = "kd1unb4b3q4t58fwlpcbzcbnm76a8fp"

    private let clientId: String
    private let tokenStore: any TokenStore
    private let tokenURL = URL(string: "https://id.twitch.tv/oauth2/token")!
    private let deviceCodeURL = URL(string: "https://id.twitch.tv/oauth2/device")!
    private let validateURL = URL(string: "https://id.twitch.tv/oauth2/validate")!
    private let revokeURL = URL(string: "https://id.twitch.tv/oauth2/revoke")!

    /// Android User-Agent that matches the Android client ID. Starts as a
    /// random pick (device-code flow has no account yet); swapped to a
    /// sticky-per-account UA once `setAccountId(_:)` is called.
    private var userAgent = TwitchClientFingerprint.randomAndroidUserAgent()

    /// Switches this service's UA to the sticky allocation for `accountId`.
    public func setAccountId(_ accountId: String) {
        userAgent = TwitchClientFingerprint.shared.userAgent(for: accountId)
    }

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

    public init(clientId: String, tokenStore: any TokenStore) {
        self.clientId = clientId
        self.tokenStore = tokenStore
    }

    // MARK: - Device Code Flow

    /// Initiates device code flow and returns the device code info for user to authorize.
    /// Uses empty scopes — Twitch's web client ID works without any OAuth scopes.
    public func initiateDeviceFlow() async throws -> DeviceCodeResponse {
        var request = URLRequest(url: deviceCodeURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
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
            Logger.auth.error("ERROR: status=\(httpResponse.statusCode)")
            Logger.auth.debug("Request body: client_id=\(clientId.prefix(6))... scopes=''")
            Logger.auth.error("Response: \(message)")
            throw TwitchMinerError.apiError(statusCode: httpResponse.statusCode, message: message)
        }

        return try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
    }

    /// Polls for token after user authorizes the device code
    public func pollForToken(deviceCode: String, interval: Int) async throws -> Account {
        let intervalDuration = UInt64(interval) * 1_000_000_000 // Convert to nanoseconds
        Logger.auth.info("Starting token polling, interval: \(interval)s")

        while true {
            try await Task.sleep(nanoseconds: intervalDuration)
            Logger.auth.debug("Polling for token...")

            do {
                let fresh = try await requestToken(deviceCode: deviceCode)
                Logger.auth.info("Token received! User: \(fresh.username)")
                let account = await mergingStoredIdentity(into: fresh)
                try await tokenStore.save(account: account)
                self.currentAccount = account
                return account
            } catch let error as TwitchMinerError {
                if case .apiError(let statusCode, let message) = error {
                    Logger.auth.debug("Poll error: status=\(statusCode), message=\(message)")
                    // authorization_pending means user hasn't authorized yet, continue polling
                    if message.contains("authorization_pending") {
                        Logger.auth.debug("Authorization pending, continuing...")
                        continue
                    }
                    // slow_down means we need to increase interval
                    if message.contains("slow_down") {
                        Logger.auth.warning("Rate limited, slowing down...")
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

        // The raw body contains the access token — never log its contents.
        Logger.auth.debug("Token response received (\(data.count) bytes)")


        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        Logger.auth.info("Token decoded successfully")

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

        return try await forceRefreshToken()
    }

    /// Force-refreshes the OAuth token regardless of local expiry metadata.
    /// Used when Twitch returns 401/tokenExpired even though local token appears valid.
    public func forceRefreshToken() async throws -> String {
        guard let account = currentAccount else {
            throw TwitchMinerError.sessionNotStarted
        }

        // If there's already a refresh in progress, wait for it.
        if let refreshTask = refreshTask {
            return try await refreshTask.value
        }

        let task = Task<String, Error> {
            defer { self.refreshTask = nil }
            return try await performRefresh(account: account)
        }

        refreshTask = task
        return try await task.value
    }

    private func performRefresh(account: Account) async throws -> String {
        guard !account.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // No refresh grant: TDM cookie imports store an empty refresh token, and the web
            // client ID returns expires_in = 0 so the device flow invents a 30-day deadline.
            // Both fabricate `tokenExpiry`, so it must never be treated as proof the token is
            // dead — Twitch is the only authority on that. Trusting the local deadline used to
            // fail every refresh instantly, which took PubSub offline for the whole fleet while
            // the token was still working perfectly for GraphQL.
            return try await revalidateWithoutRefreshGrant(account: account)
        }

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

        guard let httpResponse = response as? HTTPURLResponse else {
            Logger.auth.info("No HTTP response refreshing \(account.username); keeping the existing token")
            return account.accessToken
        }

        switch Self.refreshOutcome(forStatusCode: httpResponse.statusCode) {
        case .proceed:
            break
        case .grantRefused:
            // Twitch refused the grant, which retires the *refresh token* — it says nothing
            // about the access token in hand. A web-client login reports expires_in = 0, so the
            // 30-day expiry above is invented; once it lapses this refresh runs, gets a 400 it
            // was never going to survive, and used to be reported as a dead login while the
            // account carried on mining. Fall back to asking about the access token itself.
            Logger.auth.warning("Refresh grant for \(account.username) refused by Twitch (HTTP \(httpResponse.statusCode)); falling back to revalidating the access token")
            return try await revalidateWithoutRefreshGrant(account: account)
        case .transientFailure:
            Logger.auth.info("Token refresh for \(account.username) failed with HTTP \(httpResponse.statusCode); keeping the existing token")
            return account.accessToken
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)

        let refreshedAccount = Account(
            id: account.id,
            username: account.username,
            nickname: account.nickname,
            ownerDiscordId: account.ownerDiscordId,
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            tokenExpiry: Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn)),
            scopes: tokenResponse.scope
        )

        try await tokenStore.save(account: refreshedAccount)
        self.currentAccount = refreshedAccount
        
        onTokenRefresh?(refreshedAccount.accessToken)

        return refreshedAccount.accessToken
    }

    /// Re-establishes the real lifetime of a token that has no refresh grant.
    ///
    /// Nothing this endpoint says is allowed to retire the token. A transport failure leaves it
    /// in place because a network blip must not take a working account offline, and even an
    /// outright rejection only shortens the local window — see below for why. GraphQL, the API
    /// the miner actually runs on, is what decides a token is finished.
    private func revalidateWithoutRefreshGrant(account: Account) async throws -> String {
        let info: TokenValidationResponse
        do {
            info = try await validateTokenInternal(account.accessToken)
        } catch let error as TwitchMinerError {
            if case .authenticationFailed = error {
                // `/oauth2/validate` speaks for Helix OAuth tokens. A token imported from web
                // cookies is not one, so Twitch rejects it here while GraphQL keeps accepting it
                // happily. Treating that 401 as proof of death sent a "re-authenticate" DM on
                // every single launch for an account that went on to mine perfectly, because the
                // throw also skipped the re-arm below and left the account in this path forever.
                // Keep the token, re-arm a short window, and let a real GraphQL rejection be the
                // thing that asks the user for a new login.
                Logger.auth.warning("Token for \(account.username) was rejected by /validate, which is not authoritative for cookie-imported tokens; keeping it and letting GraphQL decide")
                return await rearmingWindow(
                    for: account,
                    lifetime: Self.unverifiedTokenRecheckInterval
                )
            }
            Logger.auth.info("Could not reach Twitch to revalidate \(account.username); keeping the existing token")
            return account.accessToken
        } catch {
            Logger.auth.info("Could not reach Twitch to revalidate \(account.username); keeping the existing token")
            return account.accessToken
        }

        // expires_in = 0 means Twitch advertises no expiry for this token. Re-arm the local
        // window so the account does not fall back into this path on every single request.
        let remaining = info.expiresIn > 0 ? TimeInterval(info.expiresIn) : Self.assumedTokenLifetime
        let renewed = await rearmingWindow(
            for: account,
            lifetime: remaining,
            scopes: info.scopes.isEmpty ? account.scopes : info.scopes
        )
        Logger.auth.info("Revalidated \(account.username) with Twitch; token is still live")
        return renewed
    }

    /// Pushes the local expiry out so the account stops re-entering the refresh path on every
    /// request, without touching the token itself.
    private func rearmingWindow(
        for account: Account,
        lifetime: TimeInterval,
        scopes: [String]? = nil
    ) async -> String {
        let renewed = Account(
            id: account.id,
            username: account.username,
            nickname: account.nickname,
            ownerDiscordId: account.ownerDiscordId,
            accessToken: account.accessToken,
            refreshToken: account.refreshToken,
            tokenExpiry: Date().addingTimeInterval(lifetime),
            scopes: scopes ?? account.scopes
        )

        try? await tokenStore.save(account: renewed)
        self.currentAccount = renewed
        return renewed.accessToken
    }

    /// What a refresh-grant response status means for the account.
    ///
    /// Note that no case retires the account. Refusing a refresh grant retires the refresh
    /// token, not the access token, and those come apart routinely for web-client logins whose
    /// expiry SwiftMiner had to invent. Only the API the miner actually runs on can say a login
    /// is finished.
    enum RefreshOutcome: Equatable {
        /// Twitch returned new credentials; decode and store them.
        case proceed
        /// Twitch refused the grant. Revalidate the access token before believing anything.
        case grantRefused
        /// A rate limit or Twitch-side fault, which says nothing about either token.
        case transientFailure
    }

    static func refreshOutcome(forStatusCode statusCode: Int) -> RefreshOutcome {
        switch statusCode {
        case 200: return .proceed
        case 400, 401: return .grantRefused
        default: return .transientFailure
        }
    }

    /// Fallback window applied when Twitch reports no expiry for a token.
    static let assumedTokenLifetime: TimeInterval = 30 * 24 * 3600

    /// Window applied to a token Twitch would not confirm. Long enough that relaunching does not
    /// re-probe every time, short enough that it never claims health nothing has verified.
    static let unverifiedTokenRecheckInterval: TimeInterval = 6 * 3600

    /// Validates an OAuth token and returns user info.
    public func validateToken(_ token: String) async throws -> (userId: String, login: String) {
        let response = try await validateTokenInternal(token)
        return (userId: response.userId, login: response.login)
    }

    /// Import a session from TDM cookies (auth-token).
    /// Validates the token and saves it to secure storage.
    public func importTDMSession(token: String) async throws -> Account {
        Logger.auth.info("Importing TDM session token (len=\(token.count))")

        // 1. Validate the token to get user info
        let userInfo = try await validateTokenInternal(token)
        Logger.auth.info("Token validated for \(userInfo.login)")

        // 2. Create account (TDM sessions don't have refresh tokens, so we default to 30d expiry)
        let account = await mergingStoredIdentity(into: Account(
            id: userInfo.userId,
            username: userInfo.login,
            accessToken: token,
            refreshToken: "", // TDM cookies usually don't have this
            tokenExpiry: Date().addingTimeInterval(30 * 24 * 3600),
            scopes: userInfo.scopes
        ))

        // 3. Save to secure storage
        try await tokenStore.save(account: account)
        self.currentAccount = account
        return account
    }

    /// Carries the fields SwiftMiner owns onto a freshly authenticated account.
    ///
    /// A sign-in only knows what Twitch returned, so saving it as-is overwrites
    /// the stored record's nickname, Discord owner, and operator flag with
    /// nothing. Re-authenticating an existing account then silently unlinks it
    /// from its Discord user — the app stops resolving that user's profile
    /// picture and greys out the Discord picture source, while the SQLite copy
    /// of the link (which the web dashboard reads) still shows it as linked.
    func mergingStoredIdentity(into account: Account) async -> Account {
        guard let existing = try? await tokenStore.loadAccount(twitchUserId: account.id) else {
            return account
        }
        return Account(
            id: account.id,
            username: account.username,
            nickname: existing.nickname,
            ownerDiscordId: existing.ownerDiscordId,
            accessToken: account.accessToken,
            refreshToken: account.refreshToken,
            tokenExpiry: account.tokenExpiry,
            scopes: account.scopes,
            isOperator: existing.isOperator
        )
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
        Logger.auth.debug("Validate response: status=\(httpResponse.statusCode) body=\(responseBody.prefix(200))")
        // Only a 401 means the token itself is dead. Any other non-200 is a Twitch-side problem
        // and must stay distinguishable, so callers can retry instead of dropping the account.
        if httpResponse.statusCode == 401 {
            throw TwitchMinerError.authenticationFailed("Token rejected by Twitch — \(responseBody.prefix(120))")
        }
        guard httpResponse.statusCode == 200 else {
            throw TwitchMinerError.apiError(
                statusCode: httpResponse.statusCode,
                message: "Token validation failed — \(responseBody.prefix(120))"
            )
        }

        return try JSONDecoder().decode(TokenValidationResponse.self, from: data)
    }

    // MARK: - Account Management

    /// Directly set the current account (used when account is already known from a fresh auth flow).
    public func setCurrentAccount(_ account: Account) {
        self.currentAccount = account
    }

    public func loadSavedAccount() async throws -> Account? {
        if let account = (try await tokenStore.loadAllAccounts()).first {
            self.currentAccount = account
            return account
        }
        return nil
    }
    
    /// Loads all accounts saved in the persistent store.
    public func loadAllAccounts() async throws -> [Account] {
        return try await tokenStore.loadAllAccounts()
    }

    /// Revokes the currently stored OAuth access token at Twitch. This is
    /// intentionally separate from local deletion: callers can still remove an
    /// account if the device is offline or Twitch is temporarily unavailable.
    public func revokeAccess(for accountId: String) async throws {
        guard let account = try await tokenStore.loadAccount(twitchUserId: accountId) else { return }
        var components = URLComponents(url: revokeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "token", value: account.accessToken)
        ]
        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw TwitchMinerError.authenticationFailed("Twitch token revocation failed")
        }
    }

    public func logout(accountId: String? = nil) async throws {
        if let id = accountId {
            try await tokenStore.deleteAccount(twitchUserId: id)
            if currentAccount?.id == id {
                currentAccount = nil
            }
        } else if let account = currentAccount {
            try await tokenStore.deleteAccount(twitchUserId: account.id)
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
