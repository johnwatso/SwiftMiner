import Foundation
import CryptoKit
import JavaScriptCore
import XCTest
@testable import SwiftMiner
@testable import SwiftMinerService
import SwiftMinerCore

final class WebDashboardSecurityTests: XCTestCase {

    // MARK: - HTTP request framing

    func testHTTPRequestFramerBuildsARequestAcrossChunks() throws {
        var framer = HTTPRequestFramer(maximumHeaderBytes: 256, maximumBodyBytes: 32)

        XCTAssertNil(try framer.append(Data("POST /api/test HTTP/1.1\r\nContent-Length: 5\r\n".utf8)))
        let frame = try XCTUnwrap(framer.append(Data("X-Test: yes\r\n\r\nhello".utf8)))

        XCTAssertEqual(frame.requestLine, "POST /api/test HTTP/1.1")
        XCTAssertEqual(frame.headers["x-test"], "yes")
        XCTAssertEqual(frame.body, Data("hello".utf8))
    }

    func testHTTPRequestFramerRejectsNegativeContentLength() {
        var framer = HTTPRequestFramer()
        XCTAssertThrowsError(
            try framer.append(Data("POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8))
        ) { error in
            XCTAssertEqual(error as? HTTPRequestFramingError, .invalidContentLength)
        }
    }

    func testHTTPRequestFramerRejectsNonNumericContentLength() {
        var framer = HTTPRequestFramer()
        XCTAssertThrowsError(
            try framer.append(Data("POST / HTTP/1.1\r\nContent-Length: nope\r\n\r\n".utf8))
        ) { error in
            XCTAssertEqual(error as? HTTPRequestFramingError, .invalidContentLength)
        }
    }

    func testHTTPRequestFramerRejectsDuplicateContentLength() {
        var framer = HTTPRequestFramer()
        XCTAssertThrowsError(
            try framer.append(Data("POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n".utf8))
        ) { error in
            XCTAssertEqual(error as? HTTPRequestFramingError, .invalidContentLength)
        }
    }

    func testHTTPRequestFramerRejectsTransferEncoding() {
        var framer = HTTPRequestFramer()
        XCTAssertThrowsError(
            try framer.append(Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
        ) { error in
            XCTAssertEqual(error as? HTTPRequestFramingError, .malformedHeaders)
        }
    }

    func testHTTPRequestFramerRejectsOversizedHeaders() {
        var framer = HTTPRequestFramer(maximumHeaderBytes: 24, maximumBodyBytes: 32)
        XCTAssertThrowsError(
            try framer.append(Data("GET / HTTP/1.1\r\nX-Long: abcdefghijklmnop".utf8))
        ) { error in
            XCTAssertEqual(error as? HTTPRequestFramingError, .headersTooLarge)
        }
    }

    func testHTTPRequestFramerRejectsOversizedBodyBeforeBufferingIt() {
        var framer = HTTPRequestFramer(maximumHeaderBytes: 256, maximumBodyBytes: 4)
        XCTAssertThrowsError(
            try framer.append(Data("POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\n".utf8))
        ) { error in
            XCTAssertEqual(error as? HTTPRequestFramingError, .bodyTooLarge)
        }
    }

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

    /// A public plain-HTTP origin must never enable OAuth: the callback carries the
    /// authorization `code` and the reply sets a week-long session cookie that cannot be
    /// marked `Secure` on an http origin. Loopback and LAN hosts keep working.
    func testPublicHTTPOriginCannotEnableSignIn() {
        let publicHTTP = WebDashboardConfig(
            baseURL: URL(string: "http://swiftminer.example.com")!,
            discord: WebProviderCredentials(clientID: "id", clientSecret: "secret"),
            twitch: WebProviderCredentials(clientID: "tid", clientSecret: "tsecret"),
            swiftBotSSO: WebSwiftBotSSO(origin: "http://swiftminer.example.com", hmacSecret: "secret")
        )
        XCTAssertFalse(publicHTTP.baseURLSupportsSignIn)
        XCTAssertFalse(publicHTTP.discordEnabled)
        XCTAssertFalse(publicHTTP.twitchEnabled)
        XCTAssertFalse(publicHTTP.swiftBotSSOEnabled)
        XCTAssertFalse(publicHTTP.anyProviderEnabled)
        XCTAssertFalse(publicHTTP.useSecureCookies)

        for local in ["http://localhost:8080", "http://127.0.0.1:8080", "http://192.168.1.20:8080",
                      "http://10.0.0.5", "http://172.16.4.4", "http://swiftminer.local", "http://mac-mini"] {
            let cfg = WebDashboardConfig(
                baseURL: URL(string: local)!,
                discord: nil,
                twitch: WebProviderCredentials(clientID: "tid", clientSecret: "tsecret")
            )
            XCTAssertTrue(cfg.twitchEnabled, "\(local) is a local origin and should keep working over http")
        }

        for publicHost in ["swiftminer.example.com", "203.0.113.10", "172.32.0.1", "8.8.8.8"] {
            XCTAssertFalse(
                WebDashboardConfig.isLocalHostname(publicHost),
                "\(publicHost) must not be treated as local"
            )
        }
    }

    /// The same rule at the configuration boundary: a public http base URL is dropped
    /// entirely rather than silently enabling an insecure dashboard.
    func testFromEnvironmentDropsPublicHTTPBaseURL() throws {
        let suiteName = "com.swiftminer.tests.web.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        defer { suite.removePersistentDomain(forName: suiteName) }

        suite.set("http://swiftminer.example.com", forKey: "webDashboardBaseURL")
        suite.set("tid", forKey: "webDashboardTwitchClientID")
        suite.set("tsecret", forKey: "webDashboardTwitchClientSecret")
        // Local sign-in keeps the dashboard itself alive, so a nil config can't mask the result.
        suite.set("operator", forKey: "webDashboardLocalUsername")
        suite.set(WebSecurity.hashLocalPassword("pw", iterations: 1_000), forKey: "webDashboardLocalPasswordHash")

        let publicHTTP = try XCTUnwrap(WebDashboardConfig.fromEnvironment(suite))
        XCTAssertNil(publicHTTP.baseURL, "A public http:// origin must be dropped, not accepted")
        XCTAssertFalse(publicHTTP.twitchEnabled)
        XCTAssertTrue(publicHTTP.localEnabled, "Local sign-in is unaffected")

        suite.set("http://127.0.0.1:8080", forKey: "webDashboardBaseURL")
        let loopback = try XCTUnwrap(WebDashboardConfig.fromEnvironment(suite))
        XCTAssertEqual(loopback.baseURL, URL(string: "http://127.0.0.1:8080"))
        XCTAssertTrue(loopback.twitchEnabled)
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

    func testLiveSwiftBotProviderCanDisableCachedDiscordSignIn() async throws {
        let mgr = try await openTempManager()
        let apiRoutes = DiscordAPIRoutes(
            manager: mgr,
            projectionBuilder: DiscordProjectionBuilder(manager: mgr),
            apiKey: "test-api-key"
        )
        let webRoutes = WebDashboardRoutes(
            config: WebDashboardConfig(
                baseURL: URL(string: "https://swiftminer.example.com")!,
                discord: nil,
                twitch: nil,
                swiftBotSSO: WebSwiftBotSSO(origin: "https://swiftbot.example.com", hmacSecret: "secret")
            ),
            manager: mgr,
            apiRoutes: apiRoutes,
            swiftBotSSOProvider: { nil }
        )
        let router = HTTPRouter()
        await webRoutes.configure(router)

        let response = await router.handle(HTTPRequest(
            method: "GET",
            path: WebDashboardConfig.loginPath,
            headers: ["host": "swiftminer.example.com"],
            body: Data()
        ))
        let html = String(decoding: response.body, as: UTF8.self)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertFalse(html.contains("Sign in with Discord"))
    }

    func testLiveTwitchProviderCanDisableCachedTwitchSignIn() async throws {
        let mgr = try await openTempManager()
        let apiRoutes = DiscordAPIRoutes(
            manager: mgr,
            projectionBuilder: DiscordProjectionBuilder(manager: mgr),
            apiKey: "test-api-key"
        )
        // Credentials captured at start-up, but the operator has since turned
        // "Allow Twitch OAuth sign-in" off — the live provider wins.
        let webRoutes = WebDashboardRoutes(
            config: WebDashboardConfig(
                baseURL: URL(string: "https://swiftminer.example.com")!,
                discord: nil,
                twitch: WebProviderCredentials(clientID: "client", clientSecret: "secret")
            ),
            manager: mgr,
            apiRoutes: apiRoutes,
            twitchCredentialsProvider: { nil }
        )
        let router = HTTPRouter()
        await webRoutes.configure(router)

        let publicHeaders = ["host": "swiftminer.example.com"]
        let login = await router.handle(HTTPRequest(
            method: "GET",
            path: WebDashboardConfig.loginPath,
            headers: publicHeaders,
            body: Data()
        ))
        let html = String(decoding: login.body, as: UTF8.self)
        XCTAssertEqual(login.statusCode, 200)
        XCTAssertFalse(html.contains("Sign in with Twitch"))

        // A bookmarked/hand-typed start URL must be refused too.
        let start = await router.handle(HTTPRequest(
            method: "GET",
            path: "/login/twitch",
            headers: publicHeaders,
            body: Data()
        ))
        XCTAssertEqual(start.statusCode, 404)
    }

    func testTwitchSignInStillOfferedWithoutALiveProvider() async throws {
        let mgr = try await openTempManager()
        let apiRoutes = DiscordAPIRoutes(
            manager: mgr,
            projectionBuilder: DiscordProjectionBuilder(manager: mgr),
            apiKey: "test-api-key"
        )
        let webRoutes = WebDashboardRoutes(
            config: WebDashboardConfig(
                baseURL: URL(string: "https://swiftminer.example.com")!,
                discord: nil,
                twitch: WebProviderCredentials(clientID: "client", clientSecret: "secret")
            ),
            manager: mgr,
            apiRoutes: apiRoutes
        )
        let router = HTTPRouter()
        await webRoutes.configure(router)

        let login = await router.handle(HTTPRequest(
            method: "GET",
            path: WebDashboardConfig.loginPath,
            headers: ["host": "swiftminer.example.com"],
            body: Data()
        ))
        let html = String(decoding: login.body, as: UTF8.self)
        XCTAssertEqual(login.statusCode, 200)
        XCTAssertTrue(html.contains("Sign in with Twitch"))
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
        // Sub-gated campaigns are their own exception card and never leak into
        // the Up Next decision; the render order is asserted alongside the other
        // exceptions in testActionableExceptionsSitBetweenConfigurationAndHistory.
        XCTAssertTrue(WebDashboardAssets.appJS.contains("${minerStateCard(p)}${activationCard(p)}${prioritiesCard(p)}"))
    }

    func testDashboardUsesPrioritySourcePickerForMultipleMiners() {
        XCTAssertTrue(WebDashboardAssets.appJS.contains("function hasMultipleConfiguredMiners(p)"))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("Number(p && p.configuredMinerCount || 0) > 1"))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("Priority Source"))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("data-priority-source=\"${value}\""))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("option('global', 'Global'"))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("option('globalAndPersonal', 'Hybrid'"))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("option('personal', 'Personal'"))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("personalCard(p)"))
    }

    /// Priorities states the current configuration and keeps the three-way
    /// control behind "Change" — a rarely-touched setting should not sit on the
    /// page competing with miner status.
    func testPrioritySourceIsSummaryFirstWithProgressiveDisclosure() {
        let js = WebDashboardAssets.appJS
        XCTAssertTrue(js.contains("function prioritySourceSummary(source)"))
        XCTAssertTrue(js.contains("Global Priorities"))
        XCTAssertTrue(js.contains("Personal Priorities"))
        XCTAssertTrue(js.contains("Hybrid Priorities"))
        XCTAssertTrue(js.contains("Managed by your operator"))
        XCTAssertTrue(js.contains("Managed by you"))
        XCTAssertTrue(js.contains("id=\"changeprioritysource\""))
        // The control only exists once the reader asks for it.
        XCTAssertTrue(js.contains("const controls = prioritySourcePickerOpen ?"))
        // Change and View priorities stay distinct actions.
        XCTAssertTrue(js.contains("View priorities →"))
        // Wired on full render only, or the in-place personal refresh would
        // stack a second listener on each save.
        XCTAssertTrue(js.contains("function wirePrioritySource()"))
        XCTAssertFalse(js.contains("mode-badge"))
    }

    /// "Hybrid" is the canonical user-facing name for the personal-then-global
    /// mode, on both surfaces. The transport value stays `globalAndPersonal`,
    /// so miners configured before the rename keep working untouched.
    @MainActor
    func testHybridIsTheCanonicalNameOnBothSurfaces() {
        let js = WebDashboardAssets.appJS

        XCTAssertEqual(Settings.AccountPrioritySource.globalAndPersonal.displayName, "Hybrid")
        XCTAssertEqual(Settings.AccountPrioritySource.globalAndPersonal.displayTitle, "Hybrid Priorities")
        XCTAssertEqual(Settings.AccountPrioritySource.global.displayName, "Global")
        XCTAssertEqual(Settings.AccountPrioritySource.personal.displayName, "Personal")
        // The persisted / API representation is untouched.
        XCTAssertEqual(Settings.AccountPrioritySource.globalAndPersonal.rawValue, "globalAndPersonal")
        XCTAssertEqual(
            Settings.AccountPrioritySource(rawValue: "globalAndPersonal"),
            .globalAndPersonal,
            "an existing miner's stored mode must still decode"
        )

        // Neither surface may still say "Global + Personal" to a reader.
        XCTAssertFalse(js.contains("Global + Personal"))
        // The value sent to the API is still the old identifier.
        XCTAssertTrue(js.contains("option('globalAndPersonal', 'Hybrid'"))
        XCTAssertTrue(js.contains("prioritySource = 'globalAndPersonal'"))

        // Hybrid is an order, not a blend: the copy has to say which wins.
        XCTAssertTrue(js.contains("Your priorities first, then Global."))
        XCTAssertTrue(js.contains("Your priorities run first"))
        XCTAssertEqual(
            Settings.AccountPrioritySource.globalAndPersonal.summary,
            "Your priorities first, then Global."
        )
    }

    /// Row actions rest behind a menu, with the ends of the list disabled.
    func testPersonalRowActionsLiveInAMenu() {
        let js = WebDashboardAssets.appJS
        XCTAssertTrue(js.contains("function rowMenu(i, count)"))
        XCTAssertTrue(js.contains("Move Up"))
        XCTAssertTrue(js.contains("Move Down"))
        XCTAssertTrue(js.contains("Remove from Priorities"))
        XCTAssertTrue(js.contains("${first || single ? 'disabled' : ''}"))
        XCTAssertTrue(js.contains("${last || single ? 'disabled' : ''}"))
        XCTAssertTrue(js.contains("row-menu-item danger"))
        // Nothing but the menu button rests on a row.
        XCTAssertFalse(js.contains("priority-row-drag"))
        XCTAssertFalse(js.contains("priority-row-remove"))
    }

    /// Personal priorities are an ordered queue: numbered rows that can be
    /// reordered, not a bag of tags. Reordering is real — the list is persisted
    /// as an ordered array — so the handle is not decorative.
    func testPersonalPrioritiesRenderAsAnOrderedQueue() {
        let js = WebDashboardAssets.appJS
        XCTAssertTrue(js.contains("class=\"priority-rows\""))
        XCTAssertTrue(js.contains("class=\"priority-rank\">${i + 1}<"))
        XCTAssertTrue(js.contains("function movePersonal(from, to)"))
        XCTAssertTrue(js.contains("priority-row-menu-btn"))
        // No pills, chips or tags.
        XCTAssertFalse(js.contains("priority-chip"))
        XCTAssertFalse(js.contains("priorities-flow"))
        // Dragging a row still reorders it; the menu is the discoverable path.
        XCTAssertTrue(js.contains("const reorderable = count > 1;"))
    }

    /// Adding a game is one quiet line until it is used; no permanently visible
    /// search field and no primary-coloured Add button.
    func testAddingAPersonalPriorityIsProgressivelyDisclosed() {
        let js = WebDashboardAssets.appJS
        XCTAssertTrue(js.contains("id=\"openaddgame\""))
        XCTAssertTrue(js.contains("const adder = personalAddOpen"))
        XCTAssertTrue(js.contains("Search for a game…"))
        XCTAssertTrue(js.contains("No personal priorities added."))
        XCTAssertFalse(js.contains("id=\"addbtn\""))
        // The picker appends; "Prioritise" elsewhere still means top of queue.
        XCTAssertTrue(js.contains("if (placement === 'append') personal.push(name); else personal.unshift(name);"))
    }

    /// Exclusions are summarised, never ranked — they have no order.
    func testExclusionsAreSummarisedNotRanked() {
        let js = WebDashboardAssets.appJS
        XCTAssertTrue(js.contains("games.length} ${games.length === 1 ? 'game' : 'games'} excluded"))
        XCTAssertTrue(js.contains("No games excluded for this miner."))
        XCTAssertTrue(js.contains("id=\"manageexclusions\""))
    }

    /// The preview is a fixed-size strip over the effective list, not the list.
    func testPriorityPreviewSummarisesTheEffectiveList() {
        let js = WebDashboardAssets.appJS
        XCTAssertTrue(js.contains("function priorityPreviewGames(p)"))
        XCTAssertTrue(js.contains("if (source === 'personal') return (p.personalPriorityGames || []).slice();"))
        XCTAssertTrue(js.contains("if (source === 'globalAndPersonal') return (p.priorityGames || []).slice();"))
        XCTAssertTrue(js.contains("games.slice(0, 4).forEach"))
        XCTAssertTrue(js.contains("priority-art-more"))
        XCTAssertTrue(js.contains("global · ${personalCount} personal"))
    }

    func testIdleDashboardUsesUpToDateStateInsteadOfAnEmptyProgressBar() {
        XCTAssertTrue(WebDashboardAssets.appJS.contains("class=\"up-to-date-state\""))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("Up to Date"))
        // The status card carries progress only when there is a campaign in
        // progress, so an idle miner never gets an empty bar under its headline.
        XCTAssertTrue(WebDashboardAssets.appJS.contains("Nothing waiting to be mined."))
        XCTAssertFalse(WebDashboardAssets.appJS.contains("Idle - no campaigns"))
    }

    /// The miner page is a status read, top to bottom: who → what now → what
    /// next → why → what happened. A card that drifts out of that order (or a
    /// second card repeating one of them) is the regression this catches.
    func testMinerDetailFollowsTheStatusFirstHierarchy() {
        let js = WebDashboardAssets.appJS
        XCTAssertTrue(js.contains("${minerIdentity(p)}${minerStateCard(p)}"))
        XCTAssertTrue(js.contains("${dropsCard(p)}${accountRemovalCard(p)}"))
        XCTAssertTrue(js.contains("Recent Completed Drops"))
        // One consolidated Priorities card, not a global card plus a personal card.
        XCTAssertTrue(js.contains("function prioritiesCard(p)"))
        XCTAssertFalse(js.contains("function globalCard(p)"))
        XCTAssertFalse(js.contains("function progressCard(p)"))
        // The mode is read off the segmented control, not repeated as a badge.
        XCTAssertFalse(js.contains("mode-badge"))
    }

    /// Status and Up Next are one adaptive card: mining, a named next campaign,
    /// a miner-level problem and idle are shapes of the same surface, never two
    /// cards saying the same thing twice.
    func testMinerStateIsASingleAdaptiveCard() {
        let js = WebDashboardAssets.appJS
        XCTAssertTrue(js.contains("function minerStateCard(p)"))
        XCTAssertFalse(js.contains("function statusCard(p)"))
        XCTAssertFalse(js.contains("function upNextCard(p)"))
        // The four shapes.
        XCTAssertTrue(js.contains("Currently mining"))
        XCTAssertTrue(js.contains("Up next"))
        XCTAssertTrue(js.contains("Nothing waiting to be mined."))
        XCTAssertTrue(js.contains("Last checked"))
        // Idle says it once: no second heading under the green card.
        XCTAssertFalse(js.contains("Nothing waiting</div>"))
        // Problem states never promise a next campaign.
        XCTAssertTrue(js.contains("cfg.kind === 'blocked' || cfg.kind === 'notConfigured'"))
    }

    /// Up Next must describe a decision the projection can actually support: a
    /// campaign is named only when it is eligible now and the priority list
    /// ranks it.
    func testUpNextOnlyNamesACampaignItCanRank() {
        let js = WebDashboardAssets.appJS
        XCTAssertTrue(js.contains("function upNextDecision(p)"))
        XCTAssertTrue(js.contains("if (!best) return { kind: 'unranked', count: eligible.length };"))
        XCTAssertTrue(js.contains("Nothing waiting"))
        XCTAssertTrue(js.contains("Next eligible campaign · ${esc(upNextReason(p, c.game))}"))
        XCTAssertTrue(js.contains("return 'Global priority';"))
        XCTAssertTrue(js.contains("return 'Your priority';"))
        // A stopped miner is about to pick nothing, and a game the projection is
        // already raising an issue for cannot honestly be called next.
        XCTAssertTrue(js.contains("if (p.diagnostics && p.diagnostics.isRunning === false) return { kind: 'stopped' };"))
        XCTAssertTrue(js.contains("excluded.has(game) || blocked.has(game)"))
    }

    /// The Up Next action is labelled for where it actually lands: the campaign
    /// list opened on the named campaign, or the whole list when none is named.
    func testUpNextActionLabelFollowsItsDestination() {
        let js = WebDashboardAssets.appJS
        XCTAssertTrue(js.contains("View campaign →"))
        XCTAssertTrue(js.contains("View all campaigns →"))
        XCTAssertTrue(js.contains("data-focus-campaign="))
        XCTAssertTrue(js.contains("campaignsModalFocusId = open.dataset.focusCampaign || null;"))
    }

    /// Issues and subscription-gated campaigns are conditional exceptions: they
    /// sit together after the configuration, share one chrome, and never claim
    /// the status accent that belongs to Current Status.
    func testActionableExceptionsSitBetweenConfigurationAndHistory() {
        let js = WebDashboardAssets.appJS
        XCTAssertTrue(js.contains("${prioritiesCard(p)}${issuesCard(p)}${subscriptionRequiredCard()}${dropsCard(p)}"))
        XCTAssertTrue(js.contains("section-card exception-card\" id=\"route-issues\""))
        XCTAssertTrue(js.contains("section-card exception-card\" id=\"route-subscription\""))
        // Both return early when there is nothing to report, so no empty space
        // is reserved for them.
        XCTAssertTrue(js.contains("if (!p.issues || !p.issues.length) return '';"))
        XCTAssertTrue(js.contains("if (!campaigns.length) return '';"))
    }

    /// The footer reports whatever version is actually serving the page, and
    /// omits it rather than inventing one when there is no bundle to read.
    func testFooterUsesTheRunningVersionAndRealDestinations() {
        XCTAssertTrue(WebDashboardAssets.appHTML.contains("class=\"portal-footer\""))
        XCTAssertTrue(WebDashboardAssets.appHTML.contains("https://swiftminer.app/help/"))
        XCTAssertTrue(WebDashboardAssets.appHTML.contains("https://swiftminer.app/help/security-privacy/"))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("SESSION.app_version"))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("new Date().getFullYear()"))
        XCTAssertFalse(WebDashboardAssets.appHTML.contains("v1.0.0"))
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
        XCTAssertTrue(WebDashboardAssets.appJS.contains("class=\"miner-identity-copy\""))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("dropsThisWeek === 1 ? 'drop' : 'drops'"))
        XCTAssertFalse(WebDashboardAssets.appJS.contains("Drops Claimed This Week"))
    }

    func testOperatorOverviewHonoursAnExplicitDiscordPicturePreference() {
        XCTAssertTrue(WebDashboardAssets.appJS.contains("operator-miner-avatar"))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("referrerpolicy=\"no-referrer\""))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("function customProfileImageURL(...urls)"))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("function secureProfileImageURL(url)"))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("discordapp.com/embed/avatars/"))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("customProfileImageURL(acc.profileImageURL, acc.discordProfileImageURL)"))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("secureProfileImageURL(acc.discordProfileImageURL) || customProfileImageURL(acc.profileImageURL)"))
        XCTAssertFalse(WebDashboardAssets.appJS.contains("${esc(cfg.headline)}${watchingHTML}"))
    }

    func testOperatorDetailShowsBackNavigationForDiscordAndLocalSessions() {
        XCTAssertTrue(WebDashboardAssets.appJS.contains("if (OPERATOR_MINERS.length <= 1) return '';"))
        XCTAssertTrue(WebDashboardAssets.appJS.contains("id=\"backoverview\""))
        XCTAssertFalse(WebDashboardAssets.appJS.contains("SESSION.provider === 'local') || OPERATOR_MINERS.length"))
    }

    func testLocalLoginPageShowsOnlyUsernamePasswordForm() async throws {
        let mgr = try await openTempManager()
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

    func testAccountRemovalRequiresCSRFAndExactTypedConfirmation() async throws {
        let mgr = try await openTempManager()
        try await mgr.execute("""
        INSERT INTO twitch_accounts (
            twitch_id, username, access_token, refresh_token, token_expiry, scopes, link_state
        ) VALUES (
            'twitch-1', 'Jonwatso', 'access', 'refresh', '2099-01-01T00:00:00Z', '', 'linked'
        );
        """)
        try await mgr.createWebSession(
            id: "remove-session",
            principalType: "twitch",
            principalId: "twitch-1",
            csrfToken: "csrf",
            createdAt: Date().timeIntervalSince1970,
            expiresAt: Date().addingTimeInterval(60).timeIntervalSince1970
        )

        let removed = AccountRemovalRecorder()
        let apiRoutes = DiscordAPIRoutes(
            manager: mgr,
            projectionBuilder: DiscordProjectionBuilder(manager: mgr),
            apiKey: "test-api-key"
        )
        await apiRoutes.setOnRemoveMinerByAccount { accountId in
            await removed.record(accountId)
            return true
        }
        let webRoutes = WebDashboardRoutes(
            config: WebDashboardConfig(baseURL: URL(string: "https://swiftminer.example.com")!, discord: nil, twitch: WebProviderCredentials(clientID: "id", clientSecret: "secret")),
            manager: mgr,
            apiRoutes: apiRoutes
        )
        let router = HTTPRouter()
        await webRoutes.configure(router)
        let cookie = "\(WebDashboardConfig.sessionCookieName)=remove-session"

        let noCSRF = await router.handle(HTTPRequest(
            method: "POST", path: "/me/account/remove", headers: ["cookie": cookie],
            body: Data("{\"confirmation\":\"swiftminer\"}".utf8)
        ))
        XCTAssertEqual(noCSRF.statusCode, 403)

        let wrongConfirmation = await router.handle(HTTPRequest(
            method: "POST", path: "/me/account/remove", headers: ["cookie": cookie, "x-sm-csrf": "csrf"],
            body: Data("{\"confirmation\":\"SwiftMiner\"}".utf8)
        ))
        XCTAssertEqual(wrongConfirmation.statusCode, 400)
        let accountIdsAfterWrongConfirmation = await removed.accountIds
        XCTAssertTrue(accountIdsAfterWrongConfirmation.isEmpty)

        let confirmed = await router.handle(HTTPRequest(
            method: "POST", path: "/me/account/remove", headers: ["cookie": cookie, "x-sm-csrf": "csrf"],
            body: Data("{\"confirmation\":\"swiftminer\"}".utf8)
        ))
        XCTAssertEqual(confirmed.statusCode, 200)
        let removedAccountIds = await removed.accountIds
        XCTAssertEqual(removedAccountIds, ["twitch-1"])
    }

    func testMinerExclusionsRequireCSRFAndAreScopedToTheSignedInMiner() async throws {
        let mgr = try await openTempManager()
        try await mgr.createWebSession(
            id: "exclusions-session",
            principalType: "twitch",
            principalId: "twitch-1",
            csrfToken: "csrf",
            createdAt: Date().timeIntervalSince1970,
            expiresAt: Date().addingTimeInterval(60).timeIntervalSince1970
        )

        let updated = ExclusionsRecorder()
        let apiRoutes = DiscordAPIRoutes(
            manager: mgr,
            projectionBuilder: DiscordProjectionBuilder(manager: mgr),
            apiKey: "test-api-key"
        )
        await apiRoutes.setOnSetExcludedGamesByAccount { accountId, games in
            await updated.record(accountId: accountId, games: games)
            return games
        }
        let webRoutes = WebDashboardRoutes(
            config: WebDashboardConfig(baseURL: URL(string: "https://swiftminer.example.com")!, discord: nil, twitch: WebProviderCredentials(clientID: "id", clientSecret: "secret")),
            manager: mgr,
            apiRoutes: apiRoutes
        )
        let router = HTTPRouter()
        await webRoutes.configure(router)
        let cookie = "\(WebDashboardConfig.sessionCookieName)=exclusions-session"
        let body = Data("{\"games\":[\"Game One\"]}".utf8)

        let noCSRF = await router.handle(HTTPRequest(
            method: "PUT", path: "/me/miners/twitch-1/exclusions", headers: ["cookie": cookie], body: body
        ))
        XCTAssertEqual(noCSRF.statusCode, 403)

        let otherAccount = await router.handle(HTTPRequest(
            method: "PUT", path: "/me/miners/twitch-2/exclusions", headers: ["cookie": cookie, "x-sm-csrf": "csrf"], body: body
        ))
        XCTAssertEqual(otherAccount.statusCode, 403)

        let confirmed = await router.handle(HTTPRequest(
            method: "PUT", path: "/me/miners/twitch-1/exclusions", headers: ["cookie": cookie, "x-sm-csrf": "csrf"], body: body
        ))
        XCTAssertEqual(confirmed.statusCode, 200)
        let updates = await updated.updates
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.0, "twitch-1")
        XCTAssertEqual(updates.first?.1, ["Game One"])
    }

    // MARK: - Session & OAuth-state persistence

    func testWebSessionLifecycleAndExpiry() async throws {
        let mgr = try await openTempManager()

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
        let now: Double = 4_000_000
        try await mgr.createOAuthState("stale", provider: "discord", createdAt: now - 1000, expiresAt: now - 1)
        let expired = await mgr.consumeOAuthState("stale", now: now)           // expired → nil
        let afterDelete = await mgr.consumeOAuthState("stale", now: now)       // and deleted
        XCTAssertNil(expired)
        XCTAssertNil(afterDelete)
    }

    func testOwnerDiscordIdNilForUnknownAccount() async throws {
        let mgr = try await openTempManager()
        let owner = await mgr.ownerDiscordId(forTwitchAccount: "no-such-account")
        XCTAssertNil(owner)
    }

    func testSwiftBotSSORegistersNewDiscordUserWithoutMiner() async throws {
        let mgr = try await openTempManager()
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

    /// Opens a throwaway database and registers its own teardown, so callers cannot forget —
    /// and so the close is *awaited* before the file is unlinked. The previous
    /// `defer { Task { await mgr.close() } }` never awaited the close and left every temp
    /// database behind.
    private func openTempManager() async throws -> SQLiteManager {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftMiner-WebSecTests-\(UUID().uuidString).sqlite")
        let mgr = SQLiteManager(databaseURL: url)
        try await mgr.open()
        addTeardownBlock {
            await mgr.close()
            try? FileManager.default.removeItem(at: url)
        }
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

private actor AccountRemovalRecorder {
    private(set) var accountIds: [String] = []

    func record(_ accountId: String) {
        accountIds.append(accountId)
    }
}

private actor ExclusionsRecorder {
    private(set) var updates: [(String, [String])] = []

    func record(accountId: String, games: [String]) {
        updates.append((accountId, games))
    }
}
