import Foundation
import SwiftMinerCore

// MARK: - Operator Identity

public enum OperatorIdentity: Sendable, Equatable {
    case localAdmin
    case bot(apiKeyId: String)

    public var stringValue: String {
        switch self {
        case .localAdmin: return "local_admin"
        case .bot(let apiKeyId): return "bot:\(apiKeyId)"
        }
    }
}

// MARK: - Models

public struct AdminAccountAssignment: Sendable {
    public let twitchAccountId: String      // maps to twitch_accounts.twitch_id
    public let discordId: String            // maps to miner_users.discord_id
    public let operatorIdentity: OperatorIdentity

    public init(twitchAccountId: String, discordId: String, operatorIdentity: OperatorIdentity) {
        self.twitchAccountId = twitchAccountId
        self.discordId = discordId
        self.operatorIdentity = operatorIdentity
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

public enum AdminUnlinkResult: Equatable, Sendable {
    case unlinked(previousDiscordId: String)
    case notFound
    case notLinked
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
    ///   - operatorIdentity: Who is performing the registration.
    func registerUser(discordId: String, operatorIdentity: OperatorIdentity) async -> AdminUserRegistrationResult

    /// Returns all registered users in the system.
    func getAllUsers() async -> [MinerUser]

    /// Returns all accounts owned by a specific Discord user.
    func getAccounts(for discordId: String) async -> [Account]

    /// Remove the Discord owner from a Twitch account.
    func unlinkAccount(twitchAccountId: String, operatorIdentity: OperatorIdentity) async -> AdminUnlinkResult
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

public struct UserRegisteredEventPayload: Codable, Sendable {
    public let discordId: String
    public let registeredBy: String

    enum CodingKeys: String, CodingKey {
        case discordId = "discord_id"
        case registeredBy = "registered_by"
    }
}
