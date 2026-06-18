import Foundation
import SQLite3
import SwiftMinerCore

// MARK: - Runtime State Provider

/// Protocol for injecting live engine state into the projection builder.
/// The app layer implements this to bridge `MinerEngine` / `MinerManager` runtime data.
public protocol ProjectionStateProvider: Sendable {
    /// Returns the active campaign for a Discord user, if any.
    func activeCampaign(for discordUserId: String) async -> DiscordUserProjection.ActiveCampaign?
    /// Returns recently completed campaigns for a Discord user, newest first.
    func recentCompletedCampaigns(for discordUserId: String, limit: Int) async -> [DiscordUserProjection.RecentCampaign]
    /// Overrides the projection state derived from DB heuristics. Return `nil` to use DB fallback.
    func projectionState(for discordUserId: String) async -> DiscordUserProjection.ProjectionState?
    /// Returns the current app-level priority games, in mining order.
    func priorityGames(for discordUserId: String) async -> [String]
    /// Returns the games prioritised specifically for this user's miner, excluding the
    /// global priority list. Used by the Discord "edit games" modal.
    func personalPriorityGames(for discordUserId: String) async -> [String]
    /// Whether global priorities are appended after this user's personal list.
    func includesGlobalPriorityGames(for discordUserId: String) async -> Bool
    /// Returns live health details for a Discord user's miner, if available.
    func diagnostics(for discordUserId: String) async -> DiscordUserProjection.Diagnostics?
    /// Returns the active campaign for a mined Twitch account, if any.
    func activeCampaign(forTwitchAccount accountId: String) async -> DiscordUserProjection.ActiveCampaign?
    /// Returns recently completed campaigns for a mined Twitch account, newest first.
    func recentCompletedCampaigns(forTwitchAccount accountId: String, limit: Int) async -> [DiscordUserProjection.RecentCampaign]
    /// Overrides the projection state derived from DB heuristics for a mined Twitch account.
    func projectionState(forTwitchAccount accountId: String) async -> DiscordUserProjection.ProjectionState?
    /// Returns the current app-level priority games for a mined Twitch account.
    func priorityGames(forTwitchAccount accountId: String) async -> [String]
    /// Returns games prioritised specifically for this mined Twitch account.
    func personalPriorityGames(forTwitchAccount accountId: String) async -> [String]
    /// Whether global priorities are appended after this mined Twitch account's personal list.
    func includesGlobalPriorityGames(forTwitchAccount accountId: String) async -> Bool
    /// Returns live health details for a mined Twitch account, if available.
    func diagnostics(forTwitchAccount accountId: String) async -> DiscordUserProjection.Diagnostics?
}

public extension ProjectionStateProvider {
    func personalPriorityGames(for discordUserId: String) async -> [String] { [] }
    func includesGlobalPriorityGames(for discordUserId: String) async -> Bool { true }
    func activeCampaign(forTwitchAccount accountId: String) async -> DiscordUserProjection.ActiveCampaign? { nil }
    func recentCompletedCampaigns(forTwitchAccount accountId: String, limit: Int) async -> [DiscordUserProjection.RecentCampaign] { [] }
    func projectionState(forTwitchAccount accountId: String) async -> DiscordUserProjection.ProjectionState? { nil }
    func priorityGames(forTwitchAccount accountId: String) async -> [String] { [] }
    func personalPriorityGames(forTwitchAccount accountId: String) async -> [String] { [] }
    func includesGlobalPriorityGames(forTwitchAccount accountId: String) async -> Bool { true }
    func diagnostics(for discordUserId: String) async -> DiscordUserProjection.Diagnostics? { nil }
    func diagnostics(forTwitchAccount accountId: String) async -> DiscordUserProjection.Diagnostics? { nil }
}

