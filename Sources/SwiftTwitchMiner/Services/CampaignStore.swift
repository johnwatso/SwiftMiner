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
