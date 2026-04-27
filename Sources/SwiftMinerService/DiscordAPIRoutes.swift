import Foundation
import SQLite3
import SwiftMinerCore

// MARK: - Activation Session Model

struct ActivationSession: Sendable {
    let sessionId: String
    let discordUserId: String
    let userCode: String
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

// MARK: - API Routes

public actor DiscordAPIRoutes {
    private let manager: SQLiteManager
    private let projectionBuilder: DiscordProjectionBuilder
    private let apiKey: String

    // In-memory activation session store (ephemeral; DB retains audit rows)
    private var activationSessions: [String: ActivationSession] = [:]

    public init(manager: SQLiteManager, projectionBuilder: DiscordProjectionBuilder, apiKey: String) {
        self.manager = manager
        self.projectionBuilder = projectionBuilder
        self.apiKey = apiKey
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
    }

    // MARK: - Handlers

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

        // Check for existing pending session
        let existingPending = activationSessions.values.first { $0.discordUserId == discordUserId && $0.status == .pending && $0.expiresAt > Date() }
        if let existing = existingPending {
            return HTTPResponse.json(existing.toResponse(), statusCode: 200)
        }

        // Create new session
        let sessionId = UUID().uuidString
        let userCode = Self.generateUserCode()
        let verificationUri = "https://www.twitch.tv/activate"
        let intervalSeconds = 5
        let expiresAt = Date().addingTimeInterval(600) // 10 minutes

        let session = ActivationSession(
            sessionId: sessionId,
            discordUserId: discordUserId,
            userCode: userCode,
            verificationUri: verificationUri,
            expiresAt: expiresAt,
            intervalSeconds: intervalSeconds,
            status: .pending
        )
        activationSessions[sessionId] = session

        // Persist audit row in oauth_link_sessions
        await self.persistActivationSession(session)

        return HTTPResponse.json(session.toResponse(), statusCode: 201)
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
}

private let SQLITE_TRANSIENT_ROUTES = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
