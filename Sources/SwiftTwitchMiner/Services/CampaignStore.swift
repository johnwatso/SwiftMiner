import Foundation

/// Observable store for Twitch drop campaigns.
///
/// `CampaignStore` is the single observable source of campaign data for the UI.
/// It owns a `CampaignService`, auto-refreshes every 5 minutes, and is
/// independent of account-specific mining state.
///
/// Usage:
/// 1. Create once at app startup and inject via environment.
/// 2. Call `configure(apiClient:)` after a user authenticates.
/// 3. Bind UI directly to `campaigns`.
@Observable
@MainActor
public final class CampaignStore {

    // MARK: - Public state

    public private(set) var campaigns: [Campaign] = []
    public private(set) var isLoading = false
    public private(set) var lastError: Error?

    // MARK: - Private

    private let service: CampaignService
    private var refreshTask: Task<Void, Never>?
    private let refreshInterval: TimeInterval = 300 // 5 minutes

    // MARK: - Init

    public init(service: CampaignService = CampaignService()) {
        self.service = service
        // Load cached campaigns immediately so the UI has data before the first API call
        campaigns = CampaignDiskCache.load()
        if !campaigns.isEmpty {
            print("[CampaignStore] Loaded \(campaigns.count) cached campaigns from disk")
        }
    }

    // MARK: - Configuration

    /// Provide an authenticated API client, then immediately refresh campaigns
    /// and start the auto-refresh timer.
    public func configure(apiClient: TwitchAPIClient) async {
        await service.configure(apiClient: apiClient)
        await refresh()
        startAutoRefresh()
    }

    /// Remove the API client and clear campaign data (e.g. on logout).
    public func deconfigure() async {
        stopAutoRefresh()
        await service.deconfigure()
        campaigns = []
        CampaignDiskCache.clear()
        lastError = nil
    }

    // MARK: - Refresh

    /// Manually trigger a campaign refresh.
    public func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await service.fetchCampaigns()
            campaigns = fetched
            lastError = nil
            CampaignDiskCache.save(fetched)
            print("[CampaignStore] Refreshed: \(fetched.count) campaigns")
        } catch {
            lastError = error
            print("[CampaignStore] Refresh failed: \(error)")
        }
    }

    // MARK: - Auto-refresh

    private func startAutoRefresh() {
        stopAutoRefresh()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64((self?.refreshInterval ?? 300) * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }
    }

    public func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }
}

// MARK: - Campaign Disk Cache

/// Persists campaigns to disk so the UI has data immediately on relaunch
/// without waiting for a fresh API call. Campaigns are non-sensitive
/// (publicly available Twitch data), so no encryption is needed.
enum CampaignDiskCache {
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
            print("[CampaignDiskCache] Save failed: \(error.localizedDescription)")
        }
    }

    static func load() -> [Campaign] {
        guard let data = try? Data(contentsOf: fileURL),
              let envelope = try? JSONDecoder().decode(CacheEnvelope.self, from: data) else {
            return []
        }
        // Discard stale cache
        guard Date().timeIntervalSince(envelope.savedAt) < maxAge else {
            print("[CampaignDiskCache] Cache expired, ignoring")
            return []
        }
        return envelope.campaigns
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
