import Foundation

/// Canonical tab visibility for the Drops screen.
/// `All` is always present, while `Active` and `Claimed` are derived from a
/// single shared classification point.
public struct CampaignTabVisibility: OptionSet, Sendable, Equatable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let active = CampaignTabVisibility(rawValue: 1 << 0)
    public static let claimed = CampaignTabVisibility(rawValue: 1 << 1)
    public static let all = CampaignTabVisibility(rawValue: 1 << 2)
}

/// Curated feed grouping used for ranking and feed composition.
/// This stays intentionally separate from tab visibility.
public enum CampaignCuratedBucket: String, Sendable, Equatable {
    case prioritised
    case active
    case closed
    case recent
}

/// UI-ready data model for a drop campaign.
/// This model combines global campaign discovery data with account-specific
/// inventory and progress tracking.
public struct CampaignViewData: Codable, Sendable, Identifiable, Equatable {
    /// The unique campaign ID from Twitch
    public let id: String
    /// The game/category ID from Twitch (used for grouping related campaigns).
    public let gameId: String?
    /// The name of the game/category (e.g. "The Finals")
    public let gameName: String
    /// The name of the campaign (e.g. "Season 2 Launch Drops")
    public let campaignName: String
    /// URL for the game or campaign artwork
    public let artworkURL: URL?
    /// Aggregate progress across all drops in this campaign (0.0 to 1.0)
    public let progress: Double
    /// Whether all drops in this campaign have been claimed for the current account
    public let isClaimed: Bool
    /// Number of drops successfully claimed
    public let dropsClaimed: Int
    /// Total number of drops in the campaign
    public let totalDrops: Int
    /// Estimated time remaining to earn all drops (nil if not mining or finished)
    public let timeRemaining: TimeInterval?
    /// The current Twitch status of the campaign (ACTIVE, EXPIRED, etc.)
    public let status: String
    /// Truth layer: derived status combining Twitch data + inventory state.
    /// Use this for selection and display logic — do NOT use `status` alone.
    public let miningStatus: MiningCampaignStatus
    /// Whether the user's game account is connected for this campaign (at least for one account in merged views)
    public let isAccountConnected: Bool
    /// Feed ranking context. Keep tab routing on `tabVisibility` instead of
    /// branching directly on relevance in the UI.
    public let relevance: CampaignRelevance
    /// Campaign start date (from Twitch API)
    public let startDate: Date
    /// Campaign end date (from Twitch API)
    public let endDate: Date
    /// Detailed information about individual drops in this campaign
    public let drops: [DropViewData]
    /// Per-account status for this campaign (used for avatar indicators)
    public let accountStates: [AccountState]

    /// True when the campaign has ended and is fully claimed, matching Twitch's
    /// closed-campaign bucket in the UI feed.
    public var isClosed: Bool {
        relevance == .closed ||
        (endDate <= Date() && isFullyClaimedByUser)
    }

    /// Lifecycle-only expiry. Keep this separate from reward progress and miner
    /// state so ended Twitch campaigns cannot render as actively mineable.
    public func isExpired(now: Date = Date()) -> Bool {
        endDate <= now ||
        status.uppercased() == "EXPIRED" ||
        relevance == .closed
    }

    /// Single source of truth for Drops tab membership.
    public var tabVisibility: CampaignTabVisibility {
        var visibility: CampaignTabVisibility = [.all]
        let now = Date()

        if relevance == .prioritised {
            visibility.insert(.active)
        }

        let isActivelyMining = accountStates.contains { $0.miningStatus == .mining }
        let hasStartedProgress = progress > 0
            || dropsClaimed > 0
            || drops.contains { ($0.currentMinutes > 0) && !$0.isClaimed }
        let isAvailable = isAccountConnected
            && !isFullyClaimedByUser
            && !hasStartedProgress
            && startDate <= now
            && endDate > now

        if !isFullyClaimedByUser && (isActivelyMining || hasStartedProgress || isAvailable) {
            visibility.insert(.active)
        }

        if isFullyClaimedByUser {
            visibility.insert(.claimed)
        }

        return visibility
    }

    /// Curated feed grouping used to build ordered, non-exhaustive feeds.
    public var curatedFeedBucket: CampaignCuratedBucket? {
        switch relevance {
        case .prioritised:
            return .prioritised
        case .active:
            return .active
        case .closed:
            return .closed
        case .recent:
            return .recent
        case .irrelevant:
            return nil
        }
    }

    public var showsInActiveTab: Bool { tabVisibility.contains(.active) }
    public var showsInClaimedTab: Bool { tabVisibility.contains(.claimed) }
    public var showsInAllTab: Bool { tabVisibility.contains(.all) }