/// Default no-op provider. All state is derived from DB queries alone.
public struct DefaultProjectionStateProvider: ProjectionStateProvider {
    public init() {}
    public func activeCampaign(for discordUserId: String) async -> DiscordUserProjection.ActiveCampaign? { nil }
    public func recentCompletedCampaigns(for discordUserId: String, limit: Int) async -> [DiscordUserProjection.RecentCampaign] { [] }
    public func projectionState(for discordUserId: String) async -> DiscordUserProjection.ProjectionState? { nil }
    public func priorityGames(for discordUserId: String) async -> [String] { [] }
    public func includesGlobalPriorityGames(for discordUserId: String) async -> Bool { true }
    public func diagnostics(for discordUserId: String) async -> DiscordUserProjection.Diagnostics? { nil }
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
        let activeCampaign: DiscordUserProjection.ActiveCampaign?
        let recentCompletedCampaigns: [DiscordUserProjection.RecentCampaign]
        let providerState: DiscordUserProjection.ProjectionState?
        let priorityGames: [String]
        let personalPriorityGames: [String]
        let includesGlobalPriorityGames: Bool
        let diagnostics: DiscordUserProjection.Diagnostics?
        let dropsClaimedThisWeek: Int
        if let account {
            if let accountActive = await stateProvider.activeCampaign(forTwitchAccount: account.twitchAccountId) {
                activeCampaign = accountActive
            } else {
                activeCampaign = await stateProvider.activeCampaign(for: discordUserId)
            }
            recentCompletedCampaigns = await stateProvider.recentCompletedCampaigns(forTwitchAccount: account.twitchAccountId, limit: 3)
            dropsClaimedThisWeek = await manager.fetchClaimsCount(twitchId: account.twitchAccountId, withinDays: 7)
            if let accountState = await stateProvider.projectionState(forTwitchAccount: account.twitchAccountId) {
                providerState = accountState
            } else {
                providerState = await stateProvider.projectionState(for: discordUserId)
            }
            priorityGames = await stateProvider.priorityGames(forTwitchAccount: account.twitchAccountId)
            personalPriorityGames = await stateProvider.personalPriorityGames(forTwitchAccount: account.twitchAccountId)
            includesGlobalPriorityGames = await stateProvider.includesGlobalPriorityGames(forTwitchAccount: account.twitchAccountId)
            diagnostics = await stateProvider.diagnostics(forTwitchAccount: account.twitchAccountId)
        } else {
            activeCampaign = await stateProvider.activeCampaign(for: discordUserId)
            recentCompletedCampaigns = await stateProvider.recentCompletedCampaigns(for: discordUserId, limit: 3)
            dropsClaimedThisWeek = 0
            providerState = await stateProvider.projectionState(for: discordUserId)
            priorityGames = await stateProvider.priorityGames(for: discordUserId)
            personalPriorityGames = await stateProvider.personalPriorityGames(for: discordUserId)
            includesGlobalPriorityGames = await stateProvider.includesGlobalPriorityGames(for: discordUserId)
            diagnostics = await stateProvider.diagnostics(for: discordUserId)
        }
        let dmState = await fetchDMState(discordUserId: discordUserId)

        let state: DiscordUserProjection.ProjectionState
        if let providerState {
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
            recentCompletedCampaigns: recentCompletedCampaigns,
            dropsClaimedThisWeek: dropsClaimedThisWeek,
            issues: issues,
            dmState: dmState,
            priorityGames: priorityGames,
            personalPriorityGames: personalPriorityGames,
            includesGlobalPriorityGames: includesGlobalPriorityGames,
            diagnostics: diagnostics
        )
    }

    /// Build a projection for a Twitch-authenticated principal, keyed on the
    /// mined account directly. Works whether or not the account has a Discord
    /// owner. Returns `nil` if SwiftMiner doesn't mine this Twitch account.
    public func buildProjection(twitchId: String) async -> DiscordUserProjection? {
        guard let acct = await manager.twitchAccount(twitchId: twitchId) else {
            return nil
        }
        let ownerDiscordId = acct.ownerDiscordId

        let account = DiscordUserProjection.Account(twitchAccountId: twitchId, username: acct.username)
        // Issues / DM state are Discord-keyed; only present if the account is linked.
        let issues = ownerDiscordId != nil ? await fetchIssues(discordUserId: ownerDiscordId!) : []
        let dmState = ownerDiscordId != nil ? await fetchDMState(discordUserId: ownerDiscordId!) : DiscordDMState()

        let activeCampaign = await stateProvider.activeCampaign(forTwitchAccount: twitchId)
        let recentCompletedCampaigns = await stateProvider.recentCompletedCampaigns(forTwitchAccount: twitchId, limit: 3)
        let dropsClaimedThisWeek = await manager.fetchClaimsCount(twitchId: twitchId, withinDays: 7)
        let priorityGames = await stateProvider.priorityGames(forTwitchAccount: twitchId)
        let personalPriorityGames = await stateProvider.personalPriorityGames(forTwitchAccount: twitchId)
        let includesGlobalPriorityGames = await stateProvider.includesGlobalPriorityGames(forTwitchAccount: twitchId)
        let diagnostics = await stateProvider.diagnostics(forTwitchAccount: twitchId)

        let state: DiscordUserProjection.ProjectionState
        if let providerState = await stateProvider.projectionState(forTwitchAccount: twitchId) {
            state = providerState
        } else if !issues.isEmpty {
            state = .blocked
        } else if activeCampaign != nil {
            state = .active
        } else {
            state = .idle
        }

        return DiscordUserProjection(
            discordUserId: ownerDiscordId ?? "",
            state: state,
            account: account,
            activeCampaign: activeCampaign,
            recentCompletedCampaigns: recentCompletedCampaigns,
            dropsClaimedThisWeek: dropsClaimedThisWeek,
            issues: issues,
            dmState: dmState,
            priorityGames: priorityGames,
            personalPriorityGames: personalPriorityGames,
            includesGlobalPriorityGames: includesGlobalPriorityGames,
            diagnostics: diagnostics
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
                sqlite3_bind_text(stmt, 1, discordUserId, -1, SQLITE_TRANSIENT_BUILDER)
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
