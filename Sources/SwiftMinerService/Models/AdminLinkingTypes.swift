import Foundation
import SwiftMinerCore

// MARK: - Models

public struct AdminAccountAssignment: Sendable {
    public let twitchAccountId: String      // maps to twitch_accounts.twitch_id
    public let discordId: String            // maps to miner_users.discord_id
    public let operatorId: String

    public init(twitchAccountId: String, discordId: String, operatorId: String) {
        self.twitchAccountId = twitchAccountId
        self.discordId = discordId
        self.operatorId = operatorId
    }
}

public enum ReassignmentPolicy: Sendable { 
    case rejectIfOwned
    case allowConfirmed(expectedCurrentOwner: String) 
}

public enum AdminLinkingResult: Equatable, Sendable {
    case linked(discordId: String, previousDiscordId: String?, userWasCreated: Bool, wasReassignment: Bool)
    case alreadyLinked(currentDiscordId: String)
    case notFound
    case invalidDiscordId
    case internalError(String)
}

public enum AdminUserRegistrationResult: Equatable, Sendable {
    case registered(discordId: String)
    case alreadyRegistered(discordId: String)
    case invalidDiscordId
    case internalError(String)
}

// MARK: - Protocol

public protocol AdminLinkingService: Sendable {
    /// Link a Twitch account to a Discord user.
    /// - Parameters:
    ///   - assignment: The assignment details (account ID, user ID, operator ID).
    ///   - policy: How to handle existing ownership.
    /// - Returns: A result enum indicating success or a specific failure reason.
    func assignAccount(_ assignment: AdminAccountAssignment, policy: ReassignmentPolicy) async -> AdminLinkingResult
    
    /// Returns all Twitch accounts that do not currently have an owner.
    func getUnownedAccounts() async -> [Account]

    /// Manually register a Discord user in the system.
    /// - Parameters:
    ///   - discordId: The Discord Snowflake ID.
    ///   - operatorId: The ID of the admin performing the registration.
    func registerUser(discordId: String, operatorId: String) async -> AdminUserRegistrationResult
}

// MARK: - Event Payloads

public struct UserLinkedEventPayload: Codable, Sendable {
    public let discordId: String
    public let twitchId: String
    public let twitchUsername: String
    public let linkMethod: String // "admin_assignment"
    public let previousOwnerDiscordId: String?
    public let userWasCreated: Bool
    public let wasReassignment: Bool

    enum CodingKeys: String, CodingKey {
        case discordId = "discord_id"
        case twitchId = "twitch_id"
        case twitchUsername = "twitch_username"
        case linkMethod = "link_method"
        case previousOwnerDiscordId = "previous_owner_discord_id"
        case userWasCreated = "user_was_created"
        case wasReassignment = "was_reassignment"
    }
}

public struct AdminAuditMetadata: Codable, Sendable {
    public let twitchUsername: String?
    public let userWasCreated: Bool
    public let wasReassignment: Bool

    enum CodingKeys: String, CodingKey {
        case twitchUsername = "twitch_username"
        case userWasCreated = "user_was_created"
        case wasReassignment = "was_reassignment"
    }
}