    private var isFullyClaimedByUser: Bool {
        if !accountStates.isEmpty {
            return accountStates.allSatisfy { $0.miningStatus == .claimed || $0.miningStatus == .claimedUnlinked }
        }
        if totalDrops > 0 {
            return dropsClaimed >= totalDrops
        }
        if !drops.isEmpty {
            return drops.allSatisfy(\.isClaimed)
        }
        return isClaimed
    }

    /// Returns a copy of this campaign with a different artwork URL.
    public func withArtworkURL(_ url: URL?) -> CampaignViewData {
        CampaignViewData(
            id: id,
            gameId: gameId,
            gameName: gameName,
            campaignName: campaignName,
            artworkURL: url,
            progress: progress,
            isClaimed: isClaimed,
            dropsClaimed: dropsClaimed,
            totalDrops: totalDrops,
            timeRemaining: timeRemaining,
            status: status,
            miningStatus: miningStatus,
            isAccountConnected: isAccountConnected,
            relevance: relevance,
            startDate: startDate,
            endDate: endDate,
            drops: drops,
            accountStates: accountStates
        )
    }

    public init(
        id: String,
        gameId: String? = nil,
        gameName: String,
        campaignName: String,
        artworkURL: URL?,
        progress: Double,
        isClaimed: Bool,
        dropsClaimed: Int,
        totalDrops: Int,
        timeRemaining: TimeInterval? = nil,
        status: String = "ACTIVE",
        miningStatus: MiningCampaignStatus = .available,
        isAccountConnected: Bool = false,
        relevance: CampaignRelevance = .active,
        startDate: Date,
        endDate: Date,
        drops: [DropViewData] = [],
        accountStates: [AccountState] = []
    ) {
        self.id = id
        self.gameId = gameId
        self.gameName = gameName
        self.campaignName = campaignName
        self.artworkURL = artworkURL
        self.progress = progress
        self.isClaimed = isClaimed
        self.dropsClaimed = dropsClaimed
        self.totalDrops = totalDrops
        self.timeRemaining = timeRemaining
        self.status = status
        self.miningStatus = miningStatus
        self.isAccountConnected = isAccountConnected
        self.relevance = relevance
        self.startDate = startDate
        self.endDate = endDate
        self.drops = drops
        self.accountStates = accountStates
    }
}

// MARK: - Account State

/// Represents the mining/claimed status of an account for a specific campaign.
public struct AccountState: Codable, Sendable, Equatable, Identifiable {
    public var id: String { accountId }
    public let accountId: String
    public let username: String
    public let initials: String
    public let miningStatus: AccountMiningStatus
    public let claimedDropCount: Int
    public let progressFraction: Double?

    private enum CodingKeys: String, CodingKey {
        case accountId
        case username
        case initials
        case miningStatus
        case claimedDropCount
        case progressFraction
    }
    
    public init(
        accountId: String,
        username: String,
        initials: String,
        miningStatus: AccountMiningStatus,
        claimedDropCount: Int = 0,
        progressFraction: Double? = nil
    ) {
        self.accountId = accountId
        self.username = username
        self.initials = initials
        self.miningStatus = miningStatus
        self.claimedDropCount = claimedDropCount
        self.progressFraction = progressFraction
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountId = try container.decode(String.self, forKey: .accountId)
        username = try container.decode(String.self, forKey: .username)
        initials = try container.decode(String.self, forKey: .initials)
        miningStatus = try container.decode(AccountMiningStatus.self, forKey: .miningStatus)
        claimedDropCount = try container.decodeIfPresent(Int.self, forKey: .claimedDropCount) ?? 0
        progressFraction = try container.decodeIfPresent(Double.self, forKey: .progressFraction)
    }
}

/// Status of an account's relationship with a campaign.
public enum AccountMiningStatus: String, Codable, Sendable, Equatable {
    /// Actively watching/earning progress for this campaign
    case mining = "MINING"
    /// All drops in this campaign are claimed for this account
    case claimed = "CLAIMED"
    /// All drops claimed, but the game account isn't linked — rewards won't
    /// reach the game until the user links it on Twitch.
    case claimedUnlinked = "CLAIMED_UNLINKED"
    /// Account needs manual re-authentication before mining can continue
    case needsAuth = "NEEDS_AUTH"
    /// Account needs game/account linking before this campaign can be mined
    case blocked = "BLOCKED"
    /// Account is linked and eligible to mine this campaign
    case ready = "READY"
    /// Account is linked but not currently mining this campaign
    case idle = "IDLE"
}

// MARK: - Overview Projection

/// Overview-only projection states backed strictly by Drops view data.
public enum CampaignOverviewState: String, Sendable, Equatable {
    case available = "AVAILABLE"
    case inProgress = "IN_PROGRESS"
    case claimable = "CLAIMABLE"
    case completed = "COMPLETED"
}

