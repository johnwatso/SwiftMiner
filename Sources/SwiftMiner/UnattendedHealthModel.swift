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
    private var monitorTask: Task<Void, Never>?

    init(store: UnattendedHealthStore?) {
        self.store = store
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
    }
}
