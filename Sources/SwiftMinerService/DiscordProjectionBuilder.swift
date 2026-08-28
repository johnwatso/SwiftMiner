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
    /// Canonical remote box-art URLs keyed by normalized game name.
    func priorityGameArtwork(for discordUserId: String) async -> [String: String]
    /// Returns the games prioritised specifically for this user's miner, excluding the
    /// global priority list. Used by the Discord "edit games" modal.
    func personalPriorityGames(for discordUserId: String) async -> [String]
    /// Whether global priorities are appended after this user's personal list.
    func includesGlobalPriorityGames(for discordUserId: String) async -> Bool
    /// Source selection shown in the WebUI's priority control.
    func prioritySource(for discordUserId: String) async -> String
    /// Returns games excluded specifically for this miner.
    func excludedGames(for discordUserId: String) async -> [String]
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
    /// Canonical remote box-art URLs keyed by normalized game name.
    func priorityGameArtwork(forTwitchAccount accountId: String) async -> [String: String]
    /// Returns games prioritised specifically for this mined Twitch account.
    func personalPriorityGames(forTwitchAccount accountId: String) async -> [String]
    /// Whether global priorities are appended after this mined Twitch account's personal list.
    func includesGlobalPriorityGames(forTwitchAccount accountId: String) async -> Bool
    /// Source selection shown in the WebUI's priority control.
    func prioritySource(forTwitchAccount accountId: String) async -> String
    /// Returns games excluded specifically for this miner.
    func excludedGames(forTwitchAccount accountId: String) async -> [String]
    /// Returns live health details for a mined Twitch account, if available.
    func diagnostics(forTwitchAccount accountId: String) async -> DiscordUserProjection.Diagnostics?
}

public extension ProjectionStateProvider {
    func personalPriorityGames(for discordUserId: String) async -> [String] { [] }
    func priorityGameArtwork(for discordUserId: String) async -> [String: String] { [:] }
    func includesGlobalPriorityGames(for discordUserId: String) async -> Bool { true }
    func prioritySource(for discordUserId: String) async -> String { "global" }
    func excludedGames(for discordUserId: String) async -> [String] { [] }
    func activeCampaign(forTwitchAccount accountId: String) async -> DiscordUserProjection.ActiveCampaign? { nil }
    func recentCompletedCampaigns(forTwitchAccount accountId: String, limit: Int) async -> [DiscordUserProjection.RecentCampaign] { [] }
    func projectionState(forTwitchAccount accountId: String) async -> DiscordUserProjection.ProjectionState? { nil }
    func priorityGames(forTwitchAccount accountId: String) async -> [String] { [] }
    func priorityGameArtwork(forTwitchAccount accountId: String) async -> [String: String] { [:] }
    func personalPriorityGames(forTwitchAccount accountId: String) async -> [String] { [] }
    func includesGlobalPriorityGames(forTwitchAccount accountId: String) async -> Bool { true }
    func prioritySource(forTwitchAccount accountId: String) async -> String { "global" }
    func excludedGames(forTwitchAccount accountId: String) async -> [String] { [] }
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
    public func priorityGameArtwork(for discordUserId: String) async -> [String: String] { [:] }
    public func includesGlobalPriorityGames(for discordUserId: String) async -> Bool { true }
    public func prioritySource(for discordUserId: String) async -> String { "global" }
    public func excludedGames(for discordUserId: String) async -> [String] { [] }
    public func diagnostics(for discordUserId: String) async -> DiscordUserProjection.Diagnostics? { nil }
}

// MARK: - Builder

