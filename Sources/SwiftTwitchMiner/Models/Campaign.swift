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
    public let benefitID: String
    public let reward: Reward?
    public var progress: Progress?
    public var isClaimed: Bool
    /// Benefit IDs from benefitEdges — preserved for compatibility and diagnostics.
    public var benefitIds: [String]
    /// Prerequisite drop IDs that must be claimed before this drop can be earned.
    public var preconditionDrops: [String]
    /// Per-drop active window (may differ from campaign window)
    public var dropStartDate: Date?
    public var dropEndDate: Date?

    public init(
        id: String,
        name: String,
        description: String? = nil,
        imageURL: URL? = nil,
        requiredMinutes: Int,
        benefitID: String = "",
        reward: Reward? = nil,
        progress: Progress? = nil,
        isClaimed: Bool = false,
        benefitIds: [String] = [],
        preconditionDrops: [String] = [],
        dropStartDate: Date? = nil,
        dropEndDate: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.imageURL = imageURL
        self.requiredMinutes = requiredMinutes
        self.benefitID = benefitID.isEmpty ? benefitIds.first ?? "" : benefitID
        self.reward = reward
        self.progress = progress
        self.isClaimed = isClaimed
        self.benefitIds = benefitIds.isEmpty
            ? (self.benefitID.isEmpty ? [] : [self.benefitID])
            : benefitIds
        self.preconditionDrops = preconditionDrops
        self.dropStartDate = dropStartDate
        self.dropEndDate = dropEndDate
    }

    /// Whether the drop has been fully earned and is ready to claim
    public var isClaimable: Bool {
        guard let p = progress else { return false }
        return p.isComplete && !isClaimed
    }

    /// Whether the drop is eligible (not claimed and can be earned)
    public var isEligible: Bool {
        !isClaimed
    }

    /// Progress percentage (0–100)
    public var percentComplete: Double {
        if isClaimed { return 100 }
        return progress?.percentComplete ?? 0
    }

    /// Whether this is a community drop (always false for timed drops)
    public var isCommunityDrop: Bool { false }

    /// Alias for requiredMinutes (backward compat)
    public var requiredMinutesWatched: Int { requiredMinutes }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case imageURL
        case requiredMinutes
        case benefitID
        case reward
        case progress
        case isClaimed
        case benefitIds
        case preconditionDrops
        case dropStartDate
        case dropEndDate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        imageURL = try container.decodeIfPresent(URL.self, forKey: .imageURL)
        requiredMinutes = try container.decode(Int.self, forKey: .requiredMinutes)
        reward = try container.decodeIfPresent(Reward.self, forKey: .reward)
        progress = try container.decodeIfPresent(Progress.self, forKey: .progress)
        benefitIds = try container.decodeIfPresent([String].self, forKey: .benefitIds) ?? []
        let decodedBenefitID = try container.decodeIfPresent(String.self, forKey: .benefitID) ?? ""
        benefitID = decodedBenefitID.isEmpty ? benefitIds.first ?? "" : decodedBenefitID
        isClaimed = try container.decodeIfPresent(Bool.self, forKey: .isClaimed) ?? progress?.isClaimed ?? false
        preconditionDrops = try container.decodeIfPresent([String].self, forKey: .preconditionDrops) ?? []
        dropStartDate = try container.decodeIfPresent(Date.self, forKey: .dropStartDate)
        dropEndDate = try container.decodeIfPresent(Date.self, forKey: .dropEndDate)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(imageURL, forKey: .imageURL)
        try container.encode(requiredMinutes, forKey: .requiredMinutes)
        try container.encode(benefitID, forKey: .benefitID)
        try container.encodeIfPresent(reward, forKey: .reward)
        try container.encodeIfPresent(progress, forKey: .progress)
        try container.encode(isClaimed, forKey: .isClaimed)
        try container.encode(benefitIds, forKey: .benefitIds)
        try container.encode(preconditionDrops, forKey: .preconditionDrops)
        try container.encodeIfPresent(dropStartDate, forKey: .dropStartDate)
        try container.encodeIfPresent(dropEndDate, forKey: .dropEndDate)
    }
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

    /// Whether campaign has eligible drops (not claimed and eligible for account)
    public var hasEligibleDrops: Bool {
        drops.contains { $0.isEligible && !$0.isClaimed }
    }

    public var isFullyComplete: Bool { drops.allSatisfy { $0.isClaimed } }

    public var hasChannelRestrictions: Bool { !channels.isEmpty }

    public var unclaimedDrops: [Drop] { drops.filter { !$0.isClaimed } }

    /// Whether the campaign is currently eligible for mining (active, linked, and has earneable drops).
    public var isMiningEligible: Bool {
        isTimeActive && isAccountConnected && !earnableDrops.isEmpty
    }

    /// Returns drops that can be earned now (not claimed, NOT yet claimable, and all preconditions met).
    public var earnableDrops: [Drop] {
        drops.filter { drop in
            // Must be unclaimed, NOT already at 100% (claimable), and linked
            guard !drop.isClaimed && !drop.isClaimable else { return false }
            
            // All preconditions must be fully claimed
            return drop.preconditionDrops.allSatisfy { pid in
                drops.first { $0.id == pid }?.isClaimed ?? true
            }
        }
    }

    /// Returns drops that can be claimed now or earned soon (not claimed and all preconditions met).
    public var eligibleDrops: [Drop] {
        drops.filter { drop in
            guard !drop.isClaimed else { return false }
            return drop.preconditionDrops.allSatisfy { pid in
                drops.first { $0.id == pid }?.isClaimed ?? true
            }
        }
    }

    // MARK: Legacy compatibility shims

    public var gameId: String { game.id }
    public var gameName: String { game.name }
    public var gameImageUrl: URL? { game.boxArtURL }
    public var startAt: Date { startDate }
    public var endAt: Date { endDate }
    public var hasDropsEnabled: Bool { true }
}

