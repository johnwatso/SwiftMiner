import Foundation

// MARK: - PrimaryState

/// A single, user-facing "resolved state" for the Activity / Drops Mining system.
/// Unifies internal states (CampaignStatus, SessionStatus, account link warnings, etc.)
/// to provide a consistent mental model and clear visual hierarchy.
public enum PrimaryState: Equatable, Sendable {
    /// The system is unable to mine due to one or more blocking reasons.
    case blocked(reasons: [BlockReason])
    
    /// System is functional and scanning for work or performing transient tasks (claiming, etc.).
    case ready
    
    /// Actively mining progress for a specific campaign/drop.
    case mining(progress: MiningProgress)
    
    /// All eligible campaigns have been fully earned and claimed.
    case completed
}

// MARK: - BlockReason

/// Specific reason why the mining system is currently blocked.
public enum BlockReason: String, Equatable, Sendable {
    /// No accounts are linked, or the current account requires re-authentication.
    case accountNotLinked
    
    /// No campaigns are currently available for the user's games or interests.
    case noEligibleCampaign
    
    /// A campaign is selected, but no participating channels are currently live.
    case noLiveStreams
}

// MARK: - MiningProgress

/// Granular progress details for an active mining session.
public struct MiningProgress: Equatable, Sendable {
    public let gameName: String
    public let campaignName: String
    public let dropName: String
    public let progressFraction: Double // 0.0 to 1.0
    public let minutesRemaining: Int
    
    public init(
        gameName: String,
        campaignName: String,
        dropName: String,
        progressFraction: Double,
        minutesRemaining: Int
    ) {
        self.gameName = gameName
        self.campaignName = campaignName
        self.dropName = dropName
        self.progressFraction = progressFraction
        self.minutesRemaining = minutesRemaining
    }
}
