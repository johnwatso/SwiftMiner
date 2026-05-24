import Foundation
import SwiftMinerCore

@MainActor
final class RewardsLedgerStore: ObservableObject {
    struct Entry: Codable, Identifiable, Equatable {
        let id: String
        let dropId: String
        let dropName: String
        let campaignName: String?
        let gameName: String?
        let minerId: String
        let accountId: String
        let accountName: String
        let claimedAt: Date
    }

    static let shared = RewardsLedgerStore()

    @Published private(set) var entries: [Entry] = []

    private let storageKey = "rewardsLedgerEntriesData"
    private let maxEntries = 1_000

    private init() {
        load()
    }

    func record(drop: Drop, miner: MinerManager.ManagedMiner, campaign: Campaign?, campaignName: String?) {
        let entry = Entry(
            id: "\(miner.accountId)-\(drop.id)",
            dropId: drop.id,
            dropName: drop.name,
            campaignName: campaign?.name ?? campaignName,
            gameName: campaign?.game.name,
            minerId: miner.id,
            accountId: miner.accountId,
            accountName: miner.displayName,
            claimedAt: Date()
        )

        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    func exportPayload() -> [Entry] {
        entries
    }

    func replace(with entries: [Entry]) {
        self.entries = Array(entries.sorted { $0.claimedAt > $1.claimedAt }.prefix(maxEntries))
        save()
    }

    private func load() {
        guard let dataString = Settings.appStorageStore.string(forKey: storageKey),
              let data = dataString.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else {
            entries = []
            return
        }
        entries = decoded.sorted { $0.claimedAt > $1.claimedAt }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries),
              let string = String(data: data, encoding: .utf8) else { return }
        Settings.appStorageStore.set(string, forKey: storageKey)
    }
}
