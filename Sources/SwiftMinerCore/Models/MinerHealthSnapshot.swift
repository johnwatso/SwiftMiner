import Foundation

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
