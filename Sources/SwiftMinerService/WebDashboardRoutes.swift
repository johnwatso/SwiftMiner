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

    public init(config: WebDashboardConfig, manager: SQLiteManager, apiRoutes: DiscordAPIRoutes) {
        self.config = config
        self.manager = manager
        self.apiRoutes = apiRoutes
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        self.urlSession = URLSession(configuration: cfg)
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
        await router.register(HTTPRoute(method: "GET", pattern: WebDashboardConfig.appPath) { req, _ in
            await me.handleApp(req)
        })
        await router.register(HTTPRoute(method: "GET", pattern: "/app/app.js") { _, _ in
            HTTPResponse(statusCode: 200,
                         headers: ["Content-Type": "application/javascript; charset=utf-8",
                                   "X-Content-Type-Options": "nosniff"],
                         body: Data(WebDashboardAssets.appJS.utf8))
        })

        // Session-scoped API. Each resolves the principal from the cookie.
        await router.register(HTTPRoute(method: "GET", pattern: "/me/session") { req, _ in
            await me.withSession(req) { s in await me.handleSessionInfo(s) }
        })
        await router.register(HTTPRoute(method: "GET", pattern: "/me/projection") { req, _ in
            await me.withSession(req) { s in await me.projection(for: s) }
        })
        await router.register(HTTPRoute(method: "POST", pattern: WebDashboardConfig.logoutPath) { req, _ in
            await me.withSession(req, requireCSRF: true) { s in await me.handleLogout(s) }
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
        switch s.principalType {
        case Self.localPrincipal:
            return await apiRoutes.webOverview()
        case WebProvider.twitch.rawValue:
            return await apiRoutes.webProjectionTwitch(twitchId: s.principalId)
        default:
            return await apiRoutes.webProjection(discordId: s.principalId)
        }
    }

    private func setPriorities(for s: WebSessionRecord, accountId: String, body: Data) async -> HTTPResponse {
        switch s.principalType {
        case Self.localPrincipal:
            // The operator may manage any mined account.
            return await apiRoutes.webSetPrioritiesTwitch(twitchId: accountId, body: body)
        case WebProvider.twitch.rawValue:
            // A Twitch principal owns exactly one account: itself. The path id
            // must match the session's account — nothing else is addressable.
            guard accountId == s.principalId else {
                return .error(code: "forbidden", message: "You can only manage your own miner.", statusCode: 403)
            }
            return await apiRoutes.webSetPrioritiesTwitch(twitchId: s.principalId, body: body)
        default:
            return await apiRoutes.webSetPriorities(discordId: s.principalId, accountId: accountId, body: body)
        }
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
        return .html(WebDashboardAssets.loginPage(
            discord: config.discordEnabled,
            twitch: config.twitchEnabled,
            local: localAvailable
        ))
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
            return .error(code: "forbidden", message: "Local sign-in is only available on the local network.", statusCode: 403)
        }
        let form = WebForm.parse(req.body)
        let username = form["username"] ?? ""
        let password = form["password"] ?? ""
        // Constant-time username check + hashed password verify.
        guard WebSecurity.constantTimeEquals(username, creds.username),
              WebSecurity.verifyLocalPassword(password, encoded: creds.passwordHash) else {
            return .html(WebDashboardAssets.message("Incorrect username or password.", linkToLogin: true), statusCode: 401)
        }
        return await issueSession(principalType: Self.localPrincipal, principalId: creds.username)
    }

    private func handleProviderLogin(_ req: HTTPRequest, providerRaw: String?) async -> HTTPResponse {
        guard let raw = providerRaw, let provider = WebProvider(rawValue: raw),
              let creds = config.credentials(for: provider) else {
            return .html(WebDashboardAssets.message("That sign-in method isn't available.", linkToLogin: true), statusCode: 404)
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
                  let id = await fetchTwitchUserId(accessToken: token, clientID: creds.clientID) else {
                return .html(WebDashboardAssets.message("Could not complete Twitch login.", linkToLogin: true), statusCode: 502)
            }
            // Only Twitch accounts that SwiftMiner actually mines may sign in.
            guard await manager.twitchAccount(twitchId: id) != nil else {
                return .html(WebDashboardAssets.message("This Twitch account isn't being mined here. Ask the operator to add it first.", linkToLogin: true), statusCode: 403)
            }
            principal = (.twitch, id)
        }

        return await issueSession(principalType: principal.type.rawValue, principalId: principal.id)
    }

    private func issueSession(principalType: String, principalId: String) async -> HTTPResponse {
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
            secure: config.useSecureCookies
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

    private func handleLogout(_ s: WebSessionRecord) async -> HTTPResponse {
        await manager.deleteWebSession(id: s.id)
        let cleared = WebCookie.expiredCookie(name: WebDashboardConfig.sessionCookieName, secure: config.useSecureCookies)
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

    private func fetchTwitchUserId(accessToken: String, clientID: String) async -> String? {
        var req = URLRequest(url: URL(string: "https://api.twitch.tv/helix/users")!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(clientID, forHTTPHeaderField: "Client-Id")
        do {
            let (data, resp) = try await urlSession.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let arr = json?["data"] as? [[String: Any]]
            return arr?.first?["id"] as? String
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
