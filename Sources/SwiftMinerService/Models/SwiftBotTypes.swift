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

    /// Asks SwiftBot to send a "connected and active" test DM to the given Discord user.
    /// `twitchUsername` and `priorityGames` are optional context the bot uses to enrich
    /// the message (e.g. for the post-setup welcome).
    func sendTestDM(to discordUserId: String, twitchUsername: String?, priorityGames: [String]) async -> Bool
}

public extension SwiftBotConnectionService {
    /// Convenience: send a basic test DM with no additional context.
    func sendTestDM(to discordUserId: String) async -> Bool {
        await sendTestDM(to: discordUserId, twitchUsername: nil, priorityGames: [])
    }
}
