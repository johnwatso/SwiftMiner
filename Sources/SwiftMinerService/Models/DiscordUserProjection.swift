import Foundation

/// Derived state for Discord. Not a direct reflection of internal miner state.
/// Enforces 1 Discord = 1 Twitch relationship for the bot interface.
public struct DiscordUserProjection: Codable, Sendable {
    public let discordUserId: String
    public let state: ProjectionState
    public let account: Account?
    public let activeCampaign: ActiveCampaign?
    public let issues: [Issue]

    public init(
        discordUserId: String,
        state: ProjectionState,
        account: Account? = nil,
        activeCampaign: ActiveCampaign? = nil,
        issues: [Issue] = []
    ) {
        self.discordUserId = discordUserId
        self.state = state
        self.account = account
        self.activeCampaign = activeCampaign
        self.issues = issues
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

        public init(campaignId: String, game: String, progress: Progress, endsAt: Date) {
            self.campaignId = campaignId
            self.game = game
            self.progress = progress
            self.endsAt = endsAt
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
