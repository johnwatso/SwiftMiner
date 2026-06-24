import Foundation
import SwiftUI
import SwiftMinerCore

@MainActor
final class UnattendedHealthModel: ObservableObject {
    @Published private(set) var snapshots: [UnattendedHealthSnapshot] = []

    var summary: UnattendedHealthSummary {
        UnattendedHealthSummary(snapshots: snapshots)
    }

    private let store: UnattendedHealthStore?
    private let notificationService: UnattendedIncidentNotificationService?
    private var monitorTask: Task<Void, Never>?

    init(store: UnattendedHealthStore?) {
        self.store = store
        self.notificationService = store.map {
            UnattendedIncidentNotificationService(store: $0)
        }
    }

    func startMonitoring() {
        guard store != nil, monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    func refresh() async {
        guard let store else {
            snapshots = []
            return
        }
        snapshots = await store.allSnapshots()
        await notificationService?.deliverPendingNotifications()
        snapshots = await store.allSnapshots()
    }

    func recordSystemIncident(
        id: String,
        displayName: String,
        kind: HealthIncident.Kind,
        severity: HealthIncident.Severity,
        summary: String,
        recommendedAction: String?
    ) async {
        guard let store else { return }
        let observedAt = Date()
        try? await store.record(.minerObserved(
            minerID: id,
            displayName: displayName,
            at: observedAt
        ))
        try? await store.record(.incidentObserved(
            minerID: id,
            kind: kind,
            severity: severity,
            summary: summary,
            recommendedAction: recommendedAction,
            at: observedAt
        ))
        await refresh()
    }

    func resolveSystemIncident(
        id: String,
        kind: HealthIncident.Kind
    ) async {
        guard let store else { return }
        try? await store.record(.incidentResolved(
            minerID: id,
            kind: kind,
            at: Date()
        ))
        await refresh()
    }
}
