import CryptoKit
import Foundation
import OSLog
import SwiftMinerCore

private let webLogger = Logger(subsystem: "com.swiftminer", category: "web")

/// Routes for the optional self-service web dashboard.
///
/// Identity is established once, server-side, via Discord **or** Twitch OAuth and
/// stored as an opaque session carrying a principal (`discord:<id>` or
/// `twitch:<id>`). Every `/me/*` route derives the acting principal **only** from
/// that session — there is no user identifier in any path a browser can reach —
/// so a signed-in user can only ever see and control their own miner.
///
/// Discord and Twitch are independent front doors. Discord DMs/linking are
/// untouched; a Twitch-only user simply gets the dashboard without DMs.
public actor WebDashboardRoutes {
    private let config: WebDashboardConfig
    private let manager: SQLiteManager
    private let apiRoutes: DiscordAPIRoutes
    private let urlSession: URLSession
    /// Resolves SwiftBot SSO availability live, so pairing/tunnel info gathered
    /// after server start (e.g. SwiftBot launched later) still lights up the
    /// Discord button without a relaunch. Falls back to `config.swiftBotSSO`.
    private let swiftBotSSOProvider: (@Sendable () async -> WebSwiftBotSSO?)?
    /// Login-page logo PNGs, served at /app/logo-dark.png and
    /// /app/logo-light.png; the page picks per color scheme. When nil the page
    /// falls back to a drawn gem mark.
    private let logoDarkPNG: Data?
    private let logoLightPNG: Data?
    /// Receives human-readable audit sentences ("Gabe signed in …") for the
    /// app's Activity Log. Optional; auditing is best-effort.
    private let audit: (@Sendable (String) async -> Void)?

    public init(
        config: WebDashboardConfig,
        manager: SQLiteManager,
        apiRoutes: DiscordAPIRoutes,
        swiftBotSSOProvider: (@Sendable () async -> WebSwiftBotSSO?)? = nil,
        logoDarkPNG: Data? = nil,
        logoLightPNG: Data? = nil,
        audit: (@Sendable (String) async -> Void)? = nil
    ) {
        self.config = config
        self.manager = manager
        self.apiRoutes = apiRoutes
        self.swiftBotSSOProvider = swiftBotSSOProvider
        self.logoDarkPNG = logoDarkPNG
        self.logoLightPNG = logoLightPNG
        self.audit = audit
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        self.urlSession = URLSession(configuration: cfg)
    }

    /// Current SwiftBot SSO config, or nil when unavailable. Requires a public
    /// base URL (the assertion returns to our https callback) and a secret.
    private func currentSwiftBotSSO() async -> WebSwiftBotSSO? {
        guard config.baseURL != nil else { return nil }
        let sso = await swiftBotSSOProvider?() ?? config.swiftBotSSO
        guard let sso, !sso.hmacSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return sso
    }

    // MARK: - Registration

    public func configure(_ router: HTTPRouter) async {
        let me = self

        await router.register(HTTPRoute(method: "GET", pattern: "/") { req, _ in
            await me.handleRoot(req)
        })
        await router.register(HTTPRoute(method: "GET", pattern: WebDashboardConfig.loginPath) { req, _ in
            await me.handleLoginChooser(req)
        })
        await router.register(HTTPRoute(method: "GET", pattern: "/login/:provider") { req, params in
            await me.handleProviderLogin(req, providerRaw: params["provider"])
        })
        await router.register(HTTPRoute(method: "POST", pattern: "/login/local") { req, _ in
            await me.handleLocalLogin(req)
        })
        await router.register(HTTPRoute(method: "GET", pattern: WebDashboardConfig.callbackPath) { req, _ in
            await me.handleCallback(req)
        })
        await router.register(HTTPRoute(method: "GET", pattern: "/oauth/swiftbot/callback") { req, _ in
            await me.handleSwiftBotSSOCallback(req)
        })
        await router.register(HTTPRoute(method: "GET", pattern: WebDashboardConfig.appPath) { req, _ in
            await me.handleApp(req)
        })
        await router.register(HTTPRoute(method: "GET", pattern: "/app/app.js") { _, _ in
            HTTPResponse(statusCode: 200,
                         headers: ["Content-Type": "application/javascript; charset=utf-8",
                                   "X-Content-Type-Options": "nosniff",
                                   "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0"],
                         body: Data(WebDashboardAssets.appJS.utf8))
        })
        await router.register(HTTPRoute(method: "GET", pattern: "/app/login.js") { _, _ in
            HTTPResponse(statusCode: 200,
                         headers: ["Content-Type": "application/javascript; charset=utf-8",
                                   "X-Content-Type-Options": "nosniff",
                                   "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0"],
                         body: Data(WebDashboardAssets.loginJS.utf8))
        })
        // Browsers request /favicon.ico unprompted; modern ones accept PNG
        // bytes there. The <link rel="icon"> tags on each page make the format
        // explicit anyway.
        if let favicon = logoDarkPNG {
            await router.register(HTTPRoute(method: "GET", pattern: "/favicon.ico") { _, _ in
                HTTPResponse(statusCode: 200,
                             headers: ["Content-Type": "image/png",
                                       "Cache-Control": "public, max-age=86400",
                                       "Content-Length": "\(favicon.count)"],
                             body: favicon)
            })
        }
        for (path, data) in [("/app/logo-dark.png", logoDarkPNG), ("/app/logo-light.png", logoLightPNG)] {
            guard let data else { continue }
            await router.register(HTTPRoute(method: "GET", pattern: path) { _, _ in
                HTTPResponse(statusCode: 200,
                             headers: ["Content-Type": "image/png",
                                       "Cache-Control": "public, max-age=86400",
                                       "Content-Length": "\(data.count)"],
                             body: data)
            })
        }

        // Session-scoped API. Each resolves the principal from the cookie.
        await router.register(HTTPRoute(method: "GET", pattern: "/me/session") { req, _ in
            await me.withSession(req) { s in await me.handleSessionInfo(s) }
        })
        await router.register(HTTPRoute(method: "GET", pattern: "/me/projection") { req, _ in
            await me.withSession(req) { s in await me.projection(for: s) }
        })
        await router.register(HTTPRoute(method: "GET", pattern: "/me/games") { req, _ in
            await me.withSession(req) { _ in await me.apiRoutes.webKnownGames() }
        })
        await router.register(HTTPRoute(method: "GET", pattern: "/me/campaigns") { req, _ in
            await me.withSession(req) { s in await me.campaigns(for: s) }
        })
        await router.register(HTTPRoute(method: "POST", pattern: WebDashboardConfig.logoutPath) { req, _ in
            await me.handleLogout(req)
        })
        await router.register(HTTPRoute(method: "POST", pattern: "/me/campaigns/:campaignId/:action") { req, params in
            await me.withSession(req, requireCSRF: true) { s in
                guard let campaignId = params["campaignId"], let action = params["action"] else { return .badRequest }
                return await me.campaignAction(for: s, campaignId: campaignId, action: action, body: req.body)
            }
        })
        await router.register(HTTPRoute(method: "PUT", pattern: "/me/miners/:accountId/priorities") { req, params in
            await me.withSession(req, requireCSRF: true) { s in
                guard let accountId = params["accountId"] else { return .badRequest }
                return await me.setPriorities(for: s, accountId: accountId, body: req.body)
            }
        })
        await router.register(HTTPRoute(method: "POST", pattern: "/me/miners/:accountId/control/:action") { req, params in
            await me.withSession(req, requireCSRF: true) { s in
                guard let accountId = params["accountId"], let actionStr = params["action"],
                      let action = MinerControlAction(rawValue: actionStr) else { return .badRequest }
                return await me.controlMiner(for: s, accountId: accountId, action: action)
            }
        })
        // Activation (linking a Twitch account) only applies to a Discord principal.
        await router.register(HTTPRoute(method: "POST", pattern: "/me/activation") { req, _ in
            await me.withSession(req, requireCSRF: true) { s in
                guard s.principalType == WebProvider.discord.rawValue else {
                    return .error(code: "not_applicable", message: "Account linking is only available for Discord sign-in.", statusCode: 409)
                }
                return await me.apiRoutes.webStartActivation(discordId: s.principalId)
            }
        })
        await router.register(HTTPRoute(method: "GET", pattern: "/me/activation/:sessionId") { req, params in
            await me.withSession(req) { s in
                guard s.principalType == WebProvider.discord.rawValue, let sid = params["sessionId"] else { return .badRequest }
                return await me.apiRoutes.webActivationStatus(discordId: s.principalId, sessionId: sid)
            }
        })

        webLogger.info("Web dashboard routes registered (base=\(self.config.normalisedBase ?? "local-only", privacy: .public) discord=\(self.config.discordEnabled, privacy: .public) twitch=\(self.config.twitchEnabled, privacy: .public) local=\(self.config.localEnabled, privacy: .public))")
    }

    // MARK: - Principal-aware dispatch

    private func projection(for s: WebSessionRecord) async -> HTTPResponse {
        if s.principalType == WebProvider.twitch.rawValue {
            if await apiRoutes.isOperatorTwitch(twitchId: s.principalId) {
                return await apiRoutes.webOverview()
            }
            return await apiRoutes.webProjectionTwitch(twitchId: s.principalId)
        } else if s.principalType == WebProvider.discord.rawValue {
            if await apiRoutes.isOperatorDiscord(discordId: s.principalId) {
                return await apiRoutes.webOverview()
            }
            return await apiRoutes.webProjection(discordId: s.principalId)
        } else {
            return await apiRoutes.webOverview()
        }
    }

    private func setPriorities(for s: WebSessionRecord, accountId: String, body: Data) async -> HTTPResponse {
        switch s.principalType {
        case Self.localPrincipal:
            // The operator may manage any mined account.
            return await apiRoutes.webSetPrioritiesTwitch(twitchId: accountId, body: body)
        case WebProvider.twitch.rawValue:
            let isOperator = await apiRoutes.isOperatorTwitch(twitchId: s.principalId)
            guard accountId == s.principalId || isOperator else {
                return .error(code: "forbidden", message: "You can only manage your own miner.", statusCode: 403)
            }
            return await apiRoutes.webSetPrioritiesTwitch(twitchId: accountId, body: body)
        default:
            let isOperator = await apiRoutes.isOperatorDiscord(discordId: s.principalId)
            let owns = await apiRoutes.webVerifiesDiscordOwnership(discordId: s.principalId, accountId: accountId)
            guard owns || isOperator else {
                return .error(code: "forbidden", message: "You can only manage your own miner.", statusCode: 403)
            }
            return await apiRoutes.webSetPrioritiesTwitch(twitchId: accountId, body: body)
        }
    }

    private func controlMiner(for s: WebSessionRecord, accountId: String, action: MinerControlAction) async -> HTTPResponse {
        let isAllowed: Bool
        switch s.principalType {
        case Self.localPrincipal:
            isAllowed = true
        case WebProvider.twitch.rawValue:
            let isOperator = await apiRoutes.isOperatorTwitch(twitchId: s.principalId)
            isAllowed = (s.principalId == accountId) || isOperator
        default:
            let isOperator = await apiRoutes.isOperatorDiscord(discordId: s.principalId)
            let owns = await apiRoutes.webVerifiesDiscordOwnership(discordId: s.principalId, accountId: accountId)
            isAllowed = owns || isOperator
        }

        guard isAllowed else {
            return .error(code: "forbidden", message: "You cannot control this miner.", statusCode: 403)
        }

        guard await apiRoutes.hasMinerControlByAccount() else {
            return .error(code: "control_unavailable", message: "Miner controls are not available.", statusCode: 503)
        }

        let response = await apiRoutes.executeMinerControlByAccount(accountId: accountId, action: action)
        return HTTPResponse.json(response, statusCode: response.ok ? 200 : 409)
    }

    private func campaignAction(for s: WebSessionRecord, campaignId: String, action: String, body: Data) async -> HTTPResponse {
        // Campaign ignore/prioritise decisions are Discord-keyed.
        let discordId: String
        switch s.principalType {
        case Self.localPrincipal:
            return .error(code: "not_supported", message: "Campaign decisions aren't available for the local operator view.", statusCode: 409)
        case WebProvider.twitch.rawValue:
            guard let owner = await manager.ownerDiscordId(forTwitchAccount: s.principalId) else {
                return .error(code: "link_required", message: "Link a Discord account to manage campaign decisions.", statusCode: 409)
            }
            discordId = owner
        default:
            discordId = s.principalId
        }
        return await apiRoutes.webCampaignAction(discordId: discordId, campaignId: campaignId, action: action, body: body)
    }

    private func campaigns(for s: WebSessionRecord) async -> HTTPResponse {
        struct Campaigns: Encodable { let campaigns: [WebCampaignSummary] }
        switch s.principalType {
        case WebProvider.twitch.rawValue:
            return await apiRoutes.webCampaigns(accountId: s.principalId)
        case WebProvider.discord.rawValue:
            guard let accountId = await manager.firstTwitchAccountId(ownerDiscordId: s.principalId) else {
                return HTTPResponse.json(Campaigns(campaigns: []))
            }
            return await apiRoutes.webCampaigns(accountId: accountId)
        default:
            return HTTPResponse.json(Campaigns(campaigns: []))
        }
    }

    /// Principal type stored for local username/password sessions.
    private static let localPrincipal = "local"

    // MARK: - Session gate

    private func withSession(
        _ req: HTTPRequest,
        requireCSRF: Bool = false,
        _ body: (WebSessionRecord) async -> HTTPResponse
    ) async -> HTTPResponse {
        let cookies = WebCookie.parse(req.header("cookie"))
        guard let sid = cookies[WebDashboardConfig.sessionCookieName],
              let session = await manager.fetchWebSession(id: sid, now: Date().timeIntervalSince1970) else {
            return .unauthorized
        }
        if requireCSRF {
            guard let presented = req.header(WebDashboardConfig.csrfHeaderName),
                  WebSecurity.constantTimeEquals(presented, session.csrfToken) else {
                let actor = await actorName(session)
                await audit?("Blocked a request from \(actor) — missing or invalid CSRF token")
                return .error(code: "csrf_failed", message: "Missing or invalid CSRF token.", statusCode: 403)
            }
        }
        return await body(session)
    }

    private func currentSession(_ req: HTTPRequest) async -> WebSessionRecord? {
        let cookies = WebCookie.parse(req.header("cookie"))
        guard let sid = cookies[WebDashboardConfig.sessionCookieName] else { return nil }
        return await manager.fetchWebSession(id: sid, now: Date().timeIntervalSince1970)
    }

    // MARK: - Page handlers

    private func handleRoot(_ req: HTTPRequest) async -> HTTPResponse {
        if await currentSession(req) != nil { return .redirect(to: WebDashboardConfig.appPath) }
        return .redirect(to: WebDashboardConfig.loginPath)
    }

    private func handleLoginChooser(_ req: HTTPRequest) async -> HTTPResponse {
        if await currentSession(req) != nil { return .redirect(to: WebDashboardConfig.appPath) }
        // Only offer the local form when this request is local (not the public
        // domain), so the password box never appears over the tunnel.
        let localAvailable = config.localEnabled && isLocalRequest(req)
        if localAvailable {
            return .html(WebDashboardAssets.loginPage(
                discordSSOURL: nil,
                twitch: false,
                local: true,
                appIcon: logoDarkPNG != nil && logoLightPNG != nil
            ))
        }
        return .html(WebDashboardAssets.loginPage(
            discordSSOURL: await swiftBotSSOStartURL(),
            twitch: config.twitchEnabled,
            local: false,
            appIcon: logoDarkPNG != nil && logoLightPNG != nil
        ))
    }

    /// URL of SwiftBot's companion-SSO entry point, with our callback as the
    /// return target. Nil when SSO isn't available.
    private func swiftBotSSOStartURL() async -> String? {
        guard let sso = await currentSwiftBotSSO(), let base = config.normalisedBase else { return nil }
        let returnTo = base + "/oauth/swiftbot/callback"
        var comps = URLComponents(string: sso.origin + "/auth/companion/discord")
        comps?.queryItems = [URLQueryItem(name: "return_to", value: returnTo)]
        return comps?.url?.absoluteString
    }

    /// True when the request is NOT addressed to the configured public domain —
    /// i.e. it arrived directly on localhost/LAN rather than through the tunnel.
    /// Tunnels (Cloudflare/Tailscale) always set `Host` to the public domain, so
    /// this keeps local sign-in off the public internet without trusting IPs.
    private func isLocalRequest(_ req: HTTPRequest) -> Bool {
        guard let publicHost = config.publicHost else { return true } // no public domain at all
        let host = (req.header("host") ?? "").lowercased()
        // Strip any port for comparison.
        let hostName = host.split(separator: ":").first.map(String.init) ?? host
        return hostName != publicHost
    }

    private func handleLocalLogin(_ req: HTTPRequest) async -> HTTPResponse {
        guard config.localEnabled, let creds = config.local else {
            return .error(code: "not_available", message: "Local sign-in is disabled.", statusCode: 404)
        }
        guard isLocalRequest(req) else {
            // Local credentials must never be accepted over the public domain.
            await audit?("Blocked a local sign-in attempt over the public domain")
            return .error(code: "forbidden", message: "Local sign-in is only available on the local network.", statusCode: 403)
        }
        let form = WebForm.parse(req.body)
        let username = form["username"] ?? ""
        let password = form["password"] ?? ""
        // Constant-time username check + hashed password verify.
        guard WebSecurity.constantTimeEquals(username, creds.username),
              WebSecurity.verifyLocalPassword(password, encoded: creds.passwordHash) else {
            let attempted = String(username.prefix(32))
            await audit?("Failed local sign-in attempt\(attempted.isEmpty ? "" : " (username “\(attempted)”)")")
            return .html(WebDashboardAssets.message("Incorrect username or password.", linkToLogin: true), statusCode: 401)
        }
        await audit?("\(creds.username) signed in to the web dashboard (local)")
        return await issueSession(principalType: Self.localPrincipal, principalId: creds.username, secureCookie: false)
    }

    private func handleProviderLogin(_ req: HTTPRequest, providerRaw: String?) async -> HTTPResponse {
        guard let raw = providerRaw, let provider = WebProvider(rawValue: raw),
              let creds = config.credentials(for: provider) else {
            return .html(WebDashboardAssets.message("That sign-in method isn't available.", linkToLogin: true), statusCode: 404)
        }
        if isLocalRequest(req) {
            return .html(WebDashboardAssets.message("Use local sign-in from this address.", linkToLogin: true), statusCode: 403)
        }
        guard provider != .discord else {
            return .html(WebDashboardAssets.message("Discord sign-in is handled through SwiftBot so server membership can be verified.", linkToLogin: true), statusCode: 403)
        }
        let now = Date().timeIntervalSince1970
        await manager.purgeExpiredOAuthStates(now: now)
        let state = WebSecurity.randomToken()
        do {
            try await manager.createOAuthState(state, provider: provider.rawValue, createdAt: now, expiresAt: now + WebDashboardConfig.oauthStateTTL)
        } catch {
            return .error(code: "internal_error", message: "Could not start login.", statusCode: 500)
        }
        return .redirect(to: authorizeURL(provider: provider, creds: creds, state: state))
    }

    private func handleCallback(_ req: HTTPRequest) async -> HTTPResponse {
        if let err = req.queryParams["error"] {
            webLogger.notice("OAuth callback error: \(err, privacy: .public)")
            return .html(WebDashboardAssets.message("Login was cancelled.", linkToLogin: true))
        }
        guard let code = req.queryParams["code"], let state = req.queryParams["state"] else {
            return .html(WebDashboardAssets.message("Invalid login response.", linkToLogin: true), statusCode: 400)
        }
        // One-time state consumption returns the provider it was minted for.
        guard let providerRaw = await manager.consumeOAuthState(state, now: Date().timeIntervalSince1970),
              let provider = WebProvider(rawValue: providerRaw),
              let creds = config.credentials(for: provider) else {
            return .html(WebDashboardAssets.message("Login session expired. Please try again.", linkToLogin: true), statusCode: 400)
        }

        let principal: (type: WebProvider, id: String)
        switch provider {
        case .discord:
            guard let token = await exchangeCode(code, provider: .discord, creds: creds),
                  let id = await fetchDiscordUserId(accessToken: token), isValidSnowflake(id) else {
                return .html(WebDashboardAssets.message("Could not complete Discord login.", linkToLogin: true), statusCode: 502)
            }
            // Web-first onboarding: ensure the Discord user row exists.
            guard await apiRoutes.webSelfRegister(discordId: id) else {
                return .html(WebDashboardAssets.message("Could not set up your account.", linkToLogin: true), statusCode: 500)
            }
            principal = (.discord, id)

        case .twitch:
            guard let token = await exchangeCode(code, provider: .twitch, creds: creds),
                  let twitchUser = await fetchTwitchUser(accessToken: token, clientID: creds.clientID) else {
                return .html(WebDashboardAssets.message("Could not complete Twitch login.", linkToLogin: true), statusCode: 502)
            }
            let id = twitchUser.id
            // Only Twitch accounts that SwiftMiner actually mines may sign in.
            guard let account = await manager.twitchAccount(twitchId: id) else {
                await audit?("Twitch user \(twitchUser.login) tried to sign in, but their account isn't mined here")
                return .html(WebDashboardAssets.message("This Twitch account isn't being mined here. Ask the operator to add it first.", linkToLogin: true), statusCode: 403)
            }
            await audit?("\(account.username) signed in to the web dashboard (Twitch)")
            principal = (.twitch, id)
        }

        return await issueSession(principalType: principal.type.rawValue, principalId: principal.id)
    }

    /// Completes Discord sign-in brokered by SwiftBot. Verifies the assertion's
    /// HMAC (pairing secret, constant-time), expiry, and single-use nonce, then
    /// issues a normal Discord-principal session.
    private func handleSwiftBotSSOCallback(_ req: HTTPRequest) async -> HTTPResponse {
        guard let sso = await currentSwiftBotSSO() else {
            return .html(WebDashboardAssets.message("Discord sign-in isn't available.", linkToLogin: true), statusCode: 404)
        }
        guard let payload = req.queryParams["sso"], !payload.isEmpty,
              let signature = req.queryParams["sig"], !signature.isEmpty else {
            return .html(WebDashboardAssets.message("Invalid sign-in response.", linkToLogin: true), statusCode: 400)
        }

        let key = SymmetricKey(data: Data(sso.hmacSecret.utf8))
        let expected = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: key)
            .map { String(format: "%02x", $0) }
            .joined()
        guard WebSecurity.constantTimeEquals(expected, signature.lowercased()) else {
            webLogger.notice("SwiftBot SSO rejected: bad signature")
            // Unverified payload — its claims can't be trusted, so no identity here.
            await audit?("Blocked a Discord sign-in with an invalid SwiftBot signature")
            return .html(WebDashboardAssets.message("Sign-in could not be verified.", linkToLogin: true), statusCode: 403)
        }

        let now = Date().timeIntervalSince1970
        guard let data = Self.base64URLDecode(payload),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let discordId = object["discordUserId"] as? String, isValidSnowflake(discordId),
              let exp = object["exp"] as? Int, Double(exp) >= now,
              let nonce = object["nonce"] as? String, !nonce.isEmpty else {
            await audit?("Rejected an expired or malformed Discord sign-in assertion")
            return .html(WebDashboardAssets.message("Sign-in expired. Please try again.", linkToLogin: true), statusCode: 400)
        }
        // Signature verified above, so the payload's claims are trustworthy.
        let displayName = (object["username"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Discord user"
        guard Self.swiftBotSSOConfirmsGuildMembership(object) else {
            webLogger.notice("SwiftBot SSO rejected: user is not a member of the attached server")
            await audit?("\(displayName) tried to sign in with Discord but isn't in the server")
            return .html(WebDashboardAssets.statusMessage(
                title: "Not in this server",
                text: "Your Discord account is not part of the server attached to this SwiftMiner. Ask the person who runs the miner to invite you, then try signing in again.",
                linkText: "Back to sign in"
            ), statusCode: 403)
        }

        // Single-use: recording the nonce fails on replay (primary-key insert).
        do {
            try await manager.createOAuthState("sso-nonce:\(nonce)", provider: "swiftbot-sso", createdAt: now, expiresAt: Double(exp))
        } catch {
            webLogger.notice("SwiftBot SSO rejected: replayed nonce")
            await audit?("Rejected a replayed Discord sign-in for \(displayName)")
            return .html(WebDashboardAssets.message("Sign-in expired. Please try again.", linkToLogin: true), statusCode: 400)
        }

        guard await apiRoutes.webSelfRegister(discordId: discordId) else {
            return .html(WebDashboardAssets.message("Could not set up your account.", linkToLogin: true), statusCode: 500)
        }
        await audit?("\(displayName) signed in to the web dashboard (Discord)")
        return await issueSession(principalType: WebProvider.discord.rawValue, principalId: discordId)
    }

    private static func swiftBotSSOConfirmsGuildMembership(_ object: [String: Any]) -> Bool {
        for key in ["isGuildMember", "guildMember", "isServerMember", "serverMember", "memberOfAttachedServer"] {
            guard let rawValue = object[key] else { continue }
            if let value = rawValue as? Bool {
                return value
            }
            if let value = rawValue as? NSNumber {
                return value.boolValue
            }
            if let value = rawValue as? String {
                switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "true", "1", "yes":
                    return true
                case "false", "0", "no":
                    return false
                default:
                    continue
                }
            }
        }
        return false
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var s = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }

    private func issueSession(principalType: String, principalId: String, secureCookie: Bool? = nil) async -> HTTPResponse {
        let now = Date().timeIntervalSince1970
        await manager.purgeExpiredWebSessions(now: now)
        let sessionId = WebSecurity.randomToken()
        let csrf = WebSecurity.randomToken()
        do {
            try await manager.createWebSession(
                id: sessionId,
                principalType: principalType,
                principalId: principalId,
                csrfToken: csrf,
                createdAt: now,
                expiresAt: now + WebDashboardConfig.sessionTTL
            )
        } catch {
            return .html(WebDashboardAssets.message("Could not create your session.", linkToLogin: true), statusCode: 500)
        }
        let cookie = WebCookie.sessionCookie(
            name: WebDashboardConfig.sessionCookieName,
            value: sessionId,
            maxAge: WebDashboardConfig.sessionTTL,
            secure: secureCookie ?? config.useSecureCookies
        )
        webLogger.info("Web session issued (\(principalType, privacy: .public))")
        return .redirect(to: WebDashboardConfig.appPath, setCookie: cookie)
    }

    private func handleApp(_ req: HTTPRequest) async -> HTTPResponse {
        guard await currentSession(req) != nil else { return .redirect(to: WebDashboardConfig.loginPath) }
        return .html(WebDashboardAssets.appHTML)
    }

    private func handleSessionInfo(_ s: WebSessionRecord) async -> HTTPResponse {
        struct Info: Encodable { let provider: String; let csrfToken: String }
        return .json(Info(provider: s.principalType, csrfToken: s.csrfToken))
    }

    /// Human-readable name for a session's principal, for audit entries.
    private func actorName(_ s: WebSessionRecord) async -> String {
        switch s.principalType {
        case WebProvider.twitch.rawValue:
            return await manager.twitchAccount(twitchId: s.principalId)?.username ?? "Twitch user"
        case Self.localPrincipal:
            return s.principalId
        case WebProvider.discord.rawValue:
            if let accountId = await manager.firstTwitchAccountId(ownerDiscordId: s.principalId),
               let account = await manager.twitchAccount(twitchId: accountId) {
                return account.username
            }
            return "Discord user"
        default:
            return "Web user"
        }
    }

    private func handleLogout(_ req: HTTPRequest) async -> HTTPResponse {
        if let s = await currentSession(req) {
            await manager.deleteWebSession(id: s.id)
            let actor = await actorName(s)
            await audit?("\(actor) signed out of the web dashboard")
        }
        let cleared = WebCookie.expiredCookie(
            name: WebDashboardConfig.sessionCookieName,
            secure: config.useSecureCookies && !isLocalRequest(req)
        )
        return .redirect(to: WebDashboardConfig.loginPath, setCookie: cleared)
    }

    // MARK: - Provider OAuth

    private func authorizeURL(provider: WebProvider, creds: WebProviderCredentials, state: String) -> String {
        var comps: URLComponents
        var items = [
            URLQueryItem(name: "client_id", value: creds.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: state)
        ]
        switch provider {
        case .discord:
            comps = URLComponents(string: "https://discord.com/oauth2/authorize")!
            items.append(URLQueryItem(name: "scope", value: "identify"))
            items.append(URLQueryItem(name: "prompt", value: "none"))
        case .twitch:
            comps = URLComponents(string: "https://id.twitch.tv/oauth2/authorize")!
            // No scopes needed: helix/users returns the caller's own record.
            items.append(URLQueryItem(name: "scope", value: ""))
        }
        comps.queryItems = items
        return comps.url!.absoluteString
    }

    private func tokenURL(for provider: WebProvider) -> URL {
        switch provider {
        case .discord: return URL(string: "https://discord.com/api/oauth2/token")!
        case .twitch:  return URL(string: "https://id.twitch.tv/oauth2/token")!
        }
    }

    private func exchangeCode(_ code: String, provider: WebProvider, creds: WebProviderCredentials) async -> String? {
        var req = URLRequest(url: tokenURL(for: provider))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "client_id", value: creds.clientID),
            URLQueryItem(name: "client_secret", value: creds.clientSecret),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI)
        ]
        req.httpBody = body.percentEncodedQuery.map { Data($0.utf8) }
        do {
            let (data, resp) = try await urlSession.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                webLogger.error("\(provider.rawValue, privacy: .public) token exchange non-2xx")
                return nil
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return json?["access_token"] as? String
        } catch {
            webLogger.error("token exchange error: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func fetchDiscordUserId(accessToken: String) async -> String? {
        var req = URLRequest(url: URL(string: "https://discord.com/api/users/@me")!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return await getJSONString(req, key: "id")
    }

    private func fetchTwitchUser(accessToken: String, clientID: String) async -> (id: String, login: String)? {
        var req = URLRequest(url: URL(string: "https://api.twitch.tv/helix/users")!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(clientID, forHTTPHeaderField: "Client-Id")
        do {
            let (data, resp) = try await urlSession.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let user = (json?["data"] as? [[String: Any]])?.first,
                  let id = user["id"] as? String else { return nil }
            let login = (user["display_name"] as? String) ?? (user["login"] as? String) ?? "id \(id)"
            return (id, login)
        } catch {
            webLogger.error("helix/users error: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func getJSONString(_ req: URLRequest, key: String) async -> String? {
        do {
            let (data, resp) = try await urlSession.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return json?[key] as? String
        } catch {
            return nil
        }
    }

    private func isValidSnowflake(_ id: String) -> Bool {
        id.count >= 17 && id.count <= 19 && id.allSatisfy { $0.isNumber }
    }
}
