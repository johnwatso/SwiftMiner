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
    public let lastDropProgressAt: Date?
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
        lastDropProgressAt: Date? = nil,
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
        self.lastDropProgressAt = lastDropProgressAt
        self.stallConfidencePercent = stallConfidencePercent
        self.stallSignals = stallSignals
    }

    @MainActor
    public static func make(miner: MinerManager.ManagedMiner, now: Date = Date()) -> MinerHealthSnapshot {
        let isNotEarning = miner.isNotEarning(now: now)

        let health: Health
        if miner.needsAuth {
            health = .needsAuth
        } else if miner.isStalled {
            health = .stalled
        } else if miner.workerState.isRecovering {
            health = .recovering
        } else if miner.status == .error || miner.status == .blockedAccountNotLinked {
            health = .blocked
        } else if miner.showsNoRecentActivityAttention || isNotEarning {
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
            // A miner that is demonstrably banking nothing is a stronger signal than any
            // single liveness gap, so it carries a floor rather than counting as one signal.
            let base = min(95, signals.count * 25)
            confidence = isNotEarning ? max(base, 60) : base
        }

        return MinerHealthSnapshot(
            id: miner.id,
            displayName: miner.displayName,
            health: health,
            statusLabel: miner.statusLabel,
            lastSuccessfulPollAt: miner.lastSuccessfulPollAt,
            lastEventAt: miner.lastEventAt,
            lastCampaignRefreshAt: miner.lastCampaignRefreshAt,
            lastDropProgressAt: miner.lastDropProgressAt,
            stallConfidencePercent: confidence,
            stallSignals: signals
        )
    }

    private static func stallSignals(for miner: MinerManager.ManagedMiner, now: Date) -> [String] {
        var signals: [String] = []
        if miner.isStalled {
            signals.append("Supervisor marked miner unresponsive")
        }
        if miner.showsNoRecentActivityAttention {
            signals.append("No recent healthy activity")
        }
        if miner.isNotEarning(now: now) {
            let elapsed = now.timeIntervalSince(
                max(miner.lastDropProgressAt ?? .distantPast, miner.statusChangedAt)
            )
            signals.append("Watching with no drop progress in \(Int(elapsed / 60))m")
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
