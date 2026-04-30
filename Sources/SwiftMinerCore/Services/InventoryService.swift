import Foundation

public struct InventorySnapshot: Codable, Sendable, Equatable {
    public let accountId: String
    public let benefitIDs: Set<String>
    public let progress: [Progress]
    public let discoveredCampaigns: [Campaign]
    public let lastUpdated: Date

    public init(
        accountId: String,
        benefitIDs: Set<String>,
        progress: [Progress],
        discoveredCampaigns: [Campaign] = [],
        lastUpdated: Date = Date()
    ) {
        self.accountId = accountId
        self.benefitIDs = benefitIDs
        self.progress = progress
        self.discoveredCampaigns = discoveredCampaigns
        self.lastUpdated = lastUpdated
    }

    public static func empty(accountId: String) -> InventorySnapshot {
        InventorySnapshot(accountId: accountId, benefitIDs: [], progress: [], discoveredCampaigns: [], lastUpdated: .distantPast)
    }
}

public actor InventoryService {
    private let apiClient: TwitchAPIClient
    private var accountId: String?
    private var snapshotCache: InventorySnapshot?
    private let cacheDuration: TimeInterval = 60

    public init(apiClient: TwitchAPIClient) {
        self.apiClient = apiClient
    }

    public func setAccountId(_ accountId: String) {
        self.accountId = accountId

        if snapshotCache?.accountId != accountId {
            snapshotCache = InventoryDiskCache.load(accountId: accountId)
        }
    }

    public func fetchInventory(forceRefresh: Bool = false) async throws -> InventorySnapshot {
        guard let accountId else {
            return .empty(accountId: "")
        }

        if !forceRefresh,
           let snapshotCache,
           Date().timeIntervalSince(snapshotCache.lastUpdated) < cacheDuration {
            return snapshotCache
        }

        do {
            let result = try await apiClient.fetchInventory()
            let benefitIDs = Set(await apiClient.getClaimedBenefits().keys)
            let snapshot = InventorySnapshot(
                accountId: accountId,
                benefitIDs: benefitIDs,
                progress: result.progress,
                discoveredCampaigns: result.discoveredCampaigns
            )
            snapshotCache = snapshot
            InventoryDiskCache.save(snapshot)
            return snapshot
        } catch {
            if let cached = await currentSnapshot() {
                return cached
            }
            throw error
        }
    }

    public func currentSnapshot() async -> InventorySnapshot? {
        if let snapshotCache {
            return snapshotCache
        }

        guard let accountId else { return nil }

        let snapshot = InventoryDiskCache.load(accountId: accountId)
        snapshotCache = snapshot
        return snapshot
    }

    /// Checks if a drop is claimed based on its benefit ID.
    /// This uses the cached benefit IDs from the most recent inventory fetch.
    public func isDropClaimed(benefitID: String) async -> Bool {
        guard let snapshot = await currentSnapshot() else { return false }
        return snapshot.benefitIDs.contains(benefitID)
    }

    public func clearCache() {
        guard let accountId else {
            snapshotCache = nil
            return
        }

        snapshotCache = nil
        InventoryDiskCache.clear(accountId: accountId)
    }
}

enum InventoryDiskCache {
    private static let directoryName = "com.swiftminer"
    private static let folderName = "inventory-snapshots"

    private static func fileURL(accountId: String) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(accountId).json")
    }

    static func save(_ snapshot: InventorySnapshot) {
        guard !snapshot.accountId.isEmpty else { return }

        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL(accountId: snapshot.accountId), options: .atomic)
        } catch {
            print("[InventoryDiskCache] Save failed: \(error.localizedDescription)")
        }
    }

    static func load(accountId: String) -> InventorySnapshot? {
        guard !accountId.isEmpty else { return nil }
        guard let data = try? Data(contentsOf: fileURL(accountId: accountId)) else {
            return nil
        }
        return try? JSONDecoder().decode(InventorySnapshot.self, from: data)
    }

    static func clear(accountId: String) {
        guard !accountId.isEmpty else { return }
        try? FileManager.default.removeItem(at: fileURL(accountId: accountId))
    }

    static func clearAll() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
    }
}
