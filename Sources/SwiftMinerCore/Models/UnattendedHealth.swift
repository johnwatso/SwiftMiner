import Foundation

public struct UnattendedHealthSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var displayName: String
    public var lastMiningProgressAt: Date?
    public var lastTwitchResponseAt: Date?
    public var lastRecovery: RecoveryRecord?
    public var operatingNormallySince: Date?
    public var activeIncident: HealthIncident?
    public var updatedAt: Date

    public init(
        id: String,
        displayName: String,
        lastMiningProgressAt: Date? = nil,
        lastTwitchResponseAt: Date? = nil,
        lastRecovery: RecoveryRecord? = nil,
        operatingNormallySince: Date? = nil,
        activeIncident: HealthIncident? = nil,
        updatedAt: Date
    ) {
        self.id = id
        self.displayName = displayName
        self.lastMiningProgressAt = lastMiningProgressAt
        self.lastTwitchResponseAt = lastTwitchResponseAt
        self.lastRecovery = lastRecovery
        self.operatingNormallySince = operatingNormallySince
        self.activeIncident = activeIncident
        self.updatedAt = updatedAt
    }
}

public struct RecoveryRecord: Codable, Sendable, Equatable, Identifiable {
    public enum Stage: String, Codable, Sendable {
        case campaignRefresh
        case channelSwitch
        case workerRestart
        case authenticationRefresh
        case other
    }

    public let id: UUID
    public let stage: Stage
    public let startedAt: Date
    public var finishedAt: Date?
    public var succeeded: Bool?
    public var detail: String?

    public init(
        id: UUID = UUID(),
        stage: Stage,
        startedAt: Date,
        finishedAt: Date? = nil,
        succeeded: Bool? = nil,
        detail: String? = nil
    ) {
        self.id = id
        self.stage = stage
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.succeeded = succeeded
        self.detail = detail
    }
}

public struct HealthIncident: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case authenticationExpired
        case recoveryExhausted
        case progressStalled
        /// Watching, responsive, but banking no drop progress. Kept separate from
        /// `progressStalled` (which means the supervisor lost the miner entirely) because
        /// they have different causes, and because this one is not yet notification-worthy.
        case notEarning
        case webDashboardUnavailable
        case automaticUpdateFailed
        case accountLinkRequired
        case channelChecksIncompatible
        case other

        /// Where each signal sits on the promotion path. Adding a case forces this choice;
        /// new ones belong at `.displayed` until live data earns them a promotion.
        public var deliveryStage: DeliveryStage {
            switch self {
            // Long-standing signals with a known, specific cause and a clear user action.
            case .authenticationExpired,
                 .recoveryExhausted,
                 .progressStalled,
                 .webDashboardUnavailable,
                 .automaticUpdateFailed:
                return .alerted
            // Added in 1.34.3. It can flag every miner at once and its false-positive rate
            // is still unmeasured, because the ledger that would measure it was itself
            // wrong until 1.34.5. Promote only once that data says it is precise.
            case .notEarning:
                return .displayed
            // Added in 1.38.4, and alerted rather than displayed despite the rule above,
            // because the signal is raised only for a Twitch compatibility failure — a
            // query shape Twitch no longer accepts. That has no transient cause: a blip or
            // an outage classifies as a network error and never reaches here. While it
            // lasts, SwiftMiner cannot tell whether a restricted campaign's channels are
            // live, so esports drop windows pass unnoticed while everything else looks
            // healthy. Silence is the failure mode being fixed; displaying it would repeat
            // the miss on 2026-08-18, when 266 failures produced no user-visible signal.
            case .channelChecksIncompatible:
                return .alerted
            case .accountLinkRequired, .other:
                return .displayed
            }
        }
    }

    public enum Severity: String, Codable, Sendable {
        case warning
        case critical
    }

    /// How far a signal has been promoted towards interrupting the user.
    ///
    /// Every new signal starts at `.displayed` and is only promoted to `.alerted` once real
    /// data shows it is precise enough to be worth a notification. Going straight to
    /// `.alerted` means guessing with someone's notification centre: a signal that fires on
    /// every miner at once is noise, and its false-positive rate cannot be known before it
    /// has run against live data. Demote rather than tolerate a noisy alert.
    public enum DeliveryStage: Sendable {
        /// Kept in the health store for diagnostics only.
        case recorded
        /// Shown in the app, status labels and the diagnostic report. Where new signals start.
        case displayed
        /// Also worth interrupting the user for.
        case alerted
    }

    public let id: String
    public let minerID: String
    public let kind: Kind
    public var severity: Severity
    public let openedAt: Date
    public var lastObservedAt: Date
    public var resolvedAt: Date?
    public var notificationSentAt: Date?
    public var summary: String
    public var recommendedAction: String?

    public init(
        id: String,
        minerID: String,
        kind: Kind,
        severity: Severity,
        openedAt: Date,
        lastObservedAt: Date,
        resolvedAt: Date? = nil,
        notificationSentAt: Date? = nil,
        summary: String,
        recommendedAction: String? = nil
    ) {
        self.id = id
        self.minerID = minerID
        self.kind = kind
        self.severity = severity
        self.openedAt = openedAt
        self.lastObservedAt = lastObservedAt
        self.resolvedAt = resolvedAt
        self.notificationSentAt = notificationSentAt
        self.summary = summary
        self.recommendedAction = recommendedAction
    }

    public static func stableID(minerID: String, kind: Kind) -> String {
        "\(minerID):\(kind.rawValue)"
    }
}

public enum UnattendedHealthEvent: Sendable, Equatable {
    case minerObserved(minerID: String, displayName: String, at: Date)
    case miningProgressObserved(minerID: String, at: Date)
    case twitchResponseSucceeded(minerID: String, at: Date)
    case recoveryStarted(minerID: String, stage: RecoveryRecord.Stage, detail: String?, at: Date)
    case recoveryFinished(minerID: String, stage: RecoveryRecord.Stage, succeeded: Bool, detail: String?, at: Date)
    case incidentObserved(
        minerID: String,
        kind: HealthIncident.Kind,
        severity: HealthIncident.Severity,
        summary: String,
        recommendedAction: String?,
        at: Date
    )
    case incidentResolved(minerID: String, kind: HealthIncident.Kind, at: Date)
    case activeIncidentResolved(minerID: String, at: Date)
    case notificationSent(minerID: String, kind: HealthIncident.Kind, at: Date)
}

public struct UnattendedHealthSummary: Sendable, Equatable {
    public let operatingNormallySince: Date?
    public let lastMiningProgressAt: Date?
    public let lastTwitchResponseAt: Date?
    public let lastRecovery: RecoveryRecord?
    public let activeIncidents: [HealthIncident]

    public init(snapshots: [UnattendedHealthSnapshot]) {
        lastMiningProgressAt = snapshots.compactMap(\.lastMiningProgressAt).max()
        lastTwitchResponseAt = snapshots.compactMap(\.lastTwitchResponseAt).max()
        lastRecovery = snapshots
            .compactMap(\.lastRecovery)
            .max { ($0.finishedAt ?? $0.startedAt) < ($1.finishedAt ?? $1.startedAt) }
        activeIncidents = snapshots
            .compactMap(\.activeIncident)
            .sorted { $0.openedAt < $1.openedAt }

        let healthySinceDates = snapshots.compactMap(\.operatingNormallySince)
        if activeIncidents.isEmpty,
           !snapshots.isEmpty,
           healthySinceDates.count == snapshots.count {
            operatingNormallySince = healthySinceDates.max()
        } else {
            operatingNormallySince = nil
        }
    }
}