public extension CampaignViewData {
    /// True when at least one unclaimed drop has real Twitch watch progress.
    var hasValidProgress: Bool {
        overviewProgressFraction != nil
    }

    /// True when all miner campaign states are terminal, falling back to
    /// inventory-backed drop state only for older data without account states.
    var isCompleted: Bool {
        if !accountStates.isEmpty {
            return accountStates.allSatisfy { $0.miningStatus == .claimed || $0.miningStatus == .claimedUnlinked }
        }
        if totalDrops > 0 {
            return dropsClaimed >= totalDrops
        }
        if !drops.isEmpty {
            return drops.allSatisfy(\.isClaimed)
        }
        return isClaimed
    }

    /// True when there are unclaimed drops in this campaign that are earnable by mining.
    /// Returns false if all drops are claimed, or if the remaining drops require subscriptions with no watch progress.
    public var hasObtainableRewards: Bool {
        if totalDrops > 0 && dropsClaimed >= totalDrops {
            return false
        }
        if drops.isEmpty {
            return totalDrops > 0
        }
        let unclaimed = drops.filter { !$0.isClaimed }
        guard !unclaimed.isEmpty else {
            return false
        }
        // If all unclaimed drops require subscription and have 0 progress, they cannot be watched/mined
        let hasMinedObtainable = unclaimed.contains { drop in
            !drop.isSubscriptionRequired || drop.currentMinutes > 0
        }
        return hasMinedObtainable
    }

    /// True when at least one unclaimed reward requires a paid Twitch subscription.
    public var hasSubscriptionRequiredRewards: Bool {
        drops.contains { $0.isSubscriptionRequired && !$0.isClaimed }
    }

    /// True when every remaining unclaimed reward is sub-gated, so watching cannot
    /// make progress until the Twitch subscription requirement is satisfied.
    public var hasOnlySubscriptionRequiredRewards: Bool {
        let unclaimed = drops.filter { !$0.isClaimed }
        return !unclaimed.isEmpty && unclaimed.allSatisfy(\.isSubscriptionRequired)
    }

    public var subscriptionRequiredRewardNames: [String] {
        drops
            .filter { $0.isSubscriptionRequired && !$0.isClaimed }
            .map(\.name)
            .filter { !$0.isEmpty }
    }

    /// Overview must only surface campaigns with real progress or completed rewards.
    var isDisplayableInOverview: Bool {
        hasValidProgress || isCompleted
    }

    /// Overview progress is projected from real drop progress objects only.
    /// It intentionally avoids averaging campaign percentages or fabricating 0%.
    var overviewProgressFraction: Double? {
        drops
            .compactMap { drop -> Double? in
                guard !drop.isClaimed else { return nil }
                guard drop.isClaimable || drop.currentMinutes > 0 else { return nil }
                return min(max(drop.progress, 0), 1)
            }
            .max()
    }

    /// Combined campaign progress used for primary Drops status. This stays
    /// independent of miner activity so a 100% campaign cannot render as active.
    var combinedProgressFraction: Double {
        let dropProgress = drops
            .map { drop -> Double in
                if drop.isClaimed || drop.isClaimable {
                    return 1
                }
                return min(max(drop.progress, 0), 1)
            }
            .max() ?? 0

        return min(max(max(progress, dropProgress), 0), 1)
    }

    var overviewState: CampaignOverviewState {
        if isCompleted {
            return .completed
        }
        if drops.contains(where: { $0.isClaimable && !$0.isClaimed }) {
            return .claimable
        }
        if hasValidProgress {
            return .inProgress
        }
        return .available
    }

    var overviewClaimedRewardCount: Int {
        max(dropsClaimed, drops.filter(\.isClaimed).count)
    }

    var overviewRemainingRewardCount: Int {
        max(totalDrops - overviewClaimedRewardCount, 0)
    }

    /// Grouping key for game-level aggregation.
    /// Prefers `gameId`, then falls back to a normalized game name.
    var aggregateGameGroupKey: String {
        if let gameId, !gameId.isEmpty {
            return gameId
        }
        let fallbackName = gameName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return "name:\(fallbackName)"
    }

    /// Campaign-level state used by `GameAggregate`.
    /// Primary Drops state: expired > completed > in progress > ready.
    func gameAggregateState(now: Date = Date()) -> GameAggregateState {
        let hasExpired = self.isExpired(now: now)
        if hasExpired {
            return .unavailable
        }

        if isCompleted {
            return .completed
        }

        if startDate > now {
            return .ready
        }

        let needsSetup = accountStates.contains {
            $0.miningStatus == .blocked || $0.miningStatus == .needsAuth
        } && hasObtainableRewards
        if needsSetup {
            return .actionRequired
        }

        if combinedProgressFraction > 0 {
            return .inProgress
        }

        return .ready
    }
}
