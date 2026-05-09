import Foundation

// MARK: - Connection State

public enum SwiftBotConnectionState: String, Codable, Equatable, Sendable {
    case connected
    case notConfigured = "not_configured"
    case disconnected
}

// MARK: - Discord User

public struct SwiftBotDiscordUser: Codable, Sendable, Identifiable, Equatable {
    public let id: String          // Discord Snowflake
    public let displayName: String // Guild display name or global name

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    enum CodingKeys: String, CodingKey {
        case id = "discord_id"
        case displayName = "display_name"
    }
}

// MARK: - DM Flow

public enum SwiftBotDMMessageType: String, Codable, CaseIterable, Sendable, Identifiable {
    case welcome
    case discordLinked = "discord_linked"
    case setup
    case linked
    case reauth
    case welcomeBack = "welcome_back"
    case dropClaimed = "drop_claimed"
    case campaignCompleted = "campaign_completed"
    case campaignDetected = "campaign_detected"
    case accountActionRequired = "account_action_required"
    case prioritisedGameNeedsLinking = "prioritised_game_needs_linking"

    public var id: String { rawValue }

    public static var debugPreviewOrder: [SwiftBotDMMessageType] {
        [
            .welcome,
            .discordLinked,
            .setup,
            .linked,
            .campaignDetected,
            .prioritisedGameNeedsLinking,
            .accountActionRequired,
            .reauth,
            .welcomeBack,
            .dropClaimed,
            .campaignCompleted
        ]
    }

    public var displayName: String {
        switch self {
        case .welcome: return "Welcome"
        case .discordLinked: return "Discord Linked"
        case .setup: return "Setup"
        case .linked: return "Twitch Connected"
        case .reauth: return "Connection Expired"
        case .welcomeBack: return "Welcome Back"
        case .dropClaimed: return "Drop Claimed"
        case .campaignCompleted: return "Campaign Complete"
        case .campaignDetected: return "New Campaign"
        case .accountActionRequired: return "Needs a Look"
        case .prioritisedGameNeedsLinking: return "Link Twitch to Claim Drops"
        }
    }
}

public struct SwiftBotDMRequest: Codable, Sendable, Equatable {
    public let messageType: SwiftBotDMMessageType
    public let debug: Bool
    public let twitchUsername: String?
    public let priorityGames: [String]
    public let activationCode: String?
    public let activationExpiresInMinutes: Int?
    public let activationURL: String?
    public let affectedGame: String?
    public let campaignName: String?
    public let milestoneTitle: String?
    public let recoveryReason: String?
    /// Opaque event identifier for persistent deduplication on the SwiftBot side.
    public let eventId: String?

    public init(
        messageType: SwiftBotDMMessageType,
        debug: Bool,
        twitchUsername: String? = nil,
        priorityGames: [String] = [],
        activationCode: String? = nil,
        activationExpiresInMinutes: Int? = nil,
        activationURL: String? = nil,
        affectedGame: String? = nil,
        campaignName: String? = nil,
        milestoneTitle: String? = nil,
        recoveryReason: String? = nil,
        eventId: String? = nil
    ) {
        self.messageType = messageType
        self.debug = debug
        self.twitchUsername = twitchUsername
        self.priorityGames = priorityGames
        self.activationCode = activationCode
        self.activationExpiresInMinutes = activationExpiresInMinutes
        self.activationURL = activationURL
        self.affectedGame = affectedGame
        self.campaignName = campaignName
        self.milestoneTitle = milestoneTitle
        self.recoveryReason = recoveryReason
        self.eventId = eventId
    }

    enum CodingKeys: String, CodingKey {
        case messageType = "message_type"
        case debug
        case twitchUsername = "twitch_username"
        case priorityGames = "priority_games"
        case activationCode = "activation_code"
        case activationExpiresInMinutes = "activation_expires_in_minutes"
        case activationURL = "activation_url"
        case affectedGame = "affected_game"
        case campaignName = "campaign_name"
        case milestoneTitle = "milestone_title"
        case recoveryReason = "recovery_reason"
        case eventId = "event_id"
    }
}

public struct DiscordDMState: Codable, Sendable, Equatable {
    public let hasReceivedWelcomeMessage: Bool
    public let hasCompletedInitialDMFlow: Bool

    public init(hasReceivedWelcomeMessage: Bool = false, hasCompletedInitialDMFlow: Bool = false) {
        self.hasReceivedWelcomeMessage = hasReceivedWelcomeMessage
        self.hasCompletedInitialDMFlow = hasCompletedInitialDMFlow
    }
}

// MARK: - Protocol

public protocol SwiftBotConnectionService: Sendable {
    /// Update the configured endpoint and re-check connectivity.
    func updateEndpoint(_ urlString: String) async

    /// Trigger a manual health check and return the result.
    func checkHealth() async -> SwiftBotConnectionState

    /// Sends a test webhook event to the bot.
    func sendTestEvent() async -> Bool

    /// Fetches all Discord users known to SwiftBot.
    func fetchDiscordUsers() async -> [SwiftBotDiscordUser]

    /// Asks SwiftBot to send the normal post-link success DM.
    func sendLinkedDM(to discordUserId: String, twitchUsername: String?, priorityGames: [String]) async -> Bool

    /// Asks SwiftBot to send an internally marked debug preview DM.
    /// Debug previews must not mutate production DM progression state.
    func sendDebugDM(to discordUserId: String, request: SwiftBotDMRequest) async -> Bool

    /// Sends a production DM event to SwiftBot.
    /// The caller (SwiftMiner) provides the event payload; SwiftBot decides notification behavior.
    func sendEventDM(to discordUserId: String, request: SwiftBotDMRequest) async -> Bool
}
