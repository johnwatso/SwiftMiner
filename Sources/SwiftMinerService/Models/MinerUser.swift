import Foundation

/// Represents a managed user in the SwiftMiner platform (Phase: Identity).
/// Bridges a Discord identity to one or more Twitch mining accounts.
public struct MinerUser: Codable, Sendable, Equatable, Identifiable {
    public let discordId: String // Discord Snowflake (Primary Key)
    public var status: UserStatus
    public let createdAt: Date
    public var dmState: DiscordDMState

    public init(
        discordId: String,
        status: UserStatus = .registered,
        createdAt: Date = Date(),
        dmState: DiscordDMState = DiscordDMState()
    ) {
        self.discordId = discordId
        self.status = status
        self.createdAt = createdAt
        self.dmState = dmState
    }

    public enum UserStatus: String, Codable, Sendable, CaseIterable {
        case registered
        case active
        case suspended
    }
    
    public var id: String { discordId }
}
