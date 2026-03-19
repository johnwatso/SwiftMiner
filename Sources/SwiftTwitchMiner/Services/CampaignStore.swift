import Foundation

/// Observable store for Twitch drop campaigns.
///
/// `CampaignStore` is the single observable source of campaign data for the UI.
/// It owns a `CampaignService`, auto-refreshes every 5 minutes, and is
/// independent of account-specific mining state.
///
/// Usage:
/// 1. Create once at app startup and inject via environment.
/// 2. Call `configure(apiClient:accountId:)` after a user authenticates.
/// 3. Bind UI directly to `campaigns`.
@Observable
@MainActor
public final class CampaignStore {

    // MARK: - Public state

    public var campaigns: [Campaign] = []
    public var isLoading = false
    public var lastError: Error?

    // MARK: - Init

    public init() {
        // Load cached campaigns immediately so the UI has data before the first API call
        campaigns = CampaignStoreDiskCache.load()
        if !campaigns.isEmpty {
            print("[CampaignStore] Loaded \(campaigns.count) cached campaigns from disk")
        }
    }

    // MARK: - Data Update

    /// Update the store with a new list of campaigns.
    /// This should be called by the aggregator (CampaignDataService).
    public func updateCampaigns(_ newCampaigns: [Campaign]) {
        self.campaigns = newCampaigns
        CampaignStoreDiskCache.save(newCampaigns)
    }
}

// MARK: - Campaign Disk Cache

/// Persists campaigns to disk so the UI has data immediately on relaunch
/// without waiting for a fresh API call. Campaigns are non-sensitive
/// (publicly available Twitch data), so no encryption is needed.
enum CampaignStoreDiskCache {
    private static let directoryName = "com.swifttwitchminer"
    private static let fileName = "campaigns-cache.json"
    /// Cache expires after 1 hour — stale campaigns are discarded on load
    private static let maxAge: TimeInterval = 3600

    private struct CacheEnvelope: Codable {
        let savedAt: Date
        let campaigns: [Campaign]
    }

    private static var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    static func save(_ campaigns: [Campaign]) {
        do {
            let envelope = CacheEnvelope(savedAt: Date(), campaigns: campaigns)
            let data = try JSONEncoder().encode(envelope)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[CampaignStoreDiskCache] Save failed: \(error.localizedDescription)")
        }
    }

    static func load() -> [Campaign] {
        guard let data = try? Data(contentsOf: fileURL),
              let envelope = try? JSONDecoder().decode(CacheEnvelope.self, from: data) else {
            return []
        }
        // Discard stale cache
        guard Date().timeIntervalSince(envelope.savedAt) < maxAge else {
            print("[CampaignStoreDiskCache] Cache expired, ignoring")
            return []
        }
        return envelope.campaigns
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
