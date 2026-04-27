import Foundation
import SQLite3
import SwiftMinerCore

// MARK: - Runtime State Provider

/// Protocol for injecting live engine state into the projection builder.
/// The app layer implements this to bridge `MinerEngine` / `MinerManager` runtime data.
public protocol ProjectionStateProvider: Sendable {
    /// Returns the active campaign for a Discord user, if any.
    func activeCampaign(for discordUserId: String) async -> DiscordUserProjection.ActiveCampaign?
    /// Returns the next upcoming campaign for a Discord user, if any.
    func upNext(for discordUserId: String) async -> DiscordUserProjection.UpNext?
    /// Overrides the projection state derived from DB heuristics. Return `nil` to use DB fallback.
    func projectionState(for discordUserId: String) async -> DiscordUserProjection.ProjectionState?
}

/// Default no-op provider. All state is derived from DB queries alone.
public struct DefaultProjectionStateProvider: ProjectionStateProvider {
    public init() {}
    public func activeCampaign(for discordUserId: String) async -> DiscordUserProjection.ActiveCampaign? { nil }
    public func upNext(for discordUserId: String) async -> DiscordUserProjection.UpNext? { nil }
    public func projectionState(for discordUserId: String) async -> DiscordUserProjection.ProjectionState? { nil }
}

// MARK: - Builder

/// Builds `DiscordUserProjection` from SQLite + optional runtime state provider.
public actor DiscordProjectionBuilder {
    private let manager: SQLiteManager
    private let stateProvider: ProjectionStateProvider

    public init(manager: SQLiteManager, stateProvider: ProjectionStateProvider = DefaultProjectionStateProvider()) {
        self.manager = manager
        self.stateProvider = stateProvider
    }

    /// Build a projection for the given Discord user ID.
    /// Returns `nil` if the user is not registered in `miner_users`.
    public func buildProjection(discordUserId: String) async -> DiscordUserProjection? {
        guard await userExists(discordUserId: discordUserId) else {
            return nil
        }

        let account = await fetchAccount(discordUserId: discordUserId)
        let issues = await fetchIssues(discordUserId: discordUserId)
        let activeCampaign = await stateProvider.activeCampaign(for: discordUserId)
        let upNext = await stateProvider.upNext(for: discordUserId)

        let state: DiscordUserProjection.ProjectionState
        if let providerState = await stateProvider.projectionState(for: discordUserId) {
            state = providerState
        } else if account == nil {
            state = .notConfigured
        } else if !issues.isEmpty {
            state = .blocked
        } else if activeCampaign != nil {
            state = .active
        } else {
            state = .idle
        }

        return DiscordUserProjection(
            discordUserId: discordUserId,
            state: state,
            account: account,
            activeCampaign: activeCampaign,
            upNext: upNext,
            issues: issues
        )
    }

    // MARK: - DB Queries

    private func userExists(discordUserId: String) async -> Bool {
        do {
            return try await manager.query { db in
                let sql = "SELECT 1 FROM miner_users WHERE discord_id = ?;"
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, discordUserId, -1, SQLITE_TRANSIENT_BUILDER)
                return sqlite3_step(stmt) == SQLITE_ROW
            }
        } catch {
            return false
        }
    }

    private func fetchAccount(discordUserId: String) async -> DiscordUserProjection.Account? {
        do {
            return try await manager.query { db in
                let sql = "SELECT twitch_id, username FROM twitch_accounts WHERE owner_discord_id = ? LIMIT 1;"
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, discordUserId, -1, SQLITE_TRANSIENT_BUILDER)
                guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
                let twitchId = String(cString: sqlite3_column_text(stmt, 0))
                let username = String(cString: sqlite3_column_text(stmt, 1))
                return DiscordUserProjection.Account(twitchAccountId: twitchId, username: username)
            }
        } catch {
            return nil
        }
    }

    private func fetchIssues(discordUserId: String) async -> [DiscordUserProjection.Issue] {
        do {
            return try await manager.query { db in
                let sql = """
                SELECT id, issue_type, message FROM user_issues
                WHERE discord_id = ?
                ORDER BY created_at DESC
                LIMIT 3;
                """
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, discordUserId, -1, SQLITE_TRANSIENT_BUILDER)

                var issues: [DiscordUserProjection.Issue] = []
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = Int(sqlite3_column_int(stmt, 0))
                    let type = String(cString: sqlite3_column_text(stmt, 1))
                    let message = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                    let action = Self.actionForIssueType(type)
                    issues.append(DiscordUserProjection.Issue(
                        issueId: "\(id)",
                        type: type,
                        campaignId: nil,
                        game: nil,
                        message: message,
                        action: action
                    ))
                }
                return issues
            }
        } catch {
            return []
        }
    }

    private static func actionForIssueType(_ type: String) -> String {
        switch type {
        case "account_not_linked":
            return "link_account"
        case "campaign_blocked", "game_blocked":
            return "ignore_campaign | ignore_game"
        default:
            return "link_account | ignore_campaign | ignore_game"
        }
    }
}

private let SQLITE_TRANSIENT_BUILDER = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
