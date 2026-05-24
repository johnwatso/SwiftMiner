import Foundation

public struct CampaignDeadlineForecast: Sendable, Equatable, Identifiable {
    public enum Outcome: String, Sendable, Equatable {
        case onTrack
        case atRisk
        case missed
        case complete
        case blocked
        case unknown
    }

    public let id: String
    public let minerId: String
    public let campaignId: String
    public let campaignName: String
    public let gameName: String
    public let outcome: Outcome
    public let minutesRemainingToEarn: Int
    public let minutesUntilDeadline: Int
    public let progressPercent: Double
    public let reason: String

    public init(
        id: String,
        minerId: String,
        campaignId: String,
        campaignName: String,
        gameName: String,
        outcome: Outcome,
        minutesRemainingToEarn: Int,
        minutesUntilDeadline: Int,
        progressPercent: Double,
        reason: String
    ) {
        self.id = id
        self.minerId = minerId
        self.campaignId = campaignId
        self.campaignName = campaignName
        self.gameName = gameName
        self.outcome = outcome
        self.minutesRemainingToEarn = minutesRemainingToEarn
        self.minutesUntilDeadline = minutesUntilDeadline
        self.progressPercent = progressPercent
        self.reason = reason
    }

    public static func make(
        minerId: String,
        campaign: Campaign,
        now: Date = Date(),
        safetyBufferMinutes: Int = 30
    ) -> CampaignDeadlineForecast {
        let minutesUntilDeadline = max(0, Int(campaign.endDate.timeIntervalSince(now) / 60))
        let eligibleDrops = campaign.eligibleDrops
        let dropsToFinish = eligibleDrops.isEmpty ? campaign.unclaimedDrops : eligibleDrops
        let minutesRemaining = dropsToFinish.reduce(0) { total, drop in
            let current = drop.progress?.currentMinutes ?? 0
            return total + max(0, drop.requiredMinutes - current)
        }
        let totalRequired = campaign.drops.reduce(0) { $0 + max(0, $1.requiredMinutes) }
        let totalWatched = campaign.drops.reduce(0) { total, drop in
            total + min(drop.requiredMinutes, drop.progress?.currentMinutes ?? (drop.isClaimed ? drop.requiredMinutes : 0))
        }
        let progressPercent = totalRequired > 0 ? min(100, (Double(totalWatched) / Double(totalRequired)) * 100) : 0

        let outcome: Outcome
        let reason: String
        if campaign.isFullyComplete {
            outcome = .complete
            reason = "All drops are claimed."
        } else if !campaign.isAccountConnected {
            outcome = .blocked
            reason = "Account is not linked for this campaign."
        } else if now < campaign.startDate || now > campaign.endDate {
            outcome = now > campaign.endDate ? .missed : .unknown
            reason = now > campaign.endDate ? "Campaign has ended." : "Campaign is not active yet."
        } else if minutesRemaining == 0 {
            outcome = .complete
            reason = "Drops are ready to claim or already complete."
        } else if minutesRemaining + safetyBufferMinutes <= minutesUntilDeadline {
            outcome = .onTrack
            reason = "Enough time remains with a \(safetyBufferMinutes)m buffer."
        } else if minutesRemaining <= minutesUntilDeadline {
            outcome = .atRisk
            reason = "Finish is possible, but the buffer is thin."
        } else {
            outcome = .missed
            reason = "Required watch time exceeds time remaining."
        }

        return CampaignDeadlineForecast(
            id: "\(minerId)-\(campaign.id)",
            minerId: minerId,
            campaignId: campaign.id,
            campaignName: campaign.name,
            gameName: campaign.game.name,
            outcome: outcome,
            minutesRemainingToEarn: minutesRemaining,
            minutesUntilDeadline: minutesUntilDeadline,
            progressPercent: progressPercent,
            reason: reason
        )
    }
}

public struct MinerHealthSnapshot: Sendable, Equatable, Identifiable {
    public enum Health: String, Sendable, Equatable {
        case mining
        case blocked
        case needsAuth
        case stalled
        case recovering
        case idle
        case attention
    }

    public let id: String
    public let displayName: String
    public let health: Health
    public let statusLabel: String
    public let lastSuccessfulPollAt: Date?
    public let lastEventAt: Date?
    public let lastCampaignRefreshAt: Date?
    public let stallConfidencePercent: Int
    public let stallSignals: [String]

    public init(
        id: String,
        displayName: String,
        health: Health,
        statusLabel: String,
        lastSuccessfulPollAt: Date?,
        lastEventAt: Date?,
        lastCampaignRefreshAt: Date?,
        stallConfidencePercent: Int,
        stallSignals: [String]
    ) {
        self.id = id
        self.displayName = displayName
        self.health = health
        self.statusLabel = statusLabel
        self.lastSuccessfulPollAt = lastSuccessfulPollAt
        self.lastEventAt = lastEventAt
        self.lastCampaignRefreshAt = lastCampaignRefreshAt
        self.stallConfidencePercent = stallConfidencePercent
        self.stallSignals = stallSignals
    }

    @MainActor
    public static func make(miner: MinerManager.ManagedMiner, now: Date = Date()) -> MinerHealthSnapshot {
        let health: Health
        if miner.needsAuth {
            health = .needsAuth
        } else if miner.isStalled {
            health = .stalled
        } else if miner.workerState.isRecovering {
            health = .recovering
        } else if miner.status == .error || miner.status == .blockedAccountNotLinked {
            health = .blocked
        } else if miner.isRunning && !miner.isHealthy {
            health = .attention
        } else if miner.status == .watching {
            health = .mining
        } else {
            health = .idle
        }

        let signals = stallSignals(for: miner, now: now)
        let confidence: Int
        if miner.isStalled {
            confidence = 100
        } else {
            confidence = min(95, signals.count * 25)
        }

        return MinerHealthSnapshot(
            id: miner.id,
            displayName: miner.displayName,
            health: health,
            statusLabel: miner.statusLabel,
            lastSuccessfulPollAt: miner.lastSuccessfulPollAt,
            lastEventAt: miner.lastEventAt,
            lastCampaignRefreshAt: miner.lastCampaignRefreshAt,
            stallConfidencePercent: confidence,
            stallSignals: signals
        )
    }

    private static func stallSignals(for miner: MinerManager.ManagedMiner, now: Date) -> [String] {
        var signals: [String] = []
        if miner.isStalled {
            signals.append("Supervisor marked miner unresponsive")
        }
        if miner.isRunning && !miner.isHealthy {
            signals.append("No recent healthy activity")
        }
        if minutes(since: miner.lastSuccessfulPollAt, now: now) >= 15 {
            signals.append("No successful poll in 15m")
        }
        if minutes(since: miner.lastEventAt, now: now) >= 20 {
            signals.append("No miner event in 20m")
        }
        if miner.workerState.isRecovering {
            signals.append("Recovery is in progress")
        }
        return signals
    }

    private static func minutes(since date: Date?, now: Date) -> Int {
        guard let date else { return Int.max }
        return Int(now.timeIntervalSince(date) / 60)
    }
}
