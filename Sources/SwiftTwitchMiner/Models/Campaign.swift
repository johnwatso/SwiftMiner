import Foundation

// MARK: - Supporting Types

/// A Twitch game / category
public struct Game: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let boxArtURL: URL?

    public init(id: String, name: String, boxArtURL: URL? = nil) {
        self.id = id
        self.name = name
        self.boxArtURL = boxArtURL
    }
}

/// Status of a drop campaign
public enum CampaignStatus: String, Codable, Sendable, Equatable {
    case active = "ACTIVE"
    case upcoming = "UPCOMING"
    case expired = "EXPIRED"
    case disabled = "DISABLED"
}

/// Type of reward a drop gives
public enum RewardType: String, Codable, Sendable, Equatable {
    case inGame = "IN_GAME"
    case badge = "BADGE"
    case emote = "EMOTE"
}

/// A drop reward (badge, emote, in-game item)
public struct Reward: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let type: RewardType
    public let name: String
    public let description: String
    public let imageURL: URL?

    public init(id: String, type: RewardType, name: String, description: String, imageURL: URL? = nil) {
        self.id = id
        self.type = type
        self.name = name
        self.description = description
        self.imageURL = imageURL
    }
}

// MARK: - Drop

/// A single timed drop within a campaign
public struct Drop: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let description: String?
    public let imageURL: URL?
    public let requiredMinutes: Int
    public let reward: Reward?
    public var progress: Progress?

    public init(
        id: String,
        name: String,
        description: String? = nil,
        imageURL: URL? = nil,
        requiredMinutes: Int,
        reward: Reward? = nil,
        progress: Progress? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.imageURL = imageURL
        self.requiredMinutes = requiredMinutes
        self.reward = reward
        self.progress = progress
    }

    /// Whether the drop has been fully earned and is ready to claim
    public var isClaimable: Bool {
        guard let p = progress else { return false }
        return p.isComplete && !p.isClaimed
    }

    /// Whether the drop has already been claimed
    public var isClaimed: Bool { progress?.isClaimed ?? false }

    /// Progress percentage (0–100)
    public var percentComplete: Double { progress?.percentComplete ?? 0 }

    /// Whether this is a community drop (always false for timed drops)
    public var isCommunityDrop: Bool { false }

    /// Alias for requiredMinutes (backward compat)
    public var requiredMinutesWatched: Int { requiredMinutes }
}

// MARK: - Campaign

/// A Twitch drops campaign containing one or more timed drops
public struct Campaign: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let game: Game
    public let status: CampaignStatus
    public let startDate: Date
    public let endDate: Date
    public var drops: [Drop]
    /// ACL whitelist — empty means any channel streaming this game qualifies
    public let channels: [Channel]
    /// Whether the user's game account is connected for this campaign
    public let isAccountConnected: Bool

    public init(
        id: String,
        name: String,
        game: Game,
        status: CampaignStatus = .active,
        startDate: Date,
        endDate: Date,
        drops: [Drop] = [],
        channels: [Channel] = [],
        isAccountConnected: Bool = false
    ) {
        self.id = id
        self.name = name
        self.game = game
        self.status = status
        self.startDate = startDate
        self.endDate = endDate
        self.drops = drops
        self.channels = channels
        self.isAccountConnected = isAccountConnected
    }

    // MARK: Computed properties

    public var isActive: Bool {
        status == .active && Date() >= startDate && Date() <= endDate
    }

    public var isTimeActive: Bool { isActive }

    public var hasClaimableDrops: Bool { drops.contains { $0.isClaimable } }

    public var isFullyComplete: Bool { drops.allSatisfy { $0.isClaimed } }

    public var hasChannelRestrictions: Bool { !channels.isEmpty }

    public var unclaimedDrops: [Drop] { drops.filter { !$0.isClaimed } }

    // MARK: Legacy compatibility shims

    public var gameId: String { game.id }
    public var gameName: String { game.name }
    public var gameImageUrl: URL? { game.boxArtURL }
    public var startAt: Date { startDate }
    public var endAt: Date { endDate }
    public var hasDropsEnabled: Bool { true }
}