// MARK: - Phase 3: Merge Layer Models

/// UI model combining a global Drop with its account-specific states.
public struct DisplayDrop: Sendable, Identifiable, Equatable {
    public var id: String { base.id }
    public let base: Drop
    public let states: [DropState]
    
    public init(base: Drop, states: [DropState]) {
        self.base = base
        self.states = states
    }
    
    /// Summary of progress across all accounts for this drop.
    public var totalAccounts: Int { states.count }
    public var claimedCount: Int { states.filter { $0.isClaimed }.count }
    public var isFullyClaimed: Bool { !states.isEmpty && states.allSatisfy { $0.isClaimed } }

    /// Whether any account has claimed this drop.
    public var isClaimedByAnyAccount: Bool { states.contains { $0.isClaimed } }

    /// Whether any account has completed but not yet claimed (ready to claim).
    public var isClaimableByAnyAccount: Bool { states.contains { $0.isComplete && !$0.isClaimed } }

    /// Best progress across all accounts (percentage 0–100).
    public var bestProgressPercent: Double {
        states.map { $0.percentComplete }.max() ?? 0
    }

    /// Best progress in minutes across all accounts.
    public var bestProgressMinutes: Int {
        states.map { $0.progressMinutes }.max() ?? 0
    }

    /// The state for a specific account, if present.
    public func state(for accountId: String) -> DropState? {
        states.first { $0.accountId == accountId }
    }
}

/// UI model combining a global Campaign with its account-specific states.
public struct DisplayCampaign: Sendable, Identifiable, Equatable {
    public var id: String { base.id }
    public let base: Campaign
    public let drops: [DisplayDrop]
    
    public init(base: Campaign, drops: [DisplayDrop]) {
        self.base = base
        self.drops = drops
    }
    
    public var name: String { base.name }
    public var gameName: String { base.game.name }
    public var isTimeActive: Bool { base.isTimeActive }

    /// Drops not yet claimed by all accounts.
    public var unclaimedDrops: [DisplayDrop] { drops.filter { !$0.isFullyClaimed } }

    /// Whether any drop is ready to claim across any account.
    public var hasClaimableDrops: Bool { drops.contains { $0.isClaimableByAnyAccount } }

    /// Whether any account is linked/eligible for at least one drop in this campaign.
    /// Returns false when no account states exist (no accounts added yet).
    public var isEligibleByAnyAccount: Bool {
        drops.contains { $0.states.contains { $0.isEligible } }
    }
}

// MARK: - Phase 5.2: Campaign Grouping Model

/// UI model grouping multiple campaigns for the same game.
public struct GameDisplayGroup: Sendable, Identifiable, Equatable {
    public var id: String { gameId }
    public let gameId: String
    public let gameName: String
    public let boxArtURL: URL?
    public let campaigns: [DisplayCampaign]
    public let drops: [DisplayDrop]
    
    public init(
        gameId: String,
        gameName: String,
        boxArtURL: URL?,
        campaigns: [DisplayCampaign],
        drops: [DisplayDrop]
    ) {
        self.gameId = gameId
        self.gameName = gameName
        self.boxArtURL = boxArtURL
        self.campaigns = campaigns
        self.drops = drops
    }
    
    /// If ANY campaign in the group is eligible.
    public var isEligibleByAnyAccount: Bool {
        campaigns.contains { $0.isEligibleByAnyAccount }
    }
    
    /// If any drop in any campaign is ready to claim.
    public var hasClaimableDrops: Bool {
        drops.contains { $0.isClaimableByAnyAccount }
    }
}
