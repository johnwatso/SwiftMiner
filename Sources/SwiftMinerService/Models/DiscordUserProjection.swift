import Foundation

/// Derived state for Discord. Not a direct reflection of internal miner state.
/// Enforces 1 Discord = 1 Twitch relationship for the bot interface.
public struct DiscordUserProjection: Codable, Sendable {
    public let discordUserId: String
    public let state: ProjectionState
    public let account: Account?
    public let activeCampaign: ActiveCampaign?
    public let recentCompletedCampaigns: [RecentCampaign]
    /// Drops claimed by this account within the trailing 7 days (rolling).
    public let dropsClaimedThisWeek: Int
    public let issues: [Issue]
    public let dmState: DiscordDMState
    public let priorityGames: [String]
    /// Games prioritised specifically for this user's miner, excluding the global list.
    public let personalPriorityGames: [String]
    /// Whether the operator-level priority list is appended after personal priorities.
    public let includesGlobalPriorityGames: Bool
    /// Live health details for browser triage. Nil when the miner is not available.
    public let diagnostics: Diagnostics?

    public init(
        discordUserId: String,
        state: ProjectionState,
        account: Account? = nil,
        activeCampaign: ActiveCampaign? = nil,
        recentCompletedCampaigns: [RecentCampaign] = [],
        dropsClaimedThisWeek: Int = 0,
        issues: [Issue] = [],
        dmState: DiscordDMState = DiscordDMState(),
        priorityGames: [String] = [],
        personalPriorityGames: [String] = [],
        includesGlobalPriorityGames: Bool = true,
        diagnostics: Diagnostics? = nil
    ) {
        self.discordUserId = discordUserId
        self.state = state
        self.account = account
        self.activeCampaign = activeCampaign
        self.recentCompletedCampaigns = recentCompletedCampaigns
        self.dropsClaimedThisWeek = dropsClaimedThisWeek
        self.issues = issues
        self.dmState = dmState
        self.priorityGames = priorityGames
        self.personalPriorityGames = personalPriorityGames
        self.includesGlobalPriorityGames = includesGlobalPriorityGames
        self.diagnostics = diagnostics
    }

    public enum ProjectionState: String, Codable, Sendable {
        case notConfigured = "notConfigured"
        case active = "active"
        case idle = "idle"
        case blocked = "blocked"
    }

    public struct Account: Codable, Sendable {
        public let twitchAccountId: String
        public let username: String

        public init(twitchAccountId: String, username: String) {
            self.twitchAccountId = twitchAccountId
            self.username = username
        }
    }

    public struct ActiveCampaign: Codable, Sendable {
        public let campaignId: String
        public let game: String
        public let progress: Progress
        public let endsAt: Date
        /// Twitch box art for the game, when known — lets web clients show the
        /// same artwork as the native GUI instead of guessing CDN URLs.
        public let boxArtURL: String?
        public let currentChannelName: String?
        public let currentChannelId: String?

        public init(
            campaignId: String,
            game: String,
            progress: Progress,
            endsAt: Date,
            boxArtURL: String? = nil,
            currentChannelName: String? = nil,
            currentChannelId: String? = nil
        ) {
            self.campaignId = campaignId
            self.game = game
            self.progress = progress
            self.endsAt = endsAt
            self.boxArtURL = boxArtURL
            self.currentChannelName = currentChannelName
            self.currentChannelId = currentChannelId
        }
    }

    public struct Progress: Codable, Sendable {
        public let current: Int
        public let required: Int
        public let unit: String
        public let pct: Int

        public init(current: Int, required: Int, unit: String, pct: Int) {
            self.current = current
            self.required = required
            self.unit = unit
            self.pct = pct
        }
    }

    public struct RecentCampaign: Codable, Sendable, Identifiable {
        public var id: String { campaignId }
        public let campaignId: String
        public let campaignName: String
        public let game: String
        public let completedAt: Date?
        public let claimedDrops: Int
        public let totalDrops: Int
        /// Twitch box art for the game, when known.
        public let boxArtURL: String?

        public init(
            campaignId: String,
            campaignName: String,
            game: String,
            completedAt: Date? = nil,
            claimedDrops: Int,
            totalDrops: Int,
            boxArtURL: String? = nil
        ) {
            self.campaignId = campaignId
            self.campaignName = campaignName
            self.game = game
            self.completedAt = completedAt
            self.claimedDrops = claimedDrops
            self.totalDrops = totalDrops
            self.boxArtURL = boxArtURL
        }
    }

    public struct Diagnostics: Codable, Sendable {
        public let health: String
        public let statusRaw: String
        public let statusLabel: String
        public let isRunning: Bool
        public let isHealthy: Bool
        public let isStalled: Bool
        public let stallConfidencePercent: Int
        public let stallSignals: [String]
        public let lastSuccessfulPollAt: Date?
        public let lastEventAt: Date?
        public let lastCampaignRefreshAt: Date?
        public let minutesSinceLastProgress: Int?
        public let currentChannelName: String?
        public let currentChannelId: String?
        public let lastSwitchReason: String?
        public let lastSwitchAt: Date?
        public let recentEvents: [DiagnosticEvent]

        public init(
            health: String,
            statusRaw: String,
            statusLabel: String,
            isRunning: Bool,
            isHealthy: Bool,
            isStalled: Bool,
            stallConfidencePercent: Int,
            stallSignals: [String],
            lastSuccessfulPollAt: Date?,
            lastEventAt: Date?,
            lastCampaignRefreshAt: Date?,
            minutesSinceLastProgress: Int?,
            currentChannelName: String?,
            currentChannelId: String?,
            lastSwitchReason: String?,
            lastSwitchAt: Date?,
            recentEvents: [DiagnosticEvent]
        ) {
            self.health = health
            self.statusRaw = statusRaw
            self.statusLabel = statusLabel
            self.isRunning = isRunning
            self.isHealthy = isHealthy
            self.isStalled = isStalled
            self.stallConfidencePercent = stallConfidencePercent
            self.stallSignals = stallSignals
            self.lastSuccessfulPollAt = lastSuccessfulPollAt
            self.lastEventAt = lastEventAt
            self.lastCampaignRefreshAt = lastCampaignRefreshAt
            self.minutesSinceLastProgress = minutesSinceLastProgress
            self.currentChannelName = currentChannelName
            self.currentChannelId = currentChannelId
            self.lastSwitchReason = lastSwitchReason
            self.lastSwitchAt = lastSwitchAt
            self.recentEvents = recentEvents
        }
    }

    public struct DiagnosticEvent: Codable, Sendable, Identifiable {
        public var id: String { "\(timestamp.timeIntervalSince1970)-\(type)-\(summary)" }
        public let timestamp: Date
        public let type: String
        public let summary: String

        public init(timestamp: Date, type: String, summary: String) {
            self.timestamp = timestamp
            self.type = type
            self.summary = summary
        }
    }

    public struct Issue: Codable, Sendable, Identifiable {
        public var id: String { issueId }
        public let issueId: String
        public let type: String
        public let campaignId: String?
        public let game: String?
        public let message: String
        public let action: String // "link_account | ignore_campaign | ignore_game"

        public init(
            issueId: String,
            type: String,
            campaignId: String? = nil,
            game: String? = nil,
            message: String,
            action: String
        ) {
            self.issueId = issueId
            self.type = type
            self.campaignId = campaignId
            self.game = game
            self.message = message
            self.action = action
        }
    }
}
