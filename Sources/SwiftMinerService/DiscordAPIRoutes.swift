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

        await router.register(HTTPRoute(method: "POST", pattern: "/v1/users/:discordUserId/miner/:action") { request, params in
            await routes.handleMinerControl(request: request, params: params)
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
        await adminLinkingService.upsertAccountIdentity(twitchId: account.id, username: account.username)
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
