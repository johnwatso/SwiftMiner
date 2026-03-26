import Foundation

/// UI-ready data model for a single drop.
/// Provides final, computed state for granular drop display.
public struct DropViewData: Codable, Sendable, Identifiable, Equatable {
    /// The unique drop ID
    public let id: String
    /// The name of the drop (reward name)
    public let name: String
    /// Description of the drop
    public let description: String?
    /// URL for the drop reward image
    public let imageURL: URL?
    /// Type of reward (inGame, badge, emote)
    public let rewardType: RewardType
    /// Minutes required to earn this drop
    public let requiredMinutes: Int
    /// Current minutes watched toward this drop
    public let currentMinutes: Int
    /// Progress percentage (0.0 to 1.0)
    public let progress: Double
    /// Whether the drop has been claimed
    public let isClaimed: Bool
    /// Whether the drop is ready to be claimed (100% progress but not yet claimed)
    public let isClaimable: Bool
    /// Whether the drop is currently earnable (linked, preconditions met, not yet claimed)
    public let isEarnable: Bool
    
    public init(
        id: String,
        name: String,
        description: String?,
        imageURL: URL?,
        rewardType: RewardType,
        requiredMinutes: Int,
        currentMinutes: Int,
        progress: Double,
        isClaimed: Bool,
        isClaimable: Bool,
        isEarnable: Bool
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.imageURL = imageURL
        self.rewardType = rewardType
        self.requiredMinutes = requiredMinutes
        self.currentMinutes = currentMinutes
        self.progress = progress
        self.isClaimed = isClaimed
        self.isClaimable = isClaimable
        self.isEarnable = isEarnable
    }
}
