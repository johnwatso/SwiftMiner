import Foundation

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
    /// Context layer: relevance of this campaign to the current feed/session.
    public let relevance: CampaignRelevance
    /// Detailed information about individual drops in this campaign
    public let drops: [DropViewData]
    /// Per-account status for this campaign (used for avatar indicators)
    public let accountStates: [AccountState]

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
        relevance: CampaignRelevance = .active,
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
        self.relevance = relevance
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
    /// Account is linked but not currently mining this campaign
    case idle = "IDLE"
}
