import Foundation

/// Fetches Twitch drop campaigns independently of any specific account session.
///
/// `CampaignService` is the single source of truth for campaign discovery.
/// It wraps `TwitchAPIClient.fetchDropCampaigns()` and is configured with
/// an API client once an account authenticates. Before configuration, all
/// fetch calls return an empty array.
public actor CampaignService {
    private var apiClient: TwitchAPIClient?

    public init() {}

    /// Wire up an authenticated API client.
    /// Call this after a user authenticates so campaign fetches can proceed.
    public func configure(apiClient: TwitchAPIClient) {
        self.apiClient = apiClient
    }

    /// Remove the API client (e.g. on logout).
    public func deconfigure() {
        self.apiClient = nil
    }

    /// Whether a client has been configured.
    public var isConfigured: Bool { apiClient != nil }

    /// Fetch all drop campaigns. Returns `[]` if no client has been configured.
    public func fetchCampaigns() async throws -> [Campaign] {
        guard let client = apiClient else { return [] }
        return try await client.fetchDropCampaigns()
    }
}
