import Foundation

public actor UnattendedHealthStore {
    /// IDs of snapshots that describe the app rather than a miner, such as automatic updates.
    /// They outlive any miner, so pruning leaves them alone.
    public static let systemSnapshotPrefix = "system:"

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

    /// Drops the live state of miners that no longer exist, keeping system entries.
    ///
    /// Miner IDs are minted per launch, so every relaunch used to leave its miners' snapshots
    /// behind for good. They were not just clutter: the summary reports a healthy duration only
    /// when every snapshot has one, so stale entries hid it permanently, and each made every
    /// write of this file larger. An incident still open on a dropped miner is archived as
    /// ended when it was last observed, so the history keeps it.
    public func retainMinerSnapshots(activeMinerIDs: Set<String>) throws {
        let staleIDs = state.snapshots.keys.filter { id in
            !activeMinerIDs.contains(id) && !id.hasPrefix(Self.systemSnapshotPrefix)
        }
        guard !staleIDs.isEmpty else { return }

        for id in staleIDs {
            if var incident = state.snapshots[id]?.activeIncident {
                incident.resolvedAt = incident.lastObservedAt
                appendIncident(incident)
            }
            state.snapshots.removeValue(forKey: id)
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

    /// Reads the persisted history, falling back to an empty store when there is nothing usable.
    ///
    /// Every fallback used to look identical — `try?` turned a first launch, an unreadable file,
    /// and a truncated one all into "no history", and the next `persist()` overwrote the evidence.
    /// Since the incident history is what an operator reads back after an unattended failure,
    /// losing it silently is the worst possible outcome, so each cause is now logged and a file
    /// we could not decode is moved aside instead of being overwritten.
    private static func loadState(from fileURL: URL) -> PersistedState {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            // First launch, or the support directory was cleared. Nothing to report.
            return PersistedState()
        } catch {
            Logger.storage.error("Unattended health history at \(fileURL.path) could not be read (\(error.localizedDescription)); starting from an empty history")
            return PersistedState()
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded: PersistedState
        do {
            decoded = try decoder.decode(PersistedState.self, from: data)
        } catch {
            Logger.storage.error("Unattended health history at \(fileURL.path) is corrupt (\(error.localizedDescription)); quarantining it and starting from an empty history")
            quarantine(fileURL)
            return PersistedState()
        }

        guard decoded.schemaVersion == PersistedState.currentSchemaVersion else {
            Logger.storage.warning("Unattended health history at \(fileURL.path) uses schema \(decoded.schemaVersion), expected \(PersistedState.currentSchemaVersion); starting from an empty history")
            quarantine(fileURL)
            return PersistedState()
        }

        return decoded
    }

    /// Renames an unusable history file out of the way so the next `persist()` cannot destroy it.
    private static func quarantine(_ fileURL: URL) {
        let quarantined = fileURL.deletingPathExtension()
            .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            .appendingPathExtension(fileURL.pathExtension)
        do {
            try FileManager.default.moveItem(at: fileURL, to: quarantined)
            Logger.storage.info("Moved unusable unattended health history to \(quarantined.path)")
        } catch {
            Logger.storage.error("Could not move unusable unattended health history aside: \(error.localizedDescription)")
        }
    }
}
