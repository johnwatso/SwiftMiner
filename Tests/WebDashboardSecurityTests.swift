import Foundation
import CryptoKit
import JavaScriptCore
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
        try XCTSkipIf(env["SWIFTMINER_WEB_LOCAL_PASSWORD_HASH"] != nil)
        XCTAssertNil(WebDashboardConfig.fromEnvironment(suite))
    }

    func testLocalConfigFromDefaultsNeedsNoBaseURL() {
        let suiteName = "web-test-local-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let hash = WebSecurity.hashLocalPassword("localpass", iterations: 1_000)
        suite.set("operator", forKey: "webDashboardLocalUsername")
        suite.set(hash, forKey: "webDashboardLocalPasswordHash")

        let config = WebDashboardConfig.fromEnvironment(suite)

        XCTAssertEqual(config?.local?.username, "operator")
        XCTAssertEqual(config?.local?.passwordHash, hash)
        XCTAssertTrue(config?.localEnabled == true)
        XCTAssertNil(config?.baseURL)
        XCTAssertFalse(config?.anyProviderEnabled == true)
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

    func testSwiftBotSSOConfigWithoutBaseURLFallsBackToOrigin() {
        let cfg = WebDashboardConfig(
            baseURL: nil,
            discord: nil,
            twitch: nil,
            swiftBotSSO: WebSwiftBotSSO(origin: "https://swiftminer.roon.nz", hmacSecret: "secret")
        )
        XCTAssertEqual(cfg.baseURL, URL(string: "https://swiftminer.roon.nz"))
        XCTAssertTrue(cfg.swiftBotSSOEnabled)
        XCTAssertTrue(cfg.anyEnabled)
        XCTAssertEqual(cfg.redirectURI, "https://swiftminer.roon.nz/oauth/callback")
        XCTAssertTrue(cfg.useSecureCookies)
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

    func testDashboardScriptIsScopedAndAllowedByCSP() {
        XCTAssertTrue(WebDashboardAssets.appJS.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("(() => {"))
        let response = HTTPResponse.html(WebDashboardAssets.appHTML)
        let csp = response.headers["Content-Security-Policy"] ?? ""
        XCTAssertTrue(csp.contains("script-src 'self'"))
    }

    func testDashboardHasAnimatedLoadingState() {
        XCTAssertTrue(WebDashboardAssets.appHTML.contains("Warming up SwiftMiner"))
        XCTAssertTrue(WebDashboardAssets.appHTML.contains("loading-skeleton"))
        XCTAssertTrue(WebDashboardAssets.appHTML.contains("prefers-reduced-motion"))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("startLoadingCopy()"))
    }

    func testDashboardSeparatesSubscriptionRequiredCampaignsFromUpNext() {
        XCTAssertTrue(WebDashboardAssets.appJS.contains("CAMPAIGNS.filter(c => !c.requiresSubscription)"))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("CAMPAIGNS.filter(c => c.requiresSubscription)"))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("Paid Twitch sub required"))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("${subscriptionRequiredCard()}${upNextCard(p)}"))
    }

    func testDashboardUsesPrioritySourcePickerForMultipleMiners() {
        XCTAssertTrue(WebDashboardAssets.appJS.contains("function hasMultipleConfiguredMiners(p)"))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("Number(p && p.configuredMinerCount || 0) > 1"))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("Priority Source"))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("data-priority-source=\"global\""))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("data-priority-source=\"globalAndPersonal\""))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("data-priority-source=\"personal\""))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("personalCard(p)"))
    }

    func testIdleDashboardUsesUpToDateStateInsteadOfAnEmptyProgressBar() {
        XCTAssertTrue(WebDashboardAssets.appJS.contains("class=\"up-to-date-state\""))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("Up to Date"))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("if (p.state === 'idle') return '';"))
        XCTAssertFalse(WebDashboardAssets.appJS.contains("Idle - no campaigns"))
    }

    func testDashboardShowsArtworkPreviewForGlobalPriorities() {
        XCTAssertTrue(WebDashboardAssets.appJS.contains("function globalPriorityGames(p)"))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("function priorityArtworkURL(p, game)"))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("priorityGameArtwork"))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("global-priority-artwork"))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("View Global Priorities"))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("function globalPrioritiesModal(p)"))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("aria-modal=\"true\""))
    }

    func testDashboardElevatesTwitchIdentityAndGroupsCompletedDrops() {
        XCTAssertTrue(WebDashboardAssets.appJS.contains("function minerIdentity(p)"))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("class=\"miner-avatar\""))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("Completed Drops"))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("dropsThisWeek === 1 ? 'drop' : 'drops'"))
        XCTAssertFalse(WebDashboardAssets.appJS.contains("Drops Claimed This Week"))
    }

    func testOperatorOverviewUsesDiscordAvatarWhenTwitchHasNoCustomPicture() {
        XCTAssertTrue(WebDashboardAssets.appJS.contains("operator-miner-avatar"))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("referrerpolicy=\"no-referrer\""))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("[acc.profileImageURL, acc.discordProfileImageURL]"))
        XCTAssertFalse(WebDashboardAssets.appJS.contains("${esc(cfg.headline)}${watchingHTML}"))
    }

    func testLocalLoginPageShowsOnlyUsernamePasswordForm() async throws {
        let mgr = try await openTempManager()
        defer { Task { await mgr.close() } }
        let router = try await configuredWebRouter(manager: mgr)

        let response = await router.handle(HTTPRequest(
            method: "GET",
            path: "/login",
            headers: ["host": "localhost:8080"],
            body: Data()
        ))

        XCTAssertEqual(response.statusCode, 200)
        let html = String(decoding: response.body, as: UTF8.self)
        XCTAssertTrue(html.contains("name=\"username\""))
        XCTAssertTrue(html.contains("name=\"password\""))
        XCTAssertTrue(html.contains("Sign in locally"))
        XCTAssertFalse(html.contains("Sign in with Twitch"))
        XCTAssertFalse(html.contains("Sign in with Discord"))
    }

    func testLANLoginPageShowsLocalUsernamePasswordForm() async throws {
        let mgr = try await openTempManager()
        defer { Task { await mgr.close() } }
        let router = try await configuredWebRouter(manager: mgr)

        let response = await router.handle(HTTPRequest(
            method: "GET",
            path: "/login",
            headers: ["host": "192.168.1.50:8080"],
            body: Data()
        ))

        XCTAssertEqual(response.statusCode, 200)
        let html = String(decoding: response.body, as: UTF8.self)
        XCTAssertTrue(html.contains("name=\"username\""))
        XCTAssertTrue(html.contains("name=\"password\""))
        XCTAssertTrue(html.contains("Sign in locally"))
        XCTAssertTrue(html.contains("Sign in locally with your operator account"))
        XCTAssertFalse(html.contains("Sign in with Twitch"))
        XCTAssertFalse(html.contains("Sign in with Discord"))
    }

    func testLANProviderLoginIsRejected() async throws {
        let mgr = try await openTempManager()
        defer { Task { await mgr.close() } }
        let router = try await configuredWebRouter(manager: mgr)

        let response = await router.handle(HTTPRequest(
            method: "GET",
            path: "/login/twitch",
            headers: ["host": "192.168.1.50:8080"],
            body: Data()
        ))

        XCTAssertEqual(response.statusCode, 403)
        XCTAssertNil(response.headers["Location"])
    }

    func testPublicLoginPageKeepsOAuthAndHidesLocalForm() async throws {
        let mgr = try await openTempManager()
        defer { Task { await mgr.close() } }
        let router = try await configuredWebRouter(manager: mgr)

        let response = await router.handle(HTTPRequest(
            method: "GET",
            path: "/login",
            headers: ["host": "swiftminer.example.com"],
            body: Data()
        ))

        XCTAssertEqual(response.statusCode, 200)
        let html = String(decoding: response.body, as: UTF8.self)
        XCTAssertTrue(html.contains("Sign in with Twitch"))
        XCTAssertTrue(html.contains("Sign in with Discord"))
        XCTAssertFalse(html.contains("name=\"username\""))
        XCTAssertFalse(html.contains("Sign in locally"))
    }

    func testLoginPageUsesDynamicMobileViewport() {
        let html = WebDashboardAssets.loginPage(discordSSOURL: "https://swiftbot.example.com/sso", twitch: true, local: false)

        XCTAssertTrue(html.contains("min-height: 100dvh"))
        XCTAssertTrue(html.contains("env(safe-area-inset-bottom)"))
        XCTAssertTrue(WebDashboardAssets.loginJS.contains("window.visualViewport"))
    }

    func testLocalProviderLoginIsRejected() async throws {
        let mgr = try await openTempManager()
        defer { Task { await mgr.close() } }
        let router = try await configuredWebRouter(manager: mgr)

        let response = await router.handle(HTTPRequest(
            method: "GET",
            path: "/login/twitch",
            headers: ["host": "localhost:8080"],
            body: Data()
        ))

        XCTAssertEqual(response.statusCode, 403)
        XCTAssertNil(response.headers["Location"])
        let html = String(decoding: response.body, as: UTF8.self)
        XCTAssertTrue(html.contains("Use local sign-in from this address."))
    }

    func testLocalLoginIssuesNonSecureCookieForHTTPAccess() async throws {
        let mgr = try await openTempManager()
        defer { Task { await mgr.close() } }
        let router = try await configuredWebRouter(manager: mgr)

        let body = Data("username=admin&password=password".utf8)
        let login = await router.handle(HTTPRequest(
            method: "POST",
            path: "/login/local",
            headers: ["host": "localhost:8080"],
            body: body
        ))

        XCTAssertEqual(login.statusCode, 302)
        XCTAssertEqual(login.headers["Location"], WebDashboardConfig.appPath)
        let setCookie = try XCTUnwrap(login.headers["Set-Cookie"])
        XCTAssertFalse(setCookie.contains("Secure"))

        let app = await router.handle(HTTPRequest(
            method: "GET",
            path: WebDashboardConfig.appPath,
            headers: ["host": "localhost:8080", "cookie": setCookie],
            body: Data()
        ))

        XCTAssertEqual(app.statusCode, 200)
    }

    func testLogoutClearsLocalSessionEvenBeforeCSRFLoads() async throws {
        let mgr = try await openTempManager()
        defer { Task { await mgr.close() } }
        let router = try await configuredWebRouter(manager: mgr)

        let login = await router.handle(HTTPRequest(
            method: "POST",
            path: "/login/local",
            headers: ["host": "localhost:8080"],
            body: Data("username=admin&password=password".utf8)
        ))
        let loginCookie = try XCTUnwrap(login.headers["Set-Cookie"])
        let sessionId = try XCTUnwrap(WebCookie.parse(loginCookie)[WebDashboardConfig.sessionCookieName])

        let logout = await router.handle(HTTPRequest(
            method: "POST",
            path: WebDashboardConfig.logoutPath,
            headers: ["host": "localhost:8080", "cookie": loginCookie],
            body: Data()
        ))

        XCTAssertEqual(logout.statusCode, 302)
        XCTAssertEqual(logout.headers["Location"], WebDashboardConfig.loginPath)
        let clearCookie = try XCTUnwrap(logout.headers["Set-Cookie"])
        XCTAssertTrue(clearCookie.contains("Max-Age=0"))
        XCTAssertFalse(clearCookie.contains("Secure"))
        let session = await mgr.fetchWebSession(id: sessionId, now: Date().timeIntervalSince1970)
        XCTAssertNil(session)
    }

    func testDiscordLogoutAuditUsesLinkedMinerNameNotRawDiscordId() async throws {
        let mgr = try await openTempManager()
        defer { Task { await mgr.close() } }

        let discordId = "123456789012345678"
        try await mgr.execute("""
        INSERT INTO miner_users (discord_id, status) VALUES ('\(discordId)', 'registered');
        INSERT INTO twitch_accounts (
            twitch_id, owner_discord_id, username, access_token, refresh_token, token_expiry, scopes, link_state
        ) VALUES (
            'twitch-1', '\(discordId)', 'Jonwatso', 'access', 'refresh', '2099-01-01T00:00:00Z', '', 'linked'
        );
        """)
        try await mgr.createWebSession(
            id: "discord-session",
            principalType: "discord",
            principalId: discordId,
            csrfToken: "csrf",
            createdAt: Date().timeIntervalSince1970,
            expiresAt: Date().addingTimeInterval(60).timeIntervalSince1970
        )

        let recorder = AuditRecorder()
        let router = try await configuredWebRouter(manager: mgr, audit: { message in
            await recorder.record(message)
        })

        let response = await router.handle(HTTPRequest(
            method: "POST",
            path: WebDashboardConfig.logoutPath,
            headers: ["host": "localhost:8080", "cookie": "\(WebDashboardConfig.sessionCookieName)=discord-session"],
            body: Data()
        ))

        XCTAssertEqual(response.statusCode, 302)
        let messages = await recorder.messages
        XCTAssertEqual(messages, ["Jonwatso signed out of the web dashboard"])
        XCTAssertFalse(messages.joined(separator: "\n").contains(discordId))
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

    func testDiscordOperatorSessionReceivesOperatorOverview() async throws {
        let mgr = try await openTempManager()
        defer { Task { await mgr.close() } }
        let discordId = "123456789012345678"
        try await mgr.execute("""
        INSERT INTO miner_users (discord_id, status) VALUES ('\(discordId)', 'registered');
        INSERT INTO twitch_accounts (
            twitch_id, owner_discord_id, username, access_token, refresh_token, token_expiry, scopes, link_state, is_operator
        ) VALUES (
            'operator-twitch', '\(discordId)', 'Operator', 'access', 'refresh', '2099-01-01T00:00:00Z', '', 'linked', 1
        );
        """)
        try await mgr.createWebSession(
            id: "discord-operator-session",
            principalType: WebProvider.discord.rawValue,
            principalId: discordId,
            csrfToken: "csrf",
            createdAt: Date().timeIntervalSince1970,
            expiresAt: Date().addingTimeInterval(60).timeIntervalSince1970
        )
        let router = try await configuredWebRouter(manager: mgr)

        let response = await router.handle(HTTPRequest(
            method: "GET",
            path: "/me/projection",
            headers: ["host": "swiftminer.example.com", "cookie": "\(WebDashboardConfig.sessionCookieName)=discord-operator-session"],
            body: Data()
        ))

        XCTAssertEqual(response.statusCode, 200)
        let payload = try decodeJSON(response.body)
        XCTAssertNotNil(payload["miners"] as? [[String: Any]])
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

    /// A single bad quote in the embedded dashboard JS once shipped a
    /// SyntaxError that broke the whole web UI ("Loading…" forever). Parse the
    /// emitted scripts with JavaScriptCore — `new Function` compiles without
    /// executing, so only syntax errors throw.
    func testEmittedWebScriptsHaveValidSyntax() throws {
        let scripts: [(name: String, source: String)] = [
            ("app.js", WebDashboardAssets.appJS),
            ("login.js", WebDashboardAssets.loginJS)
        ]
        for script in scripts {
            let context = try XCTUnwrap(JSContext())
            context.setObject(script.source, forKeyedSubscript: "src" as NSString)
            context.evaluateScript("new Function(src)")
            XCTAssertNil(context.exception, "\(script.name) failed to parse: \(context.exception?.toString() ?? "unknown error")")
        }
    }

    private func openTempManager() async throws -> SQLiteManager {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftMiner-WebSecTests-\(UUID().uuidString).sqlite")
        let mgr = SQLiteManager(databaseURL: url)
        try await mgr.open()
        return mgr
    }

    private func configuredWebRouter(
        manager: SQLiteManager,
        audit: (@Sendable (String) async -> Void)? = nil
    ) async throws -> HTTPRouter {
        let apiRoutes = DiscordAPIRoutes(
            manager: manager,
            projectionBuilder: DiscordProjectionBuilder(manager: manager),
            apiKey: "test-api-key"
        )
        let webRoutes = WebDashboardRoutes(
            config: WebDashboardConfig(
                baseURL: URL(string: "https://swiftminer.example.com")!,
                discord: nil,
                twitch: WebProviderCredentials(clientID: "twitch-client", clientSecret: "twitch-secret"),
                local: WebLocalCredentials(
                    username: "admin",
                    passwordHash: WebSecurity.hashLocalPassword("password", iterations: 1_000)
                ),
                swiftBotSSO: WebSwiftBotSSO(origin: "https://swiftbot.example.com", hmacSecret: "shared-pairing-secret")
            ),
            manager: manager,
            apiRoutes: apiRoutes,
            audit: audit
        )
        let router = HTTPRouter()
        await webRoutes.configure(router)
        return router
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

private actor AuditRecorder {
    private(set) var messages: [String] = []

    func record(_ message: String) {
        messages.append(message)
    }
}
