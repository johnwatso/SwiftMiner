import Foundation

public enum MinerWorkerState: String, Sendable, Equatable {
    case idle
    case starting
    case running
    case refreshing
    case recovering
    case authRefreshing
    case stopped
    case failed

    public var isRecovering: Bool {
        switch self {
        case .refreshing, .recovering, .authRefreshing:
            return true
        default:
            return false
        }
    }
}

public struct MinerOperationalMetadata: Sendable, Equatable {
    public var lastEventAt: Date?
    public var lastSuccessfulPollAt: Date?
    public var lastCampaignRefreshAt: Date?
    /// When the miner last banked verified drop progress. Liveness timestamps above
    /// only prove the miner is talking to Twitch; this one proves it is earning.
    public var lastDropProgressAt: Date?
    public var workerState: MinerWorkerState
    public var workerTaskID: String?
    public var isHealthy: Bool
    public var isStalled: Bool

    public init(
        lastEventAt: Date? = nil,
        lastSuccessfulPollAt: Date? = nil,
        lastCampaignRefreshAt: Date? = nil,
        lastDropProgressAt: Date? = nil,
        workerState: MinerWorkerState = .idle,
        workerTaskID: String? = nil,
        isHealthy: Bool = true,
        isStalled: Bool = false
    ) {
        self.lastEventAt = lastEventAt
        self.lastSuccessfulPollAt = lastSuccessfulPollAt
        self.lastCampaignRefreshAt = lastCampaignRefreshAt
        self.lastDropProgressAt = lastDropProgressAt
        self.workerState = workerState
        self.workerTaskID = workerTaskID
        self.isHealthy = isHealthy
        self.isStalled = isStalled
    }
}

