import Foundation

/// Represents the progress of a drop
public struct Progress: Codable, Sendable, Equatable {
    public let id: String
    public let dropId: String
    public let dropName: String
    public let campaignId: String
    public var currentMinutes: Int
    public let requiredMinutes: Int
    public var isClaimed: Bool
    public var lastUpdated: Date

    public init(
        id: String,
        dropId: String,
        dropName: String,
        campaignId: String,
        currentMinutes: Int,
        requiredMinutes: Int,
        isClaimed: Bool = false,
        lastUpdated: Date = Date()
    ) {
        self.id = id
        self.dropId = dropId
        self.dropName = dropName
        self.campaignId = campaignId
        self.currentMinutes = currentMinutes
        self.requiredMinutes = requiredMinutes
        self.isClaimed = isClaimed
        self.lastUpdated = lastUpdated
    }

    public var currentMinutesWatched: Int {
        currentMinutes
    }

    public var isComplete: Bool {
        currentMinutes >= requiredMinutes
    }

    public var remainingMinutes: Int {
        max(0, requiredMinutes - currentMinutes)
    }

    public var percentComplete: Double {
        min(100.0, (Double(currentMinutes) / Double(requiredMinutes)) * 100)
    }

    /// Convenience init used by GQL response parsing — derives id from campaignId + dropId
    public init(
        dropId: String,
        campaignId: String,
        currentMinutes: Int,
        requiredMinutes: Int,
        isClaimed: Bool = false
    ) {
        self.id = "\(campaignId)_\(dropId)"
        self.dropId = dropId
        self.dropName = ""
        self.campaignId = campaignId
        self.currentMinutes = currentMinutes
        self.requiredMinutes = requiredMinutes
        self.isClaimed = isClaimed
        self.lastUpdated = Date()
    }
}

/// Represents a user-specific state for a drop (Phase 2).
/// Separates account progress from global campaign data.
public struct DropState: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(accountId)_\(dropId)" }
    public let dropId: String
    public let accountId: String
    public let progressMinutes: Int
    public let requiredMinutes: Int
    public let isClaimed: Bool
    public let lastUpdated: Date

    public init(
        dropId: String,
        accountId: String,
        progressMinutes: Int,
        requiredMinutes: Int,
        isClaimed: Bool,
        lastUpdated: Date = Date()
    ) {
        self.dropId = dropId
        self.accountId = accountId
        self.progressMinutes = progressMinutes
        self.requiredMinutes = requiredMinutes
        self.isClaimed = isClaimed
        self.lastUpdated = lastUpdated
    }

    public var isComplete: Bool {
        progressMinutes >= requiredMinutes
    }

    public var percentComplete: Double {
        guard requiredMinutes > 0 else { return 0 }
        return min(100.0, (Double(progressMinutes) / Double(requiredMinutes)) * 100)
    }
}

/// Represents the overall progress across all campaigns
public struct OverallProgress: Codable, Sendable, Equatable {
    public let totalCampaigns: Int
    public let activeCampaigns: Int
    public let totalDrops: Int
    public let claimedDrops: Int
    public let pendingDrops: Int
    public let totalWatchTimeMinutes: Int
    public let campaigns: [CampaignProgress]

    public init(
        totalCampaigns: Int,
        activeCampaigns: Int,
        totalDrops: Int,
        claimedDrops: Int,
        pendingDrops: Int,
        totalWatchTimeMinutes: Int,
        campaigns: [CampaignProgress]
    ) {
        self.totalCampaigns = totalCampaigns
        self.activeCampaigns = activeCampaigns
        self.totalDrops = totalDrops
        self.claimedDrops = claimedDrops
        self.pendingDrops = pendingDrops
        self.totalWatchTimeMinutes = totalWatchTimeMinutes
        self.campaigns = campaigns
    }
}

/// Represents the progress within a specific campaign
public struct CampaignProgress: Codable, Sendable, Equatable {
    public let campaignId: String
    public let campaignName: String
    public let gameName: String
    public let totalDrops: Int
    public let claimedDrops: Int
    public let dropProgress: [Progress]

    public init(
        campaignId: String,
        campaignName: String,
        gameName: String,
        totalDrops: Int,
        claimedDrops: Int,
        dropProgress: [Progress]
    ) {
        self.campaignId = campaignId
        self.campaignName = campaignName
        self.gameName = gameName
        self.totalDrops = totalDrops
        self.claimedDrops = claimedDrops
        self.dropProgress = dropProgress
    }
}

/// Represents the overall mining session progress
public struct MiningSession: Codable, Sendable, Equatable {
    public let id: UUID
    public let startedAt: Date
    public var endedAt: Date?
    public var campaignsProcessed: Int
    public var dropsClaimed: Int
    public var totalWatchTime: TimeInterval
    public var currentCampaignId: String?
    public var currentChannelId: String?
    public var status: SessionStatus

    public init() {
        self.id = UUID()
        self.startedAt = Date()
        self.endedAt = nil
        self.campaignsProcessed = 0
        self.dropsClaimed = 0
        self.totalWatchTime = 0
        self.currentCampaignId = nil
        self.currentChannelId = nil
        self.status = .idle
    }
}

public enum SessionStatus: String, Codable, Sendable, Equatable {
    case idle = "IDLE"
    case authenticating = "AUTHENTICATING"
    case fetchingCampaigns = "FETCHING_CAMPAIGNS"
    case watching = "WATCHING"
    case claiming = "CLAIMING"
    case paused = "PAUSED"
    case stopped = "STOPPED"
    case error = "ERROR"
    
    public var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .authenticating: return "Authenticating"
        case .fetchingCampaigns: return "Fetching Campaigns"
        case .watching: return "Watching"
        case .claiming: return "Claiming"
        case .paused: return "Paused"
        case .stopped: return "Stopped"
        case .error: return "Error"
        }
    }
}
