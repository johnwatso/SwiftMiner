import Foundation
import SQLite3
import SwiftMinerCore

// MARK: - Activation Session Model

struct ActivationSession: Sendable {
    let sessionId: String
    let discordUserId: String
    let userCode: String
    let deviceCode: String
    let verificationUri: String
    let expiresAt: Date
    let intervalSeconds: Int
    var status: ActivationStatus
    var linkedAccountId: String?
    var twitchUsername: String?
    var failureReason: String?

    enum ActivationStatus: String, Sendable {
        case pending
        case authorized
        case expired
        case failed
    }

    func toResponse() -> SwiftMinerActivationSessionResponse {
        SwiftMinerActivationSessionResponse(
            sessionId: sessionId,
            userCode: userCode,
            verificationUri: verificationUri,
            expiresAt: expiresAt,
            intervalSeconds: intervalSeconds
        )
    }

    func toStatusResponse() -> SwiftMinerActivationStatusResponse {
        SwiftMinerActivationStatusResponse(
            sessionId: sessionId,
            status: status.rawValue,
            linkedAccountId: linkedAccountId,
            twitchUsername: twitchUsername,
            failureReason: failureReason
        )
    }
}

// MARK: - Response Models

struct SwiftMinerActivationSessionResponse: Codable, Sendable {
    let sessionId: String
    let userCode: String
    let verificationUri: String
    let expiresAt: Date
    let intervalSeconds: Int
}

struct SwiftMinerActivationStatusResponse: Codable, Sendable {
    let sessionId: String
    let status: String
    let linkedAccountId: String?
    let twitchUsername: String?
    let failureReason: String?
}

private struct RegisterUserRequest: Codable, Sendable {
    let discordUserId: String
}

private struct UpdateDMStateRequest: Codable, Sendable {
    let hasReceivedWelcomeMessage: Bool?
    let hasCompletedInitialDMFlow: Bool?

    enum CodingKeys: String, CodingKey {
        case hasReceivedWelcomeMessage = "has_received_welcome_message"
        case hasCompletedInitialDMFlow = "has_completed_initial_dm_flow"
    }
}

private struct PauseLinkWarningRequest: Codable, Sendable {
    let days: Int
}

private struct PauseLinkWarningResponse: Codable, Sendable {
    let paused: Bool
    let game: String
    let expiresAt: Date
}

private struct UpdatePriorityRequest: Codable, Sendable {
    let gameId: String?
    let gameName: String
    let placement: String?

    enum CodingKeys: String, CodingKey {
        case gameId = "game_id"
        case gameName = "game_name"
        case placement
    }
}

private struct SetPrioritiesRequest: Codable, Sendable {
    let games: [String]
    let includeGlobalPriorities: Bool?
    let prioritySource: String?

    enum CodingKeys: String, CodingKey {
        case games
        case includeGlobalPriorities = "include_global_priorities"
        case prioritySource = "priority_source"
    }
}

public struct PrioritiesResponse: Codable, Sendable {
    public let accountId: String
    public let priorityGames: [String]
    public let includeGlobalPriorities: Bool

    public init(accountId: String, priorityGames: [String], includeGlobalPriorities: Bool = true) {
        self.accountId = accountId
        self.priorityGames = priorityGames
        self.includeGlobalPriorities = includeGlobalPriorities
    }

    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case priorityGames = "priority_games"
        case includeGlobalPriorities = "include_global_priorities"
    }
}

public struct PriorityUpdateResponse: Codable, Sendable {
    public let prioritised: Bool
    public let accountId: String
    public let gameName: String
    public let priorityGames: [String]

    public init(prioritised: Bool, accountId: String, gameName: String, priorityGames: [String]) {
        self.prioritised = prioritised
        self.accountId = accountId
        self.gameName = gameName
        self.priorityGames = priorityGames
    }

    enum CodingKeys: String, CodingKey {
        case prioritised
        case accountId = "account_id"
        case gameName = "game_name"
        case priorityGames = "priority_games"
    }
}

public struct WebCampaignSummary: Codable, Sendable {
    public let campaignId: String
    public let campaignName: String
    public let game: String
    public let status: String
    public let startsAt: Date
    public let endsAt: Date
    public let dropCount: Int
    public let claimedDrops: Int
    public let subscriptionRequiredDropCount: Int
    public let requiresSubscription: Bool
    public let boxArtURL: String?

    public init(
        campaignId: String,
        campaignName: String,
        game: String,
        status: String,
        startsAt: Date,
        endsAt: Date,
        dropCount: Int,
        claimedDrops: Int,
        subscriptionRequiredDropCount: Int = 0,
        requiresSubscription: Bool = false,
        boxArtURL: String?
    ) {
        self.campaignId = campaignId
        self.campaignName = campaignName
        self.game = game
        self.status = status
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.dropCount = dropCount
        self.claimedDrops = claimedDrops
        self.subscriptionRequiredDropCount = subscriptionRequiredDropCount
        self.requiresSubscription = requiresSubscription
        self.boxArtURL = boxArtURL
    }
}

// MARK: - API Routes

