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
    /// The current status of the campaign
    public let status: String
    
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
        status: String = "ACTIVE"
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
    }
}
