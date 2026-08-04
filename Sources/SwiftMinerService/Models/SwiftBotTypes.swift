import Foundation
import SwiftMinerCore

// MARK: - Connection State

public enum SwiftBotConnectionState: String, Codable, Equatable, Sendable {
    case connected
    case notConfigured = "not_configured"
    case disconnected
    case unpaired
}

// MARK: - Discord User

public struct SwiftBotDiscordUser: Codable, Sendable, Identifiable, Equatable {
    public let id: String          // Discord Snowflake
    public let displayName: String // Guild display name or global name
    public let username: String?
    public let avatarURL: URL?

    public init(id: String, displayName: String, username: String? = nil, avatarURL: URL? = nil) {
        self.id = id
        self.displayName = displayName
        self.username = username
        self.avatarURL = MinerAvatarURL.usable(avatarURL)
    }

    enum CodingKeys: String, CodingKey {
        case id = "discord_id"
        case displayName = "display_name"
        case username
        case avatarURL = "avatar_url"
    }

    enum AlternateCodingKeys: String, CodingKey {
        case avatarUrl
        case avatar
        case displayAvatarURL = "display_avatar_url"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let alternate = try decoder.container(keyedBy: AlternateCodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        avatarURL = MinerAvatarURL.usable(try container.decodeIfPresent(URL.self, forKey: .avatarURL)
            ?? alternate.decodeIfPresent(URL.self, forKey: .avatarUrl)
            ?? alternate.decodeIfPresent(URL.self, forKey: .displayAvatarURL)
            ?? alternate.decodeIfPresent(URL.self, forKey: .avatar))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(username, forKey: .username)
        try container.encodeIfPresent(avatarURL, forKey: .avatarURL)
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
    case webDashboardAvailable = "web_dashboard_available"

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
            .campaignCompleted,
            .webDashboardAvailable
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
        case .webDashboardAvailable: return "Web Dashboard Live"
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
    public let gameArtworkURL: String?
    public let accountId: String?
    public let minerDisplayName: String?
    public let affectedGameId: String?
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
        gameArtworkURL: String? = nil,
        accountId: String? = nil,
        minerDisplayName: String? = nil,
        affectedGameId: String? = nil,
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
        self.gameArtworkURL = gameArtworkURL
        self.accountId = accountId
        self.minerDisplayName = minerDisplayName
        self.affectedGameId = affectedGameId
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
        case gameArtworkURL = "game_artwork_url"
        case accountId = "account_id"
        case minerDisplayName = "miner_display_name"
        case affectedGameId = "affected_game_id"
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

    enum CodingKeys: String, CodingKey {
        case hasReceivedWelcomeMessage = "has_received_welcome_message"
        case hasCompletedInitialDMFlow = "has_completed_initial_dm_flow"
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

    /// Asks SwiftBot to carry `hostname` on its Cloudflare tunnel, routed to
    /// SwiftMiner's local dashboard (`service`, e.g. http://localhost:8080).
    /// Signed with the shared pairing secret.
    func registerTunnelHostname(hostname: String, service: String, hmacSecret: String) async -> SwiftBotTunnelRegistrationResult

    /// Fetches SwiftBot's tunnel domain/readiness so the dashboard only needs a
    /// subdomain from the user. Returns nil when SwiftBot is unreachable or too
    /// old to support the endpoint.
    func fetchTunnelInfo() async -> SwiftBotTunnelInfo?
}

/// SwiftBot's public-tunnel facts, used to compose the dashboard hostname.
public struct SwiftBotTunnelInfo: Sendable, Decodable {
    /// Whether SwiftBot's Internet Access (Cloudflare tunnel) is fully set up.
    public let internetAccessEnabled: Bool
    /// The apex domain (Cloudflare zone), e.g. "example.com".
    public let domain: String
    /// SwiftBot's own hostname, e.g. "swiftbot.example.com".
    public let swiftBotHostname: String
}

/// Outcome of registering a hostname on SwiftBot's Cloudflare tunnel.
public enum SwiftBotTunnelRegistrationResult: Sendable {
    case success(publicURL: String)
    case failure(message: String)
}

public extension SwiftBotConnectionService {
    /// Default for implementations (and test doubles) that don't support
    /// tunnel hostname registration.
    func registerTunnelHostname(hostname: String, service: String, hmacSecret: String) async -> SwiftBotTunnelRegistrationResult {
        .failure(message: "Tunnel registration is not supported by this connection.")
    }

    /// Default for implementations (and test doubles) without tunnel info.
    func fetchTunnelInfo() async -> SwiftBotTunnelInfo? { nil }
}