public actor DiscordAPIRoutes {
    private let manager: SQLiteManager
    private let projectionBuilder: DiscordProjectionBuilder
    private let adminLinkingService: any AdminLinkingService
    private let apiKey: String
    private let authService: TwitchAuthService?
    /// Notified after a successful Twitch auth so the host app can register the new
    /// account with MinerManager and refresh the UI.
    public var onAccountActivated: (@Sendable (Account, String) async -> Void)?
    public var onMinerControl: (@Sendable (String, MinerControlAction) async -> MinerControlResponse)?
    /// Suppress the account-link ("needs linking") warning/DM for a game.
    /// Returns true when at least one of the user's miners was updated.
    /// Args: (discordUserId, gameName).
    public var onIgnoreLinkWarning: (@Sendable (String, String) async -> Bool)?
    /// Temporarily suppress the account-link warning/DM for a game.
    /// Args: (discordUserId, gameName, expiry).
    public var onPauseLinkWarning: (@Sendable (String, String, Date) async -> Bool)?
    /// Moves a game to the top of a Discord-owned account/miner's priority list.
    /// Args: (discordUserId, accountId, gameName).
    public var onPrioritiseGame: (@Sendable (String, String, String) async -> [String]?)?
    /// Replaces a Discord-owned miner's personal priority games with the given list.
    /// Args: (discordUserId, accountId, games, include globals, source). Returns the resulting effective list.
    public var onSetPriorities: (@Sendable (String, String, [String], Bool?, String?) async -> [String]?)?
    /// Replaces a miner's personal priority games, identified by Twitch account
    /// id alone (no Discord owner needed). Used by Twitch-authenticated web
    /// sessions. Args: (accountId, games, include globals, source). Returns the resulting effective list.
    public var onSetPrioritiesByAccount: (@Sendable (String, [String], Bool?, String?) async -> [String]?)?
    /// Controls a miner, identified by Twitch account id alone (no Discord owner needed).
    /// Used by Twitch-authenticated or operator web sessions. Args: (accountId, action).
    public var onMinerControlByAccount: (@Sendable (String, MinerControlAction) async -> MinerControlResponse)?
    /// Removes a miner by its Twitch account id. The host is responsible for
    /// stopping the miner, revoking its Twitch token, and deleting local data.
    public var onRemoveMinerByAccount: (@Sendable (String) async -> Bool)?

    // In-memory activation session store (ephemeral; DB retains audit rows)
    private var activationSessions: [String: ActivationSession] = [:]
    private var activationPollTasks: [String: Task<Void, Never>] = [:]

    public init(
        manager: SQLiteManager,
        projectionBuilder: DiscordProjectionBuilder,
        apiKey: String,
        adminLinkingService: (any AdminLinkingService)? = nil,
        authService: TwitchAuthService? = nil
    ) {
        self.manager = manager
        self.projectionBuilder = projectionBuilder
        self.adminLinkingService = adminLinkingService ?? SQLiteAdminLinkingService(manager: manager)
        self.apiKey = apiKey
        self.authService = authService
    }

    public func setOnAccountActivated(_ handler: @escaping @Sendable (Account, String) async -> Void) {
        self.onAccountActivated = handler
    }

    public func setOnMinerControl(_ handler: @escaping @Sendable (String, MinerControlAction) async -> MinerControlResponse) {
        self.onMinerControl = handler
    }

    public func setOnIgnoreLinkWarning(_ handler: @escaping @Sendable (String, String) async -> Bool) {
        self.onIgnoreLinkWarning = handler
    }

    public func setOnPauseLinkWarning(_ handler: @escaping @Sendable (String, String, Date) async -> Bool) {
        self.onPauseLinkWarning = handler
    }

    public func setOnPrioritiseGame(_ handler: @escaping @Sendable (String, String, String) async -> [String]?) {
        self.onPrioritiseGame = handler
    }

    public func setOnSetPriorities(_ handler: @escaping @Sendable (String, String, [String], Bool?, String?) async -> [String]?) {
        self.onSetPriorities = handler
    }

    public func setOnSetPrioritiesByAccount(_ handler: @escaping @Sendable (String, [String], Bool?, String?) async -> [String]?) {
        self.onSetPrioritiesByAccount = handler
    }

    public func setOnMinerControlByAccount(_ handler: @escaping @Sendable (String, MinerControlAction) async -> MinerControlResponse) {
        self.onMinerControlByAccount = handler
    }

    public func setOnRemoveMinerByAccount(_ handler: @escaping @Sendable (String) async -> Bool) {
        self.onRemoveMinerByAccount = handler
    }

    /// Known campaign game names, for the web dashboard's add-game autocomplete.
    public var onKnownGames: (@Sendable () async -> [String])?
    /// Active/upcoming campaign summaries for the web dashboard browser.
    public var onCampaignSummaries: (@Sendable (String) async -> [WebCampaignSummary])?

    public func setOnKnownGames(_ handler: @escaping @Sendable () async -> [String]) {
        self.onKnownGames = handler
    }

    public func setOnCampaignSummaries(_ handler: @escaping @Sendable (String) async -> [WebCampaignSummary]) {
        self.onCampaignSummaries = handler
    }

    /// Game names with active campaigns — feeds the dashboard's autocomplete.
    public func webKnownGames() async -> HTTPResponse {
        struct Games: Encodable { let games: [String] }
        let games = await onKnownGames?() ?? []
        return HTTPResponse.json(Games(games: games))
    }

    /// Compact read-only campaign feed for the web dashboard.
    public func webCampaigns(accountId: String) async -> HTTPResponse {
        struct Campaigns: Encodable { let campaigns: [WebCampaignSummary] }
        let campaigns = await onCampaignSummaries?(accountId) ?? []
        return HTTPResponse.json(Campaigns(campaigns: campaigns))
    }

    public func configure(_ router: HTTPRouter) async {
        let routes = self

        // Health check (no auth)
        await router.register(HTTPRoute(method: "GET", pattern: "/health") { _, _ in
            HTTPResponse.json(["status": "ok"])
        })

        // Projection endpoint
        await router.register(HTTPRoute(method: "GET", pattern: "/v1/discord/users/:discordUserId") { request, params in
            await routes.handleGetProjection(request: request, params: params)
        })

        // List registered users
        await router.register(HTTPRoute(method: "GET", pattern: "/v1/users") { request, params in
            await routes.handleGetUsers(request: request, params: params)
        })

        // Registration endpoint
        await router.register(HTTPRoute(method: "POST", pattern: "/v1/users") { request, params in
            await routes.handleRegisterUser(request: request, params: params)
        })

        await router.register(HTTPRoute(method: "PATCH", pattern: "/v1/users/:discordUserId/dm-state") { request, params in
            await routes.handleUpdateDMState(request: request, params: params)
        })

        // Activation endpoints
        await router.register(HTTPRoute(method: "POST", pattern: "/v1/users/:discordUserId/activation") { request, params in
            await routes.handleStartActivation(request: request, params: params)
        })

        await router.register(HTTPRoute(method: "GET", pattern: "/v1/users/:discordUserId/activation/:sessionId") { request, params in
            await routes.handleGetActivationStatus(request: request, params: params)
        })

        await router.register(HTTPRoute(method: "DELETE", pattern: "/v1/users/:discordUserId/activation/:sessionId") { request, params in
            await routes.handleCancelActivation(request: request, params: params)
        })

        // Campaign action endpoint
        await router.register(HTTPRoute(method: "POST", pattern: "/v1/users/:discordUserId/campaigns/:campaignId/:action") { request, params in
            await routes.handleCampaignAction(request: request, params: params)
        })

        // Dismiss the "needs linking" warning/DM for a specific game.
        await router.register(HTTPRoute(method: "POST", pattern: "/v1/users/:discordUserId/link-warnings/:game/ignore") { request, params in
            await routes.handleIgnoreLinkWarning(request: request, params: params)
        })

        await router.register(HTTPRoute(method: "POST", pattern: "/v1/users/:discordUserId/link-warnings/:game/pause") { request, params in
            await routes.handlePauseLinkWarning(request: request, params: params)
        })

        await router.register(HTTPRoute(method: "POST", pattern: "/v1/users/:discordUserId/miner/:action") { request, params in
            await routes.handleMinerControl(request: request, params: params)
        })

        await router.register(HTTPRoute(method: "POST", pattern: "/v1/users/:discordUserId/miners/:accountId/priorities") { request, params in
            await routes.handleUpdatePriorities(request: request, params: params)
        })

        await router.register(HTTPRoute(method: "PUT", pattern: "/v1/users/:discordUserId/miners/:accountId/priorities") { request, params in
            await routes.handleSetPriorities(request: request, params: params)
        })
    }

    // MARK: - Handlers

    private func handleGetUsers(request: HTTPRequest, params: [String: String]) async -> HTTPResponse {
        let users = await adminLinkingService.getAllUsers()
        let payload = users.map {
            UserListItem(
                discordId: $0.discordId,
                status: $0.status.rawValue,
                dmState: $0.dmState
            )
        }
        return HTTPResponse.json(["users": payload])
    }

    private func handleRegisterUser(request: HTTPRequest, params: [String: String]) async -> HTTPResponse {
        guard !request.body.isEmpty,
              let body = try? JSONDecoder().decode(RegisterUserRequest.self, from: request.body) else {
            return .error(code: "invalid_payload", message: "Body must include discordUserId.", statusCode: 400)
        }

        let result = await adminLinkingService.registerUser(
            discordId: body.discordUserId,
            operatorIdentity: .bot(apiKeyId: String(apiKey.prefix(8)))
        )

        switch result {
        case .registered(let discordId):
            return HTTPResponse.json(UserRegistrationResponse(
                discordUserId: discordId,
                status: "registered",
                dmState: DiscordDMState()
            ), statusCode: 201)
        case .alreadyRegistered(let discordId):
            let dmState = await fetchDMState(discordUserId: discordId)
            return HTTPResponse.json(UserRegistrationResponse(
                discordUserId: discordId,
                status: "already_registered",
                dmState: dmState
            ), statusCode: 200)
        case .invalidDiscordId:
            return .error(code: "invalid_discord_id", message: "Discord ID must be 17-19 numeric digits.", statusCode: 400)
        case .internalError(let message):
            return .error(code: "internal_error", message: message, statusCode: 500)
        }
    }

    private func handleUpdateDMState(request: HTTPRequest, params: [String: String]) async -> HTTPResponse {
        guard let discordUserId = params["discordUserId"],
              Self.isValidDiscordId(discordUserId) else {
            return .error(code: "invalid_discord_id", message: "Discord ID must be 17-19 numeric digits.", statusCode: 400)
        }

        guard !request.body.isEmpty,
              let body = try? JSONDecoder().decode(UpdateDMStateRequest.self, from: request.body) else {
            return .error(code: "invalid_payload", message: "Body must include DM state fields.", statusCode: 400)
        }

        guard await userExists(discordUserId: discordUserId) else {
            return .error(code: "user_not_found", message: "User not found.", statusCode: 404)
        }

        do {
            try await updateDMState(discordUserId: discordUserId, update: body)
            return HTTPResponse.json(DMStateResponse(
                discordUserId: discordUserId,
                dmState: await fetchDMState(discordUserId: discordUserId)
            ))
        } catch {
            return .error(code: "internal_error", message: "Failed to update DM state: \(error.localizedDescription)", statusCode: 500)
        }
    }

    private func handleGetProjection(request: HTTPRequest, params: [String: String]) async -> HTTPResponse {
        guard let discordUserId = params["discordUserId"],
              discordUserId.count >= 17, discordUserId.count <= 19,
              discordUserId.allSatisfy({ $0.isNumber }) else {
            return .error(code: "invalid_discord_id", message: "Discord ID must be 17-19 numeric digits.", statusCode: 400)
        }

        guard let projection = await projectionBuilder.buildProjection(discordUserId: discordUserId) else {
            return .error(code: "user_not_found", message: "User not found.", statusCode: 404)
        }

        return HTTPResponse.json(projection)
    }

    private func handleStartActivation(request: HTTPRequest, params: [String: String]) async -> HTTPResponse {
        guard let discordUserId = params["discordUserId"],
              discordUserId.count >= 17, discordUserId.count <= 19,
              discordUserId.allSatisfy({ $0.isNumber }) else {
            return .error(code: "invalid_discord_id", message: "Discord ID must be 17-19 numeric digits.", statusCode: 400)
        }

        guard let authService else {
            return .error(code: "activation_unavailable", message: "Activation flow is not configured on this SwiftMiner instance.", statusCode: 503)
        }

        // Verify user exists
        let userExists = await self.userExists(discordUserId: discordUserId)
        guard userExists else {
            return .error(code: "user_not_found", message: "User not found. Register first.", statusCode: 404)
        }

        // Check if already linked
        let alreadyLinked = await self.hasLinkedAccount(discordUserId: discordUserId)
        guard !alreadyLinked else {
            return .error(code: "account_already_linked", message: "A Twitch account is already linked to this Discord user.", statusCode: 409)
        }

        // Reuse a valid pending session for the same Discord user
        if let existing = activationSessions.values.first(where: {
            $0.discordUserId == discordUserId && $0.status == .pending && $0.expiresAt > Date()
        }) {
            return HTTPResponse.json(existing.toResponse(), statusCode: 200)
        }

        // Hit Twitch for a real device code
        let deviceResponse: DeviceCodeResponse
        do {
            deviceResponse = try await authService.initiateDeviceFlow()
        } catch {
            return .error(code: "twitch_unavailable", message: "Could not start Twitch device flow: \(error.localizedDescription)", statusCode: 502)
        }

        let sessionId = UUID().uuidString
        // Embed the user code in the verification URL so the user only has to click.
        var verificationUri = deviceResponse.verificationURI.absoluteString
        if !verificationUri.contains("device-code=") {
            let separator = verificationUri.contains("?") ? "&" : "?"
            verificationUri += "\(separator)device-code=\(deviceResponse.userCode)"
        }
        let expiresAt = Date().addingTimeInterval(TimeInterval(deviceResponse.expiresIn))

        let session = ActivationSession(
            sessionId: sessionId,
            discordUserId: discordUserId,
            userCode: deviceResponse.userCode,
            deviceCode: deviceResponse.deviceCode,
            verificationUri: verificationUri,
            expiresAt: expiresAt,
            intervalSeconds: deviceResponse.interval,
            status: .pending
        )
        activationSessions[sessionId] = session
        await self.persistActivationSession(session)

        // Kick off background polling — the user will authorize in the browser, and once
        // Twitch returns a token we link the account to the Discord user automatically.
        startPolling(sessionId: sessionId, deviceCode: deviceResponse.deviceCode, interval: deviceResponse.interval, discordUserId: discordUserId)

        return HTTPResponse.json(session.toResponse(), statusCode: 201)
    }

    private func startPolling(sessionId: String, deviceCode: String, interval: Int, discordUserId: String) {
        guard let authService else { return }
        let task = Task { [weak self] in
            do {
                let account = try await authService.pollForToken(deviceCode: deviceCode, interval: interval)
                await self?.handleActivationSuccess(sessionId: sessionId, account: account, discordUserId: discordUserId)
            } catch {
                await self?.handleActivationFailure(sessionId: sessionId, reason: error.localizedDescription)
            }
        }
        activationPollTasks[sessionId] = task
    }

    private func handleActivationSuccess(sessionId: String, account: Account, discordUserId: String) async {
        // Make sure the row exists in twitch_accounts (the auth service persisted to the
        // token store, but assignAccount queries SQLite).
        await adminLinkingService.upsertAccountIdentity(twitchId: account.id, username: account.username, isOperator: false)
        let assignment = AdminAccountAssignment(
            twitchAccountId: account.id,
            discordId: discordUserId,
            operatorIdentity: .bot(apiKeyId: String(apiKey.prefix(8)))
        )
        _ = await adminLinkingService.assignAccount(assignment, policy: .rejectIfOwned)

        await onAccountActivated?(account, discordUserId)

        if var session = activationSessions[sessionId] {
            session.status = .authorized
            session.linkedAccountId = account.id
            session.twitchUsername = account.username
            activationSessions[sessionId] = session
        }
        activationPollTasks.removeValue(forKey: sessionId)
    }

    private func handleActivationFailure(sessionId: String, reason: String) async {
        if var session = activationSessions[sessionId] {
            session.status = .failed
            session.failureReason = reason
            activationSessions[sessionId] = session
        }
        activationPollTasks.removeValue(forKey: sessionId)
    }

    private func handleGetActivationStatus(request: HTTPRequest, params: [String: String]) async -> HTTPResponse {
        guard let sessionId = params["sessionId"] else {
            return .error(code: "bad_request", message: "Missing session ID.", statusCode: 400)
        }

        guard let session = activationSessions[sessionId] else {
            return .error(code: "session_not_found", message: "Session not found.", statusCode: 404)
        }

        // Auto-expire
        var mutableSession = session
        if mutableSession.status == .pending && mutableSession.expiresAt < Date() {
            mutableSession.status = .expired
            activationSessions[sessionId] = mutableSession
        }

        return HTTPResponse.json(mutableSession.toStatusResponse())
    }

    private func handleCancelActivation(request: HTTPRequest, params: [String: String]) async -> HTTPResponse {
        guard let sessionId = params["sessionId"] else {
            return .error(code: "bad_request", message: "Missing session ID.", statusCode: 400)
        }

        guard activationSessions[sessionId] != nil else {
            return .error(code: "session_not_found", message: "Session not found.", statusCode: 404)
        }

        activationPollTasks[sessionId]?.cancel()
        activationPollTasks.removeValue(forKey: sessionId)
        activationSessions.removeValue(forKey: sessionId)
        return HTTPResponse(statusCode: 204)
    }

    private func handleIgnoreLinkWarning(request: HTTPRequest, params: [String: String]) async -> HTTPResponse {
        guard let discordUserId = params["discordUserId"],
              let rawGame = params["game"] else {
            return .error(code: "bad_request", message: "Missing path parameters.", statusCode: 400)
        }
        let gameName = rawGame.removingPercentEncoding ?? rawGame
        guard !gameName.isEmpty else {
            return .error(code: "bad_request", message: "Game name is required.", statusCode: 400)
        }

        guard let handler = onIgnoreLinkWarning else {
            return .error(code: "unavailable", message: "SwiftMiner is not available.", statusCode: 503)
        }

        let ignored = await handler(discordUserId, gameName)
        struct IgnoreLinkWarningResponse: Codable { let ignored: Bool; let game: String }
        return HTTPResponse.json(IgnoreLinkWarningResponse(ignored: ignored, game: gameName))
    }

    private func handlePauseLinkWarning(request: HTTPRequest, params: [String: String]) async -> HTTPResponse {
        guard let discordUserId = params["discordUserId"],
              Self.isValidDiscordId(discordUserId),
              let rawGame = params["game"] else {
            return .error(code: "bad_request", message: "Missing path parameters.", statusCode: 400)
        }
        let gameName = rawGame.removingPercentEncoding ?? rawGame
        guard !gameName.isEmpty else {
            return .error(code: "bad_request", message: "Game name is required.", statusCode: 400)
        }

        guard await userExists(discordUserId: discordUserId) else {
            return .error(code: "user_not_found", message: "User not found. Register first.", statusCode: 404)
        }

        let days: Int
        if request.body.isEmpty {
            days = 7
        } else if let body = try? JSONDecoder().decode(PauseLinkWarningRequest.self, from: request.body) {
            days = min(max(body.days, 1), 30)
        } else {
            return .error(code: "invalid_payload", message: "Body must include an integer days value.", statusCode: 400)
        }

        guard let handler = onPauseLinkWarning else {
            return .error(code: "unavailable", message: "SwiftMiner is not available.", statusCode: 503)
        }

        let expiresAt = Date().addingTimeInterval(TimeInterval(days * 24 * 60 * 60))
        let paused = await handler(discordUserId, gameName, expiresAt)
        return HTTPResponse.json(PauseLinkWarningResponse(paused: paused, game: gameName, expiresAt: expiresAt))
    }

    private func handleCampaignAction(request: HTTPRequest, params: [String: String]) async -> HTTPResponse {
        guard let discordUserId = params["discordUserId"],
              let campaignId = params["campaignId"],
              let action = params["action"] else {
            return .error(code: "bad_request", message: "Missing path parameters.", statusCode: 400)
        }

        // Parse body for scope
        var scope = "campaign"
        if !request.body.isEmpty,
           let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] {
            if let s = json["scope"] as? String {
                scope = s
            }
        }

        let decision: String
        let decisionScope: String

        switch action {
        case "ignore":
            decision = "ignored"
            decisionScope = scope == "game" ? "permanent" : "temporary"
        case "prioritise":
            decision = "prioritised"
            decisionScope = "temporary"
        default:
            return .error(code: "invalid_action", message: "Action must be 'ignore' or 'prioritise'.", statusCode: 400)
        }

        do {
            try await persistCampaignDecision(
                discordUserId: discordUserId,
                campaignId: campaignId,
                decision: decision,
                scope: decisionScope
            )
            
            if action == "ignore" {
                struct IgnoreResponse: Codable { let ignored: Bool; let scope: String }
                return HTTPResponse.json(IgnoreResponse(ignored: true, scope: scope))
            } else {
                struct PrioritiseResponse: Codable { let prioritised: Bool }
                return HTTPResponse.json(PrioritiseResponse(prioritised: true))
            }
        } catch {
            return .error(code: "internal_error", message: "Failed to persist decision: \(error.localizedDescription)", statusCode: 500)
        }
    }

    private func handleMinerControl(request: HTTPRequest, params: [String: String]) async -> HTTPResponse {
        guard let discordUserId = params["discordUserId"],
              Self.isValidDiscordId(discordUserId),
              let actionValue = params["action"],
              let action = MinerControlAction(rawValue: actionValue) else {
            return .error(code: "invalid_action", message: "Action must be status, pause, resume, or refresh.", statusCode: 400)
        }

        guard await userExists(discordUserId: discordUserId) else {
            return .error(code: "user_not_found", message: "User not found. Register first.", statusCode: 404)
        }

        guard let onMinerControl else {
            return .error(code: "control_unavailable", message: "Miner controls are not available.", statusCode: 503)
        }

        let response = await onMinerControl(discordUserId, action)
        return HTTPResponse.json(response, statusCode: response.ok ? 200 : 409)
    }

    private func handleUpdatePriorities(request: HTTPRequest, params: [String: String]) async -> HTTPResponse {
        guard let discordUserId = params["discordUserId"],
              Self.isValidDiscordId(discordUserId),
              let rawAccountId = params["accountId"] else {
            return .error(code: "bad_request", message: "Missing path parameters.", statusCode: 400)
        }
        let accountId = rawAccountId.removingPercentEncoding ?? rawAccountId
        guard !accountId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .error(code: "bad_request", message: "Account ID is required.", statusCode: 400)
        }
        guard !request.body.isEmpty,
              let body = try? JSONDecoder().decode(UpdatePriorityRequest.self, from: request.body) else {
            return .error(code: "invalid_payload", message: "Body must include game_name.", statusCode: 400)
        }
        let gameName = body.gameName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !gameName.isEmpty else {
            return .error(code: "invalid_payload", message: "Game name is required.", statusCode: 400)
        }
        guard (body.placement ?? "top") == "top" else {
            return .error(code: "invalid_payload", message: "Only placement 'top' is supported.", statusCode: 400)
        }
        guard await userExists(discordUserId: discordUserId) else {
            return .error(code: "user_not_found", message: "User not found. Register first.", statusCode: 404)
        }
        guard let handler = onPrioritiseGame else {
            return .error(code: "unavailable", message: "Priority controls are not available.", statusCode: 503)
        }
        guard let priorities = await handler(discordUserId, accountId, gameName) else {
            return .error(code: "account_not_found", message: "No linked miner account was found for this Discord user.", statusCode: 404)
        }
        return HTTPResponse.json(PriorityUpdateResponse(
            prioritised: true,
            accountId: accountId,
            gameName: gameName,
            priorityGames: priorities
        ))
    }

    private func handleSetPriorities(request: HTTPRequest, params: [String: String]) async -> HTTPResponse {
        guard let discordUserId = params["discordUserId"],
              Self.isValidDiscordId(discordUserId),
              let rawAccountId = params["accountId"] else {
            return .error(code: "bad_request", message: "Missing path parameters.", statusCode: 400)
        }
        let accountId = rawAccountId.removingPercentEncoding ?? rawAccountId
        guard !accountId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .error(code: "bad_request", message: "Account ID is required.", statusCode: 400)
        }
        guard !request.body.isEmpty,
              let body = try? JSONDecoder().decode(SetPrioritiesRequest.self, from: request.body) else {
            return .error(code: "invalid_payload", message: "Body must include games.", statusCode: 400)
        }
        guard await userExists(discordUserId: discordUserId) else {
            return .error(code: "user_not_found", message: "User not found. Register first.", statusCode: 404)
        }
        guard let handler = onSetPriorities else {
            return .error(code: "unavailable", message: "Priority controls are not available.", statusCode: 503)
        }
        guard let priorities = await handler(discordUserId, accountId, body.games, body.includeGlobalPriorities, body.prioritySource) else {
            return .error(code: "account_not_found", message: "No linked miner account was found for this Discord user.", statusCode: 404)
        }
        return HTTPResponse.json(PrioritiesResponse(accountId: accountId, priorityGames: priorities, includeGlobalPriorities: body.includeGlobalPriorities ?? true))
    }

    // MARK: - Web Dashboard Delegation
    //
    // These public entry points exist solely for the self-service web dashboard.
    // Every one of them takes the Discord ID *from the caller's authenticated
    // session* (never from a request path) and reuses the exact same handler
    // logic as the Bot-key API, so authorization is centralised. Nested ids
    // (`accountId`, activation `sessionId`) are additionally verified to belong
    // to the session owner here, as defense in depth.

    /// Whether a Discord user is registered. Used by the web layer to decide
    /// between onboarding and the dashboard.
    public func webUserExists(discordId: String) async -> Bool {
        await userExists(discordUserId: discordId)
    }

    /// Idempotently register the session's own Discord user (web-first onboarding).
    public func webSelfRegister(discordId: String) async -> Bool {
        let result = await adminLinkingService.registerUser(
            discordId: discordId,
            operatorIdentity: .web(discordId: discordId)
        )
        switch result {
        case .registered, .alreadyRegistered: return true
        case .invalidDiscordId, .internalError: return false
        }
    }

    public func webProjection(discordId: String) async -> HTTPResponse {
        await handleGetProjection(request: emptyRequest(), params: ["discordUserId": discordId])
    }

    public func webCampaignAction(discordId: String, campaignId: String, action: String, body: Data) async -> HTTPResponse {
        await handleCampaignAction(
            request: emptyRequest(body: body),
            params: ["discordUserId": discordId, "campaignId": campaignId, "action": action]
        )
    }

    public func webSetPriorities(discordId: String, accountId: String, body: Data) async -> HTTPResponse {
        guard await ownsAccount(discordId: discordId, accountId: accountId) else {
            return .error(code: "account_not_found", message: "No linked miner account was found for this user.", statusCode: 404)
        }
        return await handleSetPriorities(
            request: emptyRequest(body: body),
            params: ["discordUserId": discordId, "accountId": accountId]
        )
    }

    public func webStartActivation(discordId: String) async -> HTTPResponse {
        await handleStartActivation(request: emptyRequest(), params: ["discordUserId": discordId])
    }

    /// Activation polling scoped to the session owner. Returns 404 for any
    /// session that is not owned by this Discord user, preventing cross-user
    /// disclosure of another person's Twitch activation/username.
    public func webActivationStatus(discordId: String, sessionId: String) async -> HTTPResponse {
        guard activationSessions[sessionId]?.discordUserId == discordId else {
            return .error(code: "session_not_found", message: "Session not found.", statusCode: 404)
        }
        return await handleGetActivationStatus(request: emptyRequest(), params: ["sessionId": sessionId])
    }

    public func webCancelActivation(discordId: String, sessionId: String) async -> HTTPResponse {
        guard activationSessions[sessionId]?.discordUserId == discordId else {
            return .error(code: "session_not_found", message: "Session not found.", statusCode: 404)
        }
        return await handleCancelActivation(request: emptyRequest(), params: ["sessionId": sessionId])
    }

    private func ownsAccount(discordId: String, accountId: String) async -> Bool {
        await manager.ownerDiscordId(forTwitchAccount: accountId) == discordId
    }

    public func webVerifiesDiscordOwnership(discordId: String, accountId: String) async -> Bool {
        await ownsAccount(discordId: discordId, accountId: accountId)
    }

    public func hasMinerControlByAccount() async -> Bool {
        onMinerControlByAccount != nil
    }

    public func executeMinerControlByAccount(accountId: String, action: MinerControlAction) async -> MinerControlResponse {
        guard let onMinerControlByAccount else {
            return MinerControlResponse(ok: false, action: action.rawValue, state: "unavailable", twitchUsername: nil, message: "Miner controls are not available.")
        }
        return await onMinerControlByAccount(accountId, action)
    }

    public func removeMinerByAccount(accountId: String) async -> Bool {
        guard let onRemoveMinerByAccount else { return false }
        return await onRemoveMinerByAccount(accountId)
    }

    // MARK: - Web Dashboard Delegation (Twitch principal)
    //
    // For Twitch-authenticated sessions the principal *is* the mined account, so
    // there is no Discord owner to resolve and no nested id to forge — the
    // account id comes straight from the verified session.

    public func webProjectionTwitch(twitchId: String) async -> HTTPResponse {
        guard let projection = await projectionBuilder.buildProjection(twitchId: twitchId) else {
            return .error(code: "miner_not_found", message: "No miner is running for this Twitch account.", statusCode: 404)
        }
        return HTTPResponse.json(projection)
    }

    public func isOperatorTwitch(twitchId: String) async -> Bool {
        return await manager.isOperatorTwitchAccount(twitchId: twitchId)
    }

    public func isOperatorDiscord(discordId: String) async -> Bool {
        return await manager.isOperatorDiscordUser(discordId: discordId)
    }

    /// Operator overview: a projection per mined account. Used by a local
    /// (username/password) session, which represents the host, not one user.
    public func webOverview() async -> HTTPResponse {
        let ids = await manager.allTwitchAccountIds()
        var projections: [DiscordUserProjection] = []
        for id in ids {
            if let p = await projectionBuilder.buildProjection(twitchId: id) {
                projections.append(p)
            }
        }
        let totalMiners = projections.count
        let activeMiners = projections.filter { $0.state == .active }.count
        let claimsToday = await manager.fetchClaimsCountToday()

        struct Overview: Encodable {
            let miners: [DiscordUserProjection]
            let totalMiners: Int
            let activeMiners: Int
            let claimsToday: Int
        }
        return HTTPResponse.json(Overview(
            miners: projections,
            totalMiners: totalMiners,
            activeMiners: activeMiners,
            claimsToday: claimsToday
        ))
    }

    public func webSetPrioritiesTwitch(twitchId: String, body: Data) async -> HTTPResponse {
        guard !body.isEmpty,
              let decoded = try? JSONDecoder().decode(SetPrioritiesRequest.self, from: body) else {
            return .error(code: "invalid_payload", message: "Body must include games.", statusCode: 400)
        }
        guard let handler = onSetPrioritiesByAccount else {
            return .error(code: "unavailable", message: "Priority controls are not available.", statusCode: 503)
        }
        guard let priorities = await handler(twitchId, decoded.games, decoded.includeGlobalPriorities, decoded.prioritySource) else {
            return .error(code: "account_not_found", message: "No miner was found for this Twitch account.", statusCode: 404)
        }
        return HTTPResponse.json(PrioritiesResponse(accountId: twitchId, priorityGames: priorities, includeGlobalPriorities: decoded.includeGlobalPriorities ?? true))
    }

    private func emptyRequest(body: Data = Data()) -> HTTPRequest {
        HTTPRequest(method: "POST", path: "", headers: [:], body: body)
    }

    // MARK: - DB Helpers

    private func persistCampaignDecision(discordUserId: String, campaignId: String, decision: String, scope: String) async throws {
        try await manager.execute { db in
            let sql = """
            INSERT INTO user_campaign_decisions (discord_id, campaign_id, decision, scope)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(discord_id, campaign_id) DO UPDATE SET
                decision = excluded.decision,
                scope = excluded.scope,
                created_at = CURRENT_TIMESTAMP;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                let msg = String(cString: sqlite3_errmsg(db))
                throw NSError(domain: "DiscordAPIRoutes", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, discordUserId, -1, SQLITE_TRANSIENT_ROUTES)
            sqlite3_bind_text(stmt, 2, campaignId, -1, SQLITE_TRANSIENT_ROUTES)
            sqlite3_bind_text(stmt, 3, decision, -1, SQLITE_TRANSIENT_ROUTES)
            sqlite3_bind_text(stmt, 4, scope, -1, SQLITE_TRANSIENT_ROUTES)
            
            if sqlite3_step(stmt) != SQLITE_DONE {
                let msg = String(cString: sqlite3_errmsg(db))
                throw NSError(domain: "DiscordAPIRoutes", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
            }
        }
    }

    private func userExists(discordUserId: String) async -> Bool {
        do {
            return try await manager.query { db in
                let sql = "SELECT 1 FROM miner_users WHERE discord_id = ?;"
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, discordUserId, -1, SQLITE_TRANSIENT_ROUTES)
                return sqlite3_step(stmt) == SQLITE_ROW
            }
        } catch { return false }
    }

    private func fetchDMState(discordUserId: String) async -> DiscordDMState {
        do {
            return try await manager.query { db in
                let sql = """
                SELECT has_received_welcome_message, has_completed_initial_dm_flow
                FROM miner_users
                WHERE discord_id = ?;
                """
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    return DiscordDMState()
                }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, discordUserId, -1, SQLITE_TRANSIENT_ROUTES)
                guard sqlite3_step(stmt) == SQLITE_ROW else {
                    return DiscordDMState()
                }
                return DiscordDMState(
                    hasReceivedWelcomeMessage: sqlite3_column_int(stmt, 0) != 0,
                    hasCompletedInitialDMFlow: sqlite3_column_int(stmt, 1) != 0
                )
            }
        } catch {
            return DiscordDMState()
        }
    }

    private func updateDMState(discordUserId: String, update: UpdateDMStateRequest) async throws {
        try await manager.execute { db in
            let current = try currentDMState(discordUserId: discordUserId, db: db)
            let nextWelcome = update.hasReceivedWelcomeMessage ?? current.hasReceivedWelcomeMessage
            let nextInitialFlow = update.hasCompletedInitialDMFlow ?? current.hasCompletedInitialDMFlow
            let sql = """
            UPDATE miner_users
            SET has_received_welcome_message = ?, has_completed_initial_dm_flow = ?
            WHERE discord_id = ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                let msg = String(cString: sqlite3_errmsg(db))
                throw NSError(domain: "DiscordAPIRoutes", code: 3, userInfo: [NSLocalizedDescriptionKey: msg])
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, nextWelcome ? 1 : 0)
            sqlite3_bind_int(stmt, 2, nextInitialFlow ? 1 : 0)
            sqlite3_bind_text(stmt, 3, discordUserId, -1, SQLITE_TRANSIENT_ROUTES)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                let msg = String(cString: sqlite3_errmsg(db))
                throw NSError(domain: "DiscordAPIRoutes", code: 4, userInfo: [NSLocalizedDescriptionKey: msg])
            }
        }
    }

    nonisolated private func currentDMState(discordUserId: String, db: OpaquePointer?) throws -> DiscordDMState {
        let sql = """
        SELECT has_received_welcome_message, has_completed_initial_dm_flow
        FROM miner_users
        WHERE discord_id = ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "DiscordAPIRoutes", code: 5, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, discordUserId, -1, SQLITE_TRANSIENT_ROUTES)
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return DiscordDMState()
        }
        return DiscordDMState(
            hasReceivedWelcomeMessage: sqlite3_column_int(stmt, 0) != 0,
            hasCompletedInitialDMFlow: sqlite3_column_int(stmt, 1) != 0
        )
    }

    private func hasLinkedAccount(discordUserId: String) async -> Bool {
        do {
            return try await manager.query { db in
                let sql = "SELECT 1 FROM twitch_accounts WHERE owner_discord_id = ? LIMIT 1;"
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, discordUserId, -1, SQLITE_TRANSIENT_ROUTES)
                return sqlite3_step(stmt) == SQLITE_ROW
            }
        } catch { return false }
    }

    private func persistActivationSession(_ session: ActivationSession) async {
        do {
            try await manager.execute { db in
                let sql = """
                INSERT INTO oauth_link_sessions (id, discord_id, state_nonce, expires_at)
                VALUES (?, ?, ?, ?);
                """
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, session.sessionId, -1, SQLITE_TRANSIENT_ROUTES)
                sqlite3_bind_text(stmt, 2, session.discordUserId, -1, SQLITE_TRANSIENT_ROUTES)
                sqlite3_bind_text(stmt, 3, session.userCode, -1, SQLITE_TRANSIENT_ROUTES)
                let dateFormatter = ISO8601DateFormatter()
                let expiresString = dateFormatter.string(from: session.expiresAt)
                sqlite3_bind_text(stmt, 4, expiresString, -1, SQLITE_TRANSIENT_ROUTES)
                sqlite3_step(stmt)
            }
        } catch {}
    }

    // MARK: - Utilities

    private static func generateUserCode() -> String {
        let chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        var code = ""
        for i in 0..<8 {
            code.append(chars.randomElement()!)
            if i == 3 { code.append("-") }
        }
        return code
    }

    private static func isValidDiscordId(_ discordUserId: String) -> Bool {
        discordUserId.count >= 17 && discordUserId.count <= 19 && discordUserId.allSatisfy(\.isNumber)
    }
}

private let SQLITE_TRANSIENT_ROUTES = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private struct UserListItem: Codable {
    let discordId: String
    let status: String
    let dmState: DiscordDMState

    enum CodingKeys: String, CodingKey {
        case discordId = "discord_id"
        case status
        case dmState = "dm_state"
    }
}

private struct UserRegistrationResponse: Codable {
    let discordUserId: String
    let status: String
    let dmState: DiscordDMState

    enum CodingKeys: String, CodingKey {
        case discordUserId = "discord_user_id"
        case status
        case dmState = "dm_state"
    }
}

private struct DMStateResponse: Codable {
    let discordUserId: String
    let dmState: DiscordDMState

    enum CodingKeys: String, CodingKey {
        case discordUserId = "discord_user_id"
        case dmState = "dm_state"
    }
}

public enum MinerControlAction: String, Codable, Sendable {
    case status
    case pause
    case resume
    case refresh
}

public struct MinerControlResponse: Codable, Sendable {
    public let ok: Bool
    public let action: String
    public let state: String
    public let twitchUsername: String?
    public let message: String

    public init(ok: Bool, action: String, state: String, twitchUsername: String?, message: String) {
        self.ok = ok
        self.action = action
        self.state = state
        self.twitchUsername = twitchUsername
        self.message = message
    }
}
