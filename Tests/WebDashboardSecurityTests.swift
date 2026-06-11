import Foundation
import CryptoKit
import XCTest
@testable import SwiftMinerService
import SwiftMinerCore

final class WebDashboardSecurityTests: XCTestCase {

    // MARK: - Crypto / CSRF

    func testConstantTimeEqualsMatchesOnlyIdenticalStrings() {
        XCTAssertTrue(WebSecurity.constantTimeEquals("abc123", "abc123"))
        XCTAssertFalse(WebSecurity.constantTimeEquals("abc123", "abc124"))
        XCTAssertFalse(WebSecurity.constantTimeEquals("abc", "abc123"))   // length differs
        XCTAssertFalse(WebSecurity.constantTimeEquals("", "x"))
        XCTAssertTrue(WebSecurity.constantTimeEquals("", ""))
    }

    func testRandomTokensAreHexAndUnique() {
        let a = WebSecurity.randomToken()
        let b = WebSecurity.randomToken()
        XCTAssertEqual(a.count, 64)                       // 32 bytes hex
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.allSatisfy { $0.isHexDigit })
    }

    // MARK: - Cookies

    func testCookieParseExtractsSessionAmongMany() {
        let cookies = WebCookie.parse("foo=bar; sm_session=abc.def; theme=dark")
        XCTAssertEqual(cookies["sm_session"], "abc.def")
        XCTAssertEqual(cookies["foo"], "bar")
        XCTAssertNil(WebCookie.parse(nil)["sm_session"])
    }

    func testSessionCookieFlagsAreHardened() {
        let secure = WebCookie.sessionCookie(name: "sm_session", value: "v", maxAge: 60, secure: true)
        XCTAssertTrue(secure.contains("HttpOnly"))
        XCTAssertTrue(secure.contains("SameSite=Lax"))
        XCTAssertTrue(secure.contains("Secure"))
        let insecure = WebCookie.sessionCookie(name: "sm_session", value: "v", maxAge: 60, secure: false)
        XCTAssertFalse(insecure.contains("Secure"))       // only omitted for plain-http dev
        XCTAssertTrue(insecure.contains("HttpOnly"))
    }

    // MARK: - Config

    func testConfigDisabledWhenCredentialsAbsent() throws {
        let suite = UserDefaults(suiteName: "web-test-empty-\(UUID().uuidString)")!
        // Skip if the host environment happens to inject real Discord creds.
        let env = ProcessInfo.processInfo.environment
        try XCTSkipIf(env["SWIFTMINER_DISCORD_CLIENT_ID"] != nil)
        XCTAssertNil(WebDashboardConfig.fromEnvironment(suite))
    }

    func testRedirectURIAndSecureCookiePolicy() {
        let https = WebDashboardConfig(
            baseURL: URL(string: "https://swiftminer.example.com/")!,   // trailing slash
            discord: WebProviderCredentials(clientID: "id", clientSecret: "secret"),
            twitch: nil
        )
        XCTAssertEqual(https.redirectURI, "https://swiftminer.example.com/oauth/callback")
        XCTAssertTrue(https.useSecureCookies)
        XCTAssertTrue(https.discordEnabled)
        XCTAssertFalse(https.twitchEnabled)

        let http = WebDashboardConfig(
            baseURL: URL(string: "http://127.0.0.1:8080")!,
            discord: nil,
            twitch: WebProviderCredentials(clientID: "tid", clientSecret: "tsecret")
        )
        XCTAssertEqual(http.redirectURI, "http://127.0.0.1:8080/oauth/callback")
        XCTAssertFalse(http.useSecureCookies)
        XCTAssertTrue(http.twitchEnabled)
        XCTAssertTrue(http.anyProviderEnabled)
    }

    func testLocalPasswordHashRoundTrips() {
        let hash = WebSecurity.hashLocalPassword("hunter2", iterations: 2_000)
        let parts = hash.split(separator: ":")
        XCTAssertEqual(parts.count, 3)               // iterations:salt:hash
        XCTAssertTrue(WebSecurity.verifyLocalPassword("hunter2", encoded: hash))
        XCTAssertFalse(WebSecurity.verifyLocalPassword("Hunter2", encoded: hash))   // wrong case
        XCTAssertFalse(WebSecurity.verifyLocalPassword("", encoded: hash))
        XCTAssertFalse(WebSecurity.verifyLocalPassword("hunter2", encoded: "garbage"))
    }

    func testPasswordHashesAreSaltedAndUnique() {
        let a = WebSecurity.hashLocalPassword("same", iterations: 1_000)
        let b = WebSecurity.hashLocalPassword("same", iterations: 1_000)
        XCTAssertNotEqual(a, b)   // random salt ⇒ different encodings for same password
        XCTAssertTrue(WebSecurity.verifyLocalPassword("same", encoded: a))
        XCTAssertTrue(WebSecurity.verifyLocalPassword("same", encoded: b))
    }

    func testLocalOnlyConfigNeedsNoBaseURLAndDisablesOAuth() {
        let cfg = WebDashboardConfig(
            baseURL: nil,
            discord: WebProviderCredentials(clientID: "id", clientSecret: "s"),  // present but...
            twitch: nil,
            local: WebLocalCredentials(username: "admin", passwordHash: WebSecurity.hashLocalPassword("pw", iterations: 1_000))
        )
        XCTAssertFalse(cfg.discordEnabled)   // no baseURL ⇒ OAuth cannot be used
        XCTAssertFalse(cfg.anyProviderEnabled)
        XCTAssertTrue(cfg.localEnabled)
        XCTAssertTrue(cfg.anyEnabled)
        XCTAssertNil(cfg.redirectURI)
        XCTAssertFalse(cfg.useSecureCookies)
    }

    func testRootIsNeverAPublicPrefix() {
        // hasPrefix("/") matches everything — the root must only ever be an
        // *exact* public path, never a prefix, or the Bot-key API would leak.
        XCTAssertFalse(WebDashboardConfig.publicPrefixes.contains("/"))
        XCTAssertTrue(WebDashboardConfig.publicExactPaths.contains("/"))
    }

    func testPublicPathsAreSegmentScoped() {
        let prefixes = WebDashboardConfig.publicPrefixes
        let exact = WebDashboardConfig.publicExactPaths

        XCTAssertTrue(HTTPAPIServer.isPublicPath("/", prefixes: prefixes, exactPaths: exact))
        XCTAssertTrue(HTTPAPIServer.isPublicPath("/me/session", prefixes: prefixes, exactPaths: exact))
        XCTAssertTrue(HTTPAPIServer.isPublicPath("/app/app.js", prefixes: prefixes, exactPaths: exact))
        XCTAssertTrue(HTTPAPIServer.isPublicPath("/health", prefixes: prefixes, exactPaths: exact))

        XCTAssertFalse(HTTPAPIServer.isPublicPath("/meevil", prefixes: prefixes, exactPaths: exact))
        XCTAssertFalse(HTTPAPIServer.isPublicPath("/application", prefixes: prefixes, exactPaths: exact))
        XCTAssertFalse(HTTPAPIServer.isPublicPath("/healthz", prefixes: prefixes, exactPaths: exact))
        XCTAssertFalse(HTTPAPIServer.isPublicPath("/api/users", prefixes: prefixes, exactPaths: exact))
    }

    // MARK: - Session & OAuth-state persistence

    func testWebSessionLifecycleAndExpiry() async throws {
        let mgr = try await openTempManager()
        defer { Task { await mgr.close() } }

        let now: Double = 1_000_000
        try await mgr.createWebSession(id: "sess1", principalType: "discord", principalId: "123456789012345678",
                                       csrfToken: "csrf", createdAt: now, expiresAt: now + 100)

        let fetched = await mgr.fetchWebSession(id: "sess1", now: now + 50)
        XCTAssertEqual(fetched?.principalType, "discord")
        XCTAssertEqual(fetched?.principalId, "123456789012345678")
        XCTAssertEqual(fetched?.csrfToken, "csrf")

        // Past expiry → not returned.
        let afterExpiry = await mgr.fetchWebSession(id: "sess1", now: now + 200)
        XCTAssertNil(afterExpiry)

        await mgr.deleteWebSession(id: "sess1")
        let afterDelete = await mgr.fetchWebSession(id: "sess1", now: now + 10)
        XCTAssertNil(afterDelete)
    }

    func testPurgeRemovesOnlyExpiredSessions() async throws {
        let mgr = try await openTempManager()
        defer { Task { await mgr.close() } }
        let now: Double = 2_000_000
        try await mgr.createWebSession(id: "live", principalType: "twitch", principalId: "1", csrfToken: "c", createdAt: now, expiresAt: now + 1000)
        try await mgr.createWebSession(id: "dead", principalType: "discord", principalId: "2", csrfToken: "c", createdAt: now, expiresAt: now - 1)
        await mgr.purgeExpiredWebSessions(now: now)
        let live = await mgr.fetchWebSession(id: "live", now: now)
        let dead = await mgr.fetchWebSession(id: "dead", now: now)
        XCTAssertNotNil(live)
        XCTAssertNil(dead)
    }

    func testOAuthStateIsSingleUse() async throws {
        let mgr = try await openTempManager()
        defer { Task { await mgr.close() } }
        let now: Double = 3_000_000
        try await mgr.createOAuthState("state-A", provider: "twitch", createdAt: now, expiresAt: now + 600)
        let firstUse = await mgr.consumeOAuthState("state-A", now: now + 10)
        let replay = await mgr.consumeOAuthState("state-A", now: now + 20)
        let unknown = await mgr.consumeOAuthState("never-existed", now: now)
        XCTAssertEqual(firstUse, "twitch")  // first use returns the minting provider
        XCTAssertNil(replay)                // replay rejected
        XCTAssertNil(unknown)               // unknown rejected
    }

    func testExpiredOAuthStateRejectedAndConsumed() async throws {
        let mgr = try await openTempManager()
        defer { Task { await mgr.close() } }
        let now: Double = 4_000_000
        try await mgr.createOAuthState("stale", provider: "discord", createdAt: now - 1000, expiresAt: now - 1)
        let expired = await mgr.consumeOAuthState("stale", now: now)           // expired → nil
        let afterDelete = await mgr.consumeOAuthState("stale", now: now)       // and deleted
        XCTAssertNil(expired)
        XCTAssertNil(afterDelete)
    }

    func testOwnerDiscordIdNilForUnknownAccount() async throws {
        let mgr = try await openTempManager()
        defer { Task { await mgr.close() } }
        let owner = await mgr.ownerDiscordId(forTwitchAccount: "no-such-account")
        XCTAssertNil(owner)
    }

    func testSwiftBotSSORegistersNewDiscordUserWithoutMiner() async throws {
        let mgr = try await openTempManager()
        defer { Task { await mgr.close() } }
        let apiRoutes = DiscordAPIRoutes(
            manager: mgr,
            projectionBuilder: DiscordProjectionBuilder(manager: mgr),
            apiKey: "test-api-key"
        )
        let secret = "shared-pairing-secret"
        let webRoutes = WebDashboardRoutes(
            config: WebDashboardConfig(
                baseURL: URL(string: "https://swiftminer.example.com")!,
                discord: nil,
                twitch: nil,
                swiftBotSSO: WebSwiftBotSSO(origin: "https://swiftbot.example.com", hmacSecret: secret)
            ),
            manager: mgr,
            apiRoutes: apiRoutes
        )
        let router = HTTPRouter()
        await webRoutes.configure(router)

        let discordId = "123456789012345678"
        let payload = try swiftBotPayload(
            discordId: discordId,
            username: "New Discord User",
            nonce: UUID().uuidString,
            exp: Int(Date().timeIntervalSince1970) + 600,
            isGuildMember: true
        )
        let signature = swiftBotSignature(payload: payload, secret: secret)

        let response = await router.handle(HTTPRequest(
            method: "GET",
            path: "/oauth/swiftbot/callback",
            headers: [:],
            body: Data(),
            queryParams: ["sso": payload, "sig": signature]
        ))

        XCTAssertEqual(response.statusCode, 302)
        XCTAssertEqual(response.headers["Location"], WebDashboardConfig.appPath)
        let userExists = await apiRoutes.webUserExists(discordId: discordId)
        XCTAssertTrue(userExists)

        let setCookie = try XCTUnwrap(response.headers["Set-Cookie"])
        let sessionId = try XCTUnwrap(WebCookie.parse(setCookie)[WebDashboardConfig.sessionCookieName])
        let session = await mgr.fetchWebSession(id: sessionId, now: Date().timeIntervalSince1970)
        XCTAssertEqual(session?.principalType, WebProvider.discord.rawValue)
        XCTAssertEqual(session?.principalId, discordId)

        let projection = await apiRoutes.webProjection(discordId: discordId)
        XCTAssertEqual(projection.statusCode, 200)
        let payloadJSON = try decodeJSON(projection.body)
        XCTAssertEqual(payloadJSON["state"] as? String, "notConfigured")
        XCTAssertNil(payloadJSON["account"] as? [String: Any])
    }

    func testSwiftBotSSORejectsDiscordUserOutsideAttachedServer() async throws {
        let mgr = try await openTempManager()
        defer { Task { await mgr.close() } }
        let apiRoutes = DiscordAPIRoutes(
            manager: mgr,
            projectionBuilder: DiscordProjectionBuilder(manager: mgr),
            apiKey: "test-api-key"
        )
        let secret = "shared-pairing-secret"
        let webRoutes = WebDashboardRoutes(
            config: WebDashboardConfig(
                baseURL: URL(string: "https://swiftminer.example.com")!,
                discord: nil,
                twitch: nil,
                swiftBotSSO: WebSwiftBotSSO(origin: "https://swiftbot.example.com", hmacSecret: secret)
            ),
            manager: mgr,
            apiRoutes: apiRoutes
        )
        let router = HTTPRouter()
        await webRoutes.configure(router)

        let discordId = "123456789012345678"
        let payload = try swiftBotPayload(
            discordId: discordId,
            username: "Outside User",
            nonce: UUID().uuidString,
            exp: Int(Date().timeIntervalSince1970) + 600,
            isGuildMember: false
        )
        let signature = swiftBotSignature(payload: payload, secret: secret)

        let response = await router.handle(HTTPRequest(
            method: "GET",
            path: "/oauth/swiftbot/callback",
            headers: [:],
            body: Data(),
            queryParams: ["sso": payload, "sig": signature]
        ))

        XCTAssertEqual(response.statusCode, 403)
        XCTAssertNil(response.headers["Set-Cookie"])
        XCTAssertNil(response.headers["Location"])
        let html = String(decoding: response.body, as: UTF8.self)
        XCTAssertTrue(html.contains("Not in this server"))
        XCTAssertTrue(html.contains("not part of the server attached to this SwiftMiner"))
        let userExists = await apiRoutes.webUserExists(discordId: discordId)
        XCTAssertFalse(userExists)
    }

    func testUnknownTwitchAccountCannotUseWebDashboard() async throws {
        let mgr = try await openTempManager()
        defer { Task { await mgr.close() } }
        let apiRoutes = DiscordAPIRoutes(
            manager: mgr,
            projectionBuilder: DiscordProjectionBuilder(manager: mgr),
            apiKey: "test-api-key"
        )

        let response = await apiRoutes.webProjectionTwitch(twitchId: "unknown-twitch-account")
        XCTAssertEqual(response.statusCode, 404)
        let body = try decodeJSON(response.body)
        XCTAssertEqual(body["error"] as? String, "miner_not_found")
    }

    func testDirectDiscordOAuthIsRejectedBecauseServerMembershipIsUnverified() async throws {
        let mgr = try await openTempManager()
        defer { Task { await mgr.close() } }
        let apiRoutes = DiscordAPIRoutes(
            manager: mgr,
            projectionBuilder: DiscordProjectionBuilder(manager: mgr),
            apiKey: "test-api-key"
        )
        let webRoutes = WebDashboardRoutes(
            config: WebDashboardConfig(
                baseURL: URL(string: "https://swiftminer.example.com")!,
                discord: WebProviderCredentials(clientID: "discord-client", clientSecret: "discord-secret"),
                twitch: nil,
                swiftBotSSO: WebSwiftBotSSO(origin: "https://swiftbot.example.com", hmacSecret: "shared-pairing-secret")
            ),
            manager: mgr,
            apiRoutes: apiRoutes
        )
        let router = HTTPRouter()
        await webRoutes.configure(router)

        let response = await router.handle(HTTPRequest(
            method: "GET",
            path: "/login/discord",
            headers: [:],
            body: Data()
        ))

        XCTAssertEqual(response.statusCode, 403)
        XCTAssertNil(response.headers["Location"])
        let userExists = await apiRoutes.webUserExists(discordId: "123456789012345678")
        XCTAssertFalse(userExists)
    }

    // MARK: - Helpers

    private func openTempManager() async throws -> SQLiteManager {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftMiner-WebSecTests-\(UUID().uuidString).sqlite")
        let mgr = SQLiteManager(databaseURL: url)
        try await mgr.open()
        return mgr
    }

    private func swiftBotPayload(discordId: String, username: String, nonce: String, exp: Int, isGuildMember: Bool) throws -> String {
        let object: [String: Any] = [
            "discordUserId": discordId,
            "username": username,
            "nonce": nonce,
            "exp": exp,
            "isGuildMember": isGuildMember
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return base64URL(data)
    }

    private func swiftBotSignature(payload: String, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        return HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: key)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func decodeJSON(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