public actor MinerSupervisor {
    public struct Configuration: Sendable, Equatable {
        public var stallTimeout: TimeInterval
        public var peerFreshnessWindow: TimeInterval
        public var startupGracePeriod: TimeInterval
        public var noRecentActivityWindow: TimeInterval
        public var recoveryBaseCooldown: TimeInterval
        public var recoveryMaxCooldown: TimeInterval

        public init(
            stallTimeout: TimeInterval = 15 * 60,
            peerFreshnessWindow: TimeInterval = 4 * 60,
            startupGracePeriod: TimeInterval = 2 * 60,
            noRecentActivityWindow: TimeInterval = 3 * 60,
            recoveryBaseCooldown: TimeInterval = 45,
            recoveryMaxCooldown: TimeInterval = 10 * 60
        ) {
            self.stallTimeout = stallTimeout
            self.peerFreshnessWindow = peerFreshnessWindow
            self.startupGracePeriod = startupGracePeriod
            self.noRecentActivityWindow = noRecentActivityWindow
            self.recoveryBaseCooldown = recoveryBaseCooldown
            self.recoveryMaxCooldown = recoveryMaxCooldown
        }
    }

    public enum RecoveryStage: Int, Sendable, Equatable {
        case refresh = 1
        case restart = 2
        case authRefresh = 3
    }

    public struct RecoveryAction: Sendable, Equatable {
        public let minerId: String
        public let stage: RecoveryStage
        public let reason: String
        public let attempt: Int
    }

    public enum StallCause: String, Sendable, Equatable {
        case networkError
        case twitchAPIFailure
        case rateLimited
        case authIssue
        case watchSessionFailure
        case workerStartupFailure
        case noRecentActivity
        case unknown

        public var displayName: String {
            switch self {
            case .networkError: return "network connectivity"
            case .twitchAPIFailure: return "Twitch API failure"
            case .rateLimited: return "Twitch rate limiting"
            case .authIssue: return "authentication issue"
            case .watchSessionFailure: return "watch session failure"
            case .workerStartupFailure: return "worker startup failure"
            case .noRecentActivity: return "no recent activity"
            case .unknown: return "miner unresponsive"
            }
        }
    }

    private struct Entry: Sendable {
        var metadata = MinerOperationalMetadata()
        var lastStateUpdateAt: Date?
        var workerStartedAt: Date?
        var recoveryAttemptCount = 0
        var nextRecoveryStage: RecoveryStage = .refresh
        var recoveryCooldownUntil: Date?
        var lastRecoveryReason: String?
        var lastIssueCause: StallCause?
        var lastIssueDetail: String?
        var lastIssueAt: Date?
    }

    private let configuration: Configuration
    private var entries: [String: Entry] = [:]

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func registerMiner(_ minerId: String) {
        if entries[minerId] == nil {
            entries[minerId] = Entry()
        }
    }

    public func unregisterMiner(_ minerId: String) {
        entries.removeValue(forKey: minerId)
    }

    public func recordWorkerStart(minerId: String, taskID: String, at date: Date = Date()) {
        var entry = entries[minerId, default: Entry()]
        entry.workerStartedAt = date
        entry.lastStateUpdateAt = date
        entry.metadata.lastEventAt = date
        entry.metadata.workerTaskID = taskID
        entry.metadata.workerState = .starting
        entry.metadata.isHealthy = true
        entry.metadata.isStalled = false
        entries[minerId] = entry
    }

    public func recordWorkerRunning(minerId: String, at date: Date = Date()) {
        var entry = entries[minerId, default: Entry()]
        entry.workerStartedAt = entry.workerStartedAt ?? date
        entry.lastStateUpdateAt = date
        entry.metadata.lastEventAt = date
        entry.metadata.workerState = .running
        entry.metadata.isHealthy = true
        entry.metadata.isStalled = false
        entries[minerId] = entry
    }

    public func recordWorkerStop(minerId: String, at date: Date = Date(), failed: Bool = false) {
        var entry = entries[minerId, default: Entry()]
        entry.lastStateUpdateAt = date
        entry.metadata.lastEventAt = date
        entry.metadata.workerState = failed ? .failed : .stopped
        entry.metadata.isHealthy = !failed
        entry.metadata.isStalled = false
        entries[minerId] = entry
    }

    public func recordIssue(minerId: String, cause: StallCause, detail: String, at date: Date = Date()) {
        var entry = entries[minerId, default: Entry()]
        entry.lastIssueCause = cause
        entry.lastIssueDetail = detail
        entry.lastIssueAt = date
        entries[minerId] = entry
    }

    public func recordEvent(minerId: String, at date: Date = Date()) {
        var entry = entries[minerId, default: Entry()]
        entry.metadata.lastEventAt = date
        entries[minerId] = entry
    }

    public func recordStateUpdate(minerId: String, workerState: MinerWorkerState? = nil, at date: Date = Date()) {
        var entry = entries[minerId, default: Entry()]
        entry.lastStateUpdateAt = date
        entry.metadata.lastEventAt = date
        if let workerState {
            entry.metadata.workerState = workerState
        }
        entries[minerId] = entry
    }

    public func recordSuccessfulPoll(minerId: String, at date: Date = Date()) {
        var entry = entries[minerId, default: Entry()]
        entry.metadata.lastSuccessfulPollAt = date
        entry.metadata.lastEventAt = date
        if entry.metadata.workerState == .starting {
            entry.metadata.workerState = .running
        }
        entries[minerId] = entry
    }

    /// Records that the miner banked verified drop progress (watch minutes or a claim).
    /// This is the only signal that distinguishes a miner that is earning from one that
    /// merely looks alive, so it is recorded separately from ordinary liveness events.
    public func recordDropProgress(minerId: String, at date: Date = Date()) {
        var entry = entries[minerId, default: Entry()]
        entry.metadata.lastDropProgressAt = date
        entry.metadata.lastEventAt = date
        entries[minerId] = entry
    }

    public func recordCampaignRefresh(minerId: String, at date: Date = Date()) {
        var entry = entries[minerId, default: Entry()]
        entry.metadata.lastCampaignRefreshAt = date
        entry.metadata.lastEventAt = date
        entry.metadata.workerState = .running
        entries[minerId] = entry
    }

    public func markRecovering(minerId: String, stage: RecoveryStage, at date: Date = Date()) {
        var entry = entries[minerId, default: Entry()]
        entry.lastStateUpdateAt = date
        entry.metadata.lastEventAt = date
        switch stage {
        case .refresh:
            entry.metadata.workerState = .refreshing
        case .restart:
            entry.metadata.workerState = .recovering
        case .authRefresh:
            entry.metadata.workerState = .authRefreshing
        }
        entry.metadata.isHealthy = false
        entries[minerId] = entry
    }

    public func noteRecoverySuccess(minerId: String, at date: Date = Date()) {
        var entry = entries[minerId, default: Entry()]
        entry.metadata.lastEventAt = date
        entry.metadata.isHealthy = true
        entry.metadata.isStalled = false
        entry.metadata.workerState = .running
        entry.nextRecoveryStage = .refresh
        entries[minerId] = entry
    }

    public func noteRecoveryFailure(minerId: String, stage: RecoveryStage, at date: Date = Date()) {
        var entry = entries[minerId, default: Entry()]
        entry.metadata.lastEventAt = date
        entry.metadata.isHealthy = false
        switch stage {
        case .refresh:
            entry.metadata.workerState = .refreshing
            entry.nextRecoveryStage = .restart
        case .restart:
            entry.metadata.workerState = .recovering
            entry.nextRecoveryStage = .authRefresh
        case .authRefresh:
            entry.metadata.workerState = .failed
            entry.nextRecoveryStage = .authRefresh
        }
        entries[minerId] = entry
    }

    public func snapshot(for minerId: String) -> MinerOperationalMetadata? {
        entries[minerId]?.metadata
    }

    public func refreshHealth(for miners: [MinerManager.ManagedMiner], now: Date = Date()) -> [String: MinerOperationalMetadata] {
        let activePeers = Set(
            miners.compactMap { miner -> String? in
                guard miner.isRunning, !miner.needsAuth else { return nil }
                return miner.id
            }
        )

        for miner in miners {
            var entry = entries[miner.id, default: Entry()]
            let hasFreshPeerPoll = activePeers
                .filter { $0 != miner.id }
                .compactMap { entries[$0]?.metadata.lastSuccessfulPollAt }
                .contains { now.timeIntervalSince($0) <= configuration.peerFreshnessWindow }

            let livenessDate = [entry.metadata.lastEventAt, entry.metadata.lastSuccessfulPollAt, entry.lastStateUpdateAt]
                .compactMap { $0 }
                .max()

            let age = livenessDate.map { now.timeIntervalSince($0) } ?? .infinity
            let startupAge = entry.workerStartedAt.map { now.timeIntervalSince($0) } ?? .infinity
            let eligibleForStallDetection = miner.isRunning
                && !miner.needsAuth
                && hasFreshPeerPoll
                && startupAge >= configuration.startupGracePeriod

            let isStalled = eligibleForStallDetection && age >= configuration.stallTimeout
            let isHealthy = !miner.isRunning || miner.needsAuth || (!isStalled && age < configuration.noRecentActivityWindow)

            entry.metadata.isStalled = isStalled
            entry.metadata.isHealthy = isHealthy

            if !miner.isRunning, entry.metadata.workerState != .failed {
                entry.metadata.workerState = .stopped
                entry.metadata.isStalled = false
                entry.metadata.isHealthy = true
            }

            entries[miner.id] = entry
        }

        return Dictionary(uniqueKeysWithValues: miners.compactMap { miner in
            guard let metadata = entries[miner.id]?.metadata else { return nil }
            return (miner.id, metadata)
        })
    }

    public func nextRecoveryAction(for miners: [MinerManager.ManagedMiner], now: Date = Date()) -> RecoveryAction? {
        _ = refreshHealth(for: miners, now: now)

        for miner in miners where miner.isRunning && !miner.needsAuth {
            guard var entry = entries[miner.id], entry.metadata.isStalled else { continue }
            if let cooldown = entry.recoveryCooldownUntil, cooldown > now {
                continue
            }

            let stage = entry.nextRecoveryStage
            entry.recoveryAttemptCount += 1
            entry.lastRecoveryReason = recoveryReason(for: miner, entry: entry, now: now)
            let cooldownScale = pow(2.0, Double(max(0, entry.recoveryAttemptCount - 1)))
            let cooldown = min(configuration.recoveryBaseCooldown * cooldownScale, configuration.recoveryMaxCooldown)
            entry.recoveryCooldownUntil = now.addingTimeInterval(cooldown)
            entries[miner.id] = entry

            return RecoveryAction(
                minerId: miner.id,
                stage: stage,
                reason: entry.lastRecoveryReason ?? "miner has stopped reporting liveness",
                attempt: entry.recoveryAttemptCount
            )
        }

        return nil
    }

    private func recoveryReason(for miner: MinerManager.ManagedMiner, entry: Entry, now: Date) -> String {
        let lastSignal = [entry.metadata.lastEventAt, entry.metadata.lastSuccessfulPollAt, entry.lastStateUpdateAt]
            .compactMap { $0 }
            .max()
        let signalAge = lastSignal.map { Int(now.timeIntervalSince($0) / 60) } ?? -1

        // Prefer the most recent specific issue if it fired within the stall window — it tells
        // the user *why* the miner stopped reporting, not just that it did.
        if let cause = entry.lastIssueCause,
           let issueAt = entry.lastIssueAt,
           now.timeIntervalSince(issueAt) <= configuration.stallTimeout {
            let detail = entry.lastIssueDetail?.trimmingCharacters(in: .whitespacesAndNewlines)
            var fragment = "cause=\(cause.rawValue) • \(cause.displayName)"
            if let detail, !detail.isEmpty {
                fragment += " • \(detail)"
            }
            if signalAge >= 0 {
                fragment += " • silent \(signalAge) min"
            }
            return "\(miner.displayName) — \(fragment)"
        }

        if signalAge >= 0 {
            return "\(miner.displayName) — cause=\(StallCause.noRecentActivity.rawValue) • \(StallCause.noRecentActivity.displayName) • silent \(signalAge) min while peers were polling"
        }
        return "\(miner.displayName) — cause=\(StallCause.workerStartupFailure.rawValue) • \(StallCause.workerStartupFailure.displayName)"
    }
}
