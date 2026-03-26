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
        ((status == CampaignStatus.expired.rawValue || endDate <= Date()) && isClaimed)
    }

    /// Single source of truth for Drops tab membership.
    public var tabVisibility: CampaignTabVisibility {
        var visibility: CampaignTabVisibility = [.all]

        // Show in Active tab if:
        // 1. Relevance is prioritised or active (normal routing)
        // 2. Has in-progress drops (waiting for stream to continue)
        if relevance == .prioritised || relevance == .active ||
           miningStatus == .inProgress {
            visibility.insert(.active)
        }

        if isClaimed ||
            miningStatus == .claimed ||
            accountStates.contains(where: { $0.miningStatus == .claimed }) {
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

    /// Returns a copy of this campaign with a different artwork URL.
    public func withArtworkURL(_ url: URL?) -> CampaignViewData {
        CampaignViewData(
            id: id,
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
    
    public init(
        accountId: String,
        username: String,
        initials: String,
        miningStatus: AccountMiningStatus
    ) {
        self.accountId = accountId
        self.username = username
        self.initials = initials
        self.miningStatus = miningStatus
    }
}

/// Status of an account's relationship with a campaign.
public enum AccountMiningStatus: String, Codable, Sendable, Equatable {
    /// Actively watching/earning progress for this campaign
    case mining = "MINING"
    /// All drops in this campaign are claimed for this account
    case claimed = "CLAIMED"
    /// Account needs manual re-authentication before mining can continue
    case needsAuth = "NEEDS_AUTH"
    /// Account is linked but not currently mining this campaign
    case idle = "IDLE"
}
