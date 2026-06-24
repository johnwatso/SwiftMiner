import Foundation

public actor UnattendedHealthStore {
    private struct PersistedState: Codable {
        static let currentSchemaVersion = 1

        var schemaVersion = currentSchemaVersion
        var snapshots: [String: UnattendedHealthSnapshot] = [:]
        var incidentHistory: [HealthIncident] = []
        var recoveryHistory: [String: [RecoveryRecord]] = [:]
    }

    private let fileURL: URL
    private let maxIncidentHistory: Int
    private let maxRecoveryHistoryPerMiner: Int
    private var state: PersistedState

    public init(
        fileURL: URL,
        maxIncidentHistory: Int = 200,
        maxRecoveryHistoryPerMiner: Int = 50
    ) {
        self.fileURL = fileURL
        self.maxIncidentHistory = max(1, maxIncidentHistory)
        self.maxRecoveryHistoryPerMiner = max(1, maxRecoveryHistoryPerMiner)
        self.state = Self.loadState(from: fileURL)
    }

    public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("SwiftMiner", isDirectory: true)
            .appendingPathComponent("unattended-health.json")
    }

    public func record(_ event: UnattendedHealthEvent) throws {
        switch event {
        case let .minerObserved(minerID, displayName, at):
            var snapshot = snapshot(for: minerID, displayName: displayName, at: at)
            snapshot.displayName = displayName
            snapshot.updatedAt = at
            state.snapshots[minerID] = snapshot

        case let .miningProgressObserved(minerID, at):
            var snapshot = snapshot(for: minerID, at: at)
            snapshot.lastMiningProgressAt = at
            markOperatingNormally(&snapshot, at: at)
            state.snapshots[minerID] = snapshot

        case let .twitchResponseSucceeded(minerID, at):
            var snapshot = snapshot(for: minerID, at: at)
            snapshot.lastTwitchResponseAt = at
            snapshot.updatedAt = at
            state.snapshots[minerID] = snapshot

        case let .recoveryStarted(minerID, stage, detail, at):
            var snapshot = snapshot(for: minerID, at: at)
            snapshot.lastRecovery = RecoveryRecord(stage: stage, startedAt: at, detail: detail)
            snapshot.operatingNormallySince = nil
            snapshot.updatedAt = at
            state.snapshots[minerID] = snapshot

        case let .recoveryFinished(minerID, stage, succeeded, detail, at):
            var snapshot = snapshot(for: minerID, at: at)
            var recovery = matchingRecovery(in: snapshot, stage: stage, at: at)
            recovery.finishedAt = at
            recovery.succeeded = succeeded
            recovery.detail = detail ?? recovery.detail
            snapshot.lastRecovery = recovery
            if succeeded, snapshot.activeIncident == nil {
                snapshot.operatingNormallySince = at
            }
            snapshot.updatedAt = at
            state.snapshots[minerID] = snapshot
            appendRecovery(recovery, minerID: minerID)

        case let .incidentObserved(minerID, kind, severity, summary, recommendedAction, at):
            var snapshot = snapshot(for: minerID, at: at)
            let incidentID = HealthIncident.stableID(minerID: minerID, kind: kind)
            if var incident = snapshot.activeIncident, incident.id == incidentID {
                incident.lastObservedAt = at
                incident.severity = severity
                incident.summary = summary
                incident.recommendedAction = recommendedAction
                snapshot.activeIncident = incident
            } else {
                if var previous = snapshot.activeIncident {
                    previous.resolvedAt = at
                    appendIncident(previous)
                }
                snapshot.activeIncident = HealthIncident(
                    id: incidentID,
                    minerID: minerID,
                    kind: kind,
                    severity: severity,
                    openedAt: at,
                    lastObservedAt: at,
                    summary: summary,
                    recommendedAction: recommendedAction
                )
            }
            snapshot.operatingNormallySince = nil
            snapshot.updatedAt = at
            state.snapshots[minerID] = snapshot

        case let .incidentResolved(minerID, kind, at):
            var snapshot = snapshot(for: minerID, at: at)
            let incidentID = HealthIncident.stableID(minerID: minerID, kind: kind)
            if var incident = snapshot.activeIncident, incident.id == incidentID {
                resolve(incident: &incident, snapshot: &snapshot, at: at)
            }

        case let .activeIncidentResolved(minerID, at):
            var snapshot = snapshot(for: minerID, at: at)
            if var incident = snapshot.activeIncident {
                resolve(incident: &incident, snapshot: &snapshot, at: at)
            }

        case let .notificationSent(minerID, kind, at):
            var snapshot = snapshot(for: minerID, at: at)
            let incidentID = HealthIncident.stableID(minerID: minerID, kind: kind)
            if var incident = snapshot.activeIncident, incident.id == incidentID {
                incident.notificationSentAt = at
                snapshot.activeIncident = incident
                snapshot.updatedAt = at
                state.snapshots[minerID] = snapshot
            }
        }

        try persist()
    }

    public func snapshot(for minerID: String) -> UnattendedHealthSnapshot? {
        state.snapshots[minerID]
    }

    public func allSnapshots() -> [UnattendedHealthSnapshot] {
        state.snapshots.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    public func incidentsAwaitingNotification() -> [(incident: HealthIncident, displayName: String)] {
        state.snapshots.values.compactMap { snapshot in
            guard let incident = snapshot.activeIncident,
                  incident.notificationSentAt == nil else {
                return nil
            }
            return (incident, snapshot.displayName)
        }
        .sorted { $0.incident.openedAt < $1.incident.openedAt }
    }

    public func incidents(since date: Date? = nil) -> [HealthIncident] {
        state.incidentHistory
            .filter { date == nil || $0.lastObservedAt >= date! }
            .sorted { $0.lastObservedAt > $1.lastObservedAt }
    }

    public func recoveries(for minerID: String, since date: Date? = nil) -> [RecoveryRecord] {
        (state.recoveryHistory[minerID] ?? [])
            .filter { date == nil || ($0.finishedAt ?? $0.startedAt) >= date! }
            .sorted { ($0.finishedAt ?? $0.startedAt) > ($1.finishedAt ?? $1.startedAt) }
    }

    public func reset() throws {
        state = PersistedState()
        try persist()
    }

    private func snapshot(
        for minerID: String,
        displayName: String? = nil,
        at: Date
    ) -> UnattendedHealthSnapshot {
        state.snapshots[minerID] ?? UnattendedHealthSnapshot(
            id: minerID,
            displayName: displayName ?? minerID,
            updatedAt: at
        )
    }

    private func markOperatingNormally(_ snapshot: inout UnattendedHealthSnapshot, at: Date) {
        if snapshot.activeIncident == nil, snapshot.operatingNormallySince == nil {
            snapshot.operatingNormallySince = at
        }
        snapshot.updatedAt = at
    }

    private func matchingRecovery(
        in snapshot: UnattendedHealthSnapshot,
        stage: RecoveryRecord.Stage,
        at: Date
    ) -> RecoveryRecord {
        if let recovery = snapshot.lastRecovery,
           recovery.stage == stage,
           recovery.finishedAt == nil {
            return recovery
        }
        return RecoveryRecord(stage: stage, startedAt: at)
    }

    private func appendIncident(_ incident: HealthIncident) {
        state.incidentHistory.removeAll { $0.id == incident.id && $0.openedAt == incident.openedAt }
        state.incidentHistory.append(incident)
        if state.incidentHistory.count > maxIncidentHistory {
            state.incidentHistory.sort { $0.lastObservedAt > $1.lastObservedAt }
            state.incidentHistory.removeLast(state.incidentHistory.count - maxIncidentHistory)
        }
    }

    private func resolve(
        incident: inout HealthIncident,
        snapshot: inout UnattendedHealthSnapshot,
        at: Date
    ) {
        incident.resolvedAt = at
        appendIncident(incident)
        snapshot.activeIncident = nil
        snapshot.operatingNormallySince = at
        snapshot.updatedAt = at
        state.snapshots[snapshot.id] = snapshot
    }

    private func appendRecovery(_ recovery: RecoveryRecord, minerID: String) {
        var history = state.recoveryHistory[minerID] ?? []
        history.removeAll { $0.id == recovery.id }
        history.append(recovery)
        history.sort { ($0.finishedAt ?? $0.startedAt) > ($1.finishedAt ?? $1.startedAt) }
        if history.count > maxRecoveryHistoryPerMiner {
            history.removeLast(history.count - maxRecoveryHistoryPerMiner)
        }
        state.recoveryHistory[minerID] = history
    }

    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: fileURL, options: .atomic)
    }

    private static func loadState(from fileURL: URL) -> PersistedState {
        guard let data = try? Data(contentsOf: fileURL) else {
            return PersistedState()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(PersistedState.self, from: data),
              decoded.schemaVersion == PersistedState.currentSchemaVersion else {
            return PersistedState()
        }
        return decoded
    }
}