/// Builds `DiscordUserProjection` from SQLite + optional runtime state provider.
public actor DiscordProjectionBuilder {
    private let manager: SQLiteManager
    private let stateProvider: ProjectionStateProvider
    /// The app supplies its authenticated, cached Twitch profile URLs. Keeping
    /// this optional means the standalone service remains network-independent.
    private let twitchProfileImageURL: @Sendable (String) async -> URL?
    /// The app supplies the cached Discord profile URL for a linked user. This
    /// remains optional so the standalone service has no SwiftBot dependency.
    private let discordProfileImageURL: @Sendable (String) async -> URL?
    /// The app supplies each account's picture-source choice. Optional for the
    /// same reason as the URLs above: the preference lives in the app's
    /// settings, so a standalone service keeps the Twitch-first default.
    private let prefersDiscordProfileImage: @Sendable (String) async -> Bool
    /// The app supplies each account's nickname. Optional like the values above:
    /// nicknames are stored with the account in the app, not in SQLite, so a
    /// standalone service simply shows Twitch usernames.
    private let accountNickname: @Sendable (String) async -> String?

    public init(
        manager: SQLiteManager,
        stateProvider: ProjectionStateProvider = DefaultProjectionStateProvider(),
        twitchProfileImageURL: @escaping @Sendable (String) async -> URL? = { _ in nil },
        discordProfileImageURL: @escaping @Sendable (String) async -> URL? = { _ in nil },
        prefersDiscordProfileImage: @escaping @Sendable (String) async -> Bool = { _ in false },
        accountNickname: @escaping @Sendable (String) async -> String? = { _ in nil }
    ) {
        self.manager = manager
        self.stateProvider = stateProvider
        self.twitchProfileImageURL = twitchProfileImageURL
        self.discordProfileImageURL = discordProfileImageURL
        self.prefersDiscordProfileImage = prefersDiscordProfileImage
        self.accountNickname = accountNickname
    }

    /// Build a projection for the given Discord user ID.
    /// Returns `nil` if the user is not registered in `miner_users`.
    public func buildProjection(discordUserId: String) async -> DiscordUserProjection? {
        guard await userExists(discordUserId: discordUserId) else {
            return nil
        }
        let configuredMinerCount = await manager.allTwitchAccountIds().count

        let account = await fetchAccount(discordUserId: discordUserId)
        let issues = await fetchIssues(discordUserId: discordUserId)
        let activeCampaign: DiscordUserProjection.ActiveCampaign?
        let recentCompletedCampaigns: [DiscordUserProjection.RecentCampaign]
        let providerState: DiscordUserProjection.ProjectionState?
        let priorityGames: [String]
        let priorityGameArtwork: [String: String]
        let personalPriorityGames: [String]
        let includesGlobalPriorityGames: Bool
        let prioritySource: String
        let excludedGames: [String]
        let diagnostics: DiscordUserProjection.Diagnostics?
        let dropsClaimedThisWeek: Int
        if let account {
            if let accountActive = await stateProvider.activeCampaign(forTwitchAccount: account.twitchAccountId) {
                activeCampaign = accountActive
            } else {
                activeCampaign = await stateProvider.activeCampaign(for: discordUserId)
            }
            recentCompletedCampaigns = await stateProvider.recentCompletedCampaigns(forTwitchAccount: account.twitchAccountId, limit: .max)
            dropsClaimedThisWeek = await manager.fetchClaimsCount(twitchId: account.twitchAccountId, withinDays: 7)
            if let accountState = await stateProvider.projectionState(forTwitchAccount: account.twitchAccountId) {
                providerState = accountState
            } else {
                providerState = await stateProvider.projectionState(for: discordUserId)
            }
            priorityGames = await stateProvider.priorityGames(forTwitchAccount: account.twitchAccountId)
            priorityGameArtwork = await stateProvider.priorityGameArtwork(forTwitchAccount: account.twitchAccountId)
            personalPriorityGames = await stateProvider.personalPriorityGames(forTwitchAccount: account.twitchAccountId)
            includesGlobalPriorityGames = await stateProvider.includesGlobalPriorityGames(forTwitchAccount: account.twitchAccountId)
            prioritySource = await stateProvider.prioritySource(forTwitchAccount: account.twitchAccountId)
            excludedGames = await stateProvider.excludedGames(forTwitchAccount: account.twitchAccountId)
            diagnostics = await stateProvider.diagnostics(forTwitchAccount: account.twitchAccountId)
        } else {
            activeCampaign = await stateProvider.activeCampaign(for: discordUserId)
            recentCompletedCampaigns = await stateProvider.recentCompletedCampaigns(for: discordUserId, limit: .max)
            dropsClaimedThisWeek = 0
            providerState = await stateProvider.projectionState(for: discordUserId)
            priorityGames = await stateProvider.priorityGames(for: discordUserId)
            priorityGameArtwork = await stateProvider.priorityGameArtwork(for: discordUserId)
            personalPriorityGames = await stateProvider.personalPriorityGames(for: discordUserId)
            includesGlobalPriorityGames = await stateProvider.includesGlobalPriorityGames(for: discordUserId)
            prioritySource = await stateProvider.prioritySource(for: discordUserId)
            excludedGames = await stateProvider.excludedGames(for: discordUserId)
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
            priorityGameArtwork: priorityGameArtwork,
            personalPriorityGames: personalPriorityGames,
            includesGlobalPriorityGames: includesGlobalPriorityGames,
            prioritySource: prioritySource,
            excludedGames: excludedGames,
            configuredMinerCount: configuredMinerCount,
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
        let configuredMinerCount = await manager.allTwitchAccountIds().count
        let ownerDiscordId = acct.ownerDiscordId

        let discordProfileURL: URL? = if let ownerDiscordId {
            MinerAvatarURL.secure(await discordProfileImageURL(ownerDiscordId))
        } else {
            nil
        }
        let account = DiscordUserProjection.Account(
            twitchAccountId: twitchId,
            username: acct.username,
            nickname: await accountNickname(twitchId),
            profileImageURL: MinerAvatarURL.usable(await twitchProfileImageURL(twitchId)),
            discordProfileImageURL: discordProfileURL,
            prefersDiscordProfileImage: await prefersDiscordProfileImage(twitchId)
        )
        // Issues / DM state are Discord-keyed; only present if the account is linked.
        let issues = ownerDiscordId != nil ? await fetchIssues(discordUserId: ownerDiscordId!) : []
        let dmState = ownerDiscordId != nil ? await fetchDMState(discordUserId: ownerDiscordId!) : DiscordDMState()

        let activeCampaign = await stateProvider.activeCampaign(forTwitchAccount: twitchId)
        let recentCompletedCampaigns = await stateProvider.recentCompletedCampaigns(forTwitchAccount: twitchId, limit: .max)
        let dropsClaimedThisWeek = await manager.fetchClaimsCount(twitchId: twitchId, withinDays: 7)
        let priorityGames = await stateProvider.priorityGames(forTwitchAccount: twitchId)
        let priorityGameArtwork = await stateProvider.priorityGameArtwork(forTwitchAccount: twitchId)
        let personalPriorityGames = await stateProvider.personalPriorityGames(forTwitchAccount: twitchId)
        let includesGlobalPriorityGames = await stateProvider.includesGlobalPriorityGames(forTwitchAccount: twitchId)
        let prioritySource = await stateProvider.prioritySource(forTwitchAccount: twitchId)
        let excludedGames = await stateProvider.excludedGames(forTwitchAccount: twitchId)
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
            priorityGameArtwork: priorityGameArtwork,
            personalPriorityGames: personalPriorityGames,
            includesGlobalPriorityGames: includesGlobalPriorityGames,
            prioritySource: prioritySource,
            excludedGames: excludedGames,
            configuredMinerCount: configuredMinerCount,
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
            let record: (twitchId: String, username: String)? = try await manager.query { db in
                let sql = "SELECT twitch_id, username FROM twitch_accounts WHERE owner_discord_id = ? LIMIT 1;"
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, discordUserId, -1, SQLITE_TRANSIENT_BUILDER)
                guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
                let twitchId = String(cString: sqlite3_column_text(stmt, 0))
                let username = String(cString: sqlite3_column_text(stmt, 1))
                return (twitchId, username)
            }
            guard let record else { return nil }
            return DiscordUserProjection.Account(
                twitchAccountId: record.twitchId,
                username: record.username,
                nickname: await accountNickname(record.twitchId),
                profileImageURL: MinerAvatarURL.usable(await twitchProfileImageURL(record.twitchId)),
                discordProfileImageURL: MinerAvatarURL.secure(await discordProfileImageURL(discordUserId)),
                prefersDiscordProfileImage: await prefersDiscordProfileImage(record.twitchId)
            )
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
