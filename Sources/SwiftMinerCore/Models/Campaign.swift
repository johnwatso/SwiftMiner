import Foundation

enum TwitchDropSafetyClassifier {
    private static let internalTestLabels: Set<String> = [
        "test",
        "drop test",
        "drops test",
        "twitch test",
        "twitch drops test",
        "qa test",
        "internal test"
    ]

    static func isInternalTestLabel(_ value: String) -> Bool {
        internalTestLabels.contains(normalizedLabel(value))
    }

    private static func normalizedLabel(_ value: String) -> String {
        value
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

// MARK: - Supporting Types

/// A Twitch game / category
public struct Game: Codable, Sendable, Identifiable, Equatable {
    public static let specialIRLCategoryId = "509672"

    public let id: String
    public let name: String
    public let boxArtURL: URL?

    public init(id: String, name: String, boxArtURL: URL? = nil) {
        self.id = id
        self.name = name
        self.boxArtURL = boxArtURL
    }

    /// Whether this game represents a global/special event category that can host drops
    /// from any game (e.g. Just Chatting, Music, Special Events).
    /// These campaigns bypass strict game-name channel matching — any ACL channel qualifies.
    public var isSpecialEvents: Bool {
        // IDs from TwitchDropsMiner and John's spec:
        // 509658: Just Chatting
        // 26936:  Music
        // 509659: Travel & Outdoors
        // 509663: Special Events
        // 509672: IRL
        ["509658", "26936", "509659", "509663", Self.specialIRLCategoryId].contains(id)
    }
}

/// Status of a drop campaign
public enum CampaignStatus: String, Codable, Sendable, Equatable {
    case active = "ACTIVE"
    case upcoming = "UPCOMING"
    case expired = "EXPIRED"
    case disabled = "DISABLED"
}

/// The truth layer for a campaign's status relative to an account.
public enum MiningCampaignStatus: String, Codable, Sendable, Equatable {
    /// Not started but eligible to earn
    case available = "AVAILABLE"
    /// Partially completed
    case inProgress = "IN_PROGRESS"
    /// Ready to claim (100% progress but not claimed)
    case claimable = "CLAIMABLE"
    /// Fully completed and claimed
    case claimed = "CLAIMED"
    /// No longer valid (time window closed)
    case expired = "EXPIRED"
}

/// The context layer for a campaign's relevance to the user/session.
public enum CampaignRelevance: String, Codable, Sendable, Equatable {
    /// User-selected games (always visible)
    case prioritised = "PRIORITISED"
    /// Currently mineable (available / in progress / claimable)
    case active = "ACTIVE"
    /// Claimed recently (last 24–48h)
    case recent = "RECENT"
    /// Campaign ended but all drops claimed (visible in "Closed Drop Campaigns")
    case closed = "CLOSED"
    /// Not relevant to current session
    case irrelevant = "IRRELEVANT"
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

    public var isLikelyInternalTestReward: Bool {
        TwitchDropSafetyClassifier.isInternalTestLabel(name)
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
    /// Number of Twitch subscriptions required to earn this drop (0 = none).
    public let requiredSubs: Int
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
        requiredSubs: Int = 0,
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
        self.requiredSubs = requiredSubs
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

    /// Whether this drop requires purchasing Twitch subscriptions.
    public var isSubscriptionRequired: Bool { requiredSubs > 0 }

    /// Alias for requiredMinutes (backward compat)
    public var requiredMinutesWatched: Int { requiredMinutes }

    /// Twitch occasionally exposes QA-looking drop fixtures to real inventories.
    /// Treat exact "test" labels as non-actionable so SwiftMiner does not watch or claim them.
    public var isLikelyInternalTestDrop: Bool {
        TwitchDropSafetyClassifier.isInternalTestLabel(name)
            || (reward?.isLikelyInternalTestReward ?? false)
    }

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
        case requiredSubs
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
        requiredSubs = try container.decodeIfPresent(Int.self, forKey: .requiredSubs) ?? 0
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
        try container.encode(requiredSubs, forKey: .requiredSubs)
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
    /// Twitch's allow.isEnabled value for this campaign/account when present.
    /// This describes whether an allow-list is enabled; false means unrestricted,
    /// not that drops are disabled.
    public let allowIsEnabled: Bool?
    
    /// User preference context (used for relevance calculation)
    public let isPrioritised: Bool

    public init(
        id: String,
        name: String,
        game: Game,
        status: CampaignStatus = .active,
        startDate: Date,
        endDate: Date,
        drops: [Drop] = [],
        channels: [Channel] = [],
        isAccountConnected: Bool = false,
        allowIsEnabled: Bool? = nil,
        isPrioritised: Bool = false
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
        self.allowIsEnabled = allowIsEnabled
        self.isPrioritised = isPrioritised
    }

    // MARK: - Truth Layer: Mining Status

    /// The definitive status of this campaign for the current account.
    /// Derived from both Twitch data and Inventory state.
    public var miningStatus: MiningCampaignStatus {
        // 1. Expired check — use date window only.
        // The API status field can return stale values (e.g. "EXPIRED" while endDate is still
        // in the future for CDL/esports campaigns). Rely on the date window as authoritative.
        if Date() > endDate {
            return .expired
        }
        
        // 2. Claimed check (All drops must be claimed)
        if !drops.isEmpty && drops.allSatisfy({ $0.isClaimed }) {
            return .claimed
        }
        
        // 3. Claimable check (Any drop ready to claim)
        if drops.contains(where: { $0.isClaimable }) {
            return .claimable
        }
        
        // 4. In Progress check (Any drop has progress > 0)
        if drops.contains(where: { ($0.progress?.currentMinutes ?? 0) > 0 }) {
            return .inProgress
        }
        
        // 5. Default to Available
        return .available
    }

    // MARK: - Context Layer: Relevance

    /// The relevance of this campaign to the current session/feed.
    public var relevance: CampaignRelevance {
        // Exact test/QA fixtures should not clutter active or prioritised campaign lists.
        if isLikelyInternalTestCampaign {
            return .irrelevant
        }

        // 1. Prioritised check
        if isPrioritised {
            return .prioritised
        }

        let s = miningStatus
        
        // 2. Claimed check — ALL claimed campaigns show as recent (so they appear in Claimed tab)
        // This MUST come before Active check to prevent claimed campaigns showing in Active
        // Use drops directly since isFullyClaimed isn't defined yet at this point in the file
        let allDropsClaimed = !drops.isEmpty && drops.allSatisfy({ $0.isClaimed })
        if s == .claimed || allDropsClaimed {
            return .recent
        }

        // 3. Active check — unprioritised, unlinked public campaigns should not
        // clutter Drops. Prioritised campaigns are handled above; connected
        // campaigns remain active here.
        if isAccountConnected && isTimeActive && (s == .available || s == .inProgress || s == .claimable) {
            return .active
        }

        // 4. Closed check — use date window only (same reasoning as isActive).
        // API status field can be stale (e.g. "EXPIRED" while endDate is still future).
        if endDate <= Date() {
            return .closed
        }

        return .irrelevant
    }

    // MARK: Computed properties

    public var isActive: Bool {
        // Trust the date window over the API status field — Twitch occasionally returns
        // stale/incorrect status (e.g. "EXPIRED") for campaigns that are still within
        // their time window (endDate in the future). Date-based check is authoritative.
        Date() >= startDate && Date() <= endDate
    }

    public var isTimeActive: Bool { isActive }

    public var hasClaimableDrops: Bool { drops.contains { $0.isClaimable } }

    /// Whether campaign has eligible drops (not claimed and eligible for account)
    public var hasEligibleDrops: Bool {
        drops.contains { $0.isEligible && !$0.isClaimed }
    }

    public var isFullyComplete: Bool { drops.allSatisfy { $0.isClaimed } }

    /// Whether the campaign consists only of badge or emote rewards (non-drop rewards).
    public var hasOnlyBadgesOrEmotes: Bool {
        !drops.isEmpty && drops.allSatisfy { drop in
            guard let type = drop.reward?.type else { return false }
            return type == .badge || type == .emote
        }
    }

    public var hasChannelRestrictions: Bool { !channels.isEmpty }

    public var unclaimedDrops: [Drop] { drops.filter { !$0.isClaimed } }

    /// Exact-match guard for Twitch QA/test fixtures that should never become mining targets.
    public var isLikelyInternalTestCampaign: Bool {
        if TwitchDropSafetyClassifier.isInternalTestLabel(name) {
            return true
        }

        return !drops.isEmpty && drops.allSatisfy(\.isLikelyInternalTestDrop)
    }

    /// True if campaign has ended but all drops are claimed (visible in Twitch's "Closed Drop Campaigns")
    public var isClosed: Bool {
        // Campaign is closed if: ended/exired AND all drops are claimed
        (!isActive || status == .expired) && drops.allSatisfy { $0.isClaimed }
    }

    /// Whether the campaign is currently eligible for mining without warnings.
    /// This still requires the external game account to be linked.
    public var isMiningEligible: Bool {
        canAttemptMining && isAccountConnected
    }

    /// Whether SwiftMiner should attempt this campaign if Twitch exposes usable drops.
    /// Game-account linkage is intentionally not a hard gate here: Twitch is the
    /// source of truth for whether progress can be earned, while SwiftMiner still
    /// warns the user that an external account link may be needed for in-game delivery.
    public var canAttemptMining: Bool {
        isTimeActive
            && status != .disabled
            && hasDropsEnabled
            && !isLikelyInternalTestCampaign
            && !eligibleDrops.isEmpty
    }

    /// Drops that require purchasing subscriptions and have no progress yet.
    /// These cannot be earned by watching alone.
    public var subscriptionRequiredDrops: [Drop] {
        drops.filter { $0.isSubscriptionRequired && !$0.isClaimed && ($0.progress?.currentMinutes ?? 0) == 0 }
    }

    /// Returns drops that can be earned now (not claimed, NOT yet claimable, and all preconditions met).
    public var earnableDrops: [Drop] {
        drops.filter { drop in
            // Must be unclaimed, NOT already at 100% (claimable), and linked
            guard !drop.isClaimed && !drop.isClaimable else { return false }

            // Subscription-required drops without progress can't be earned by watching
            if drop.isSubscriptionRequired, (drop.progress?.currentMinutes ?? 0) == 0 {
                return false
            }

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

            // Subscription-required drops without progress can't be earned by watching
            if drop.isSubscriptionRequired, (drop.progress?.currentMinutes ?? 0) == 0 {
                return false
            }

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
    public var hasDropsEnabled: Bool { status != .disabled }
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
