import Foundation

/// Stateless service for fetching and enriching Twitch drop campaigns.
public enum CampaignService {
    
    /// Fetch all drop campaigns and enrich them with account-specific inventory data.
    /// - Parameters:
    ///   - apiClient: The authenticated API client to use for the fetch.
    ///   - inventoryService: The account-specific inventory service for enrichment.
    /// - Returns: Array of enriched Campaign objects.
    public static func fetchCampaigns(
        using apiClient: TwitchAPIClient,
        inventoryService: InventoryService
    ) async throws -> [Campaign] {
        let campaigns = try await apiClient.fetchDropCampaigns()

        // Fetch inventory once - fallback to cached snapshot on failure
        let snapshot: InventorySnapshot
        do {
            snapshot = try await inventoryService.fetchInventory()
        } catch {
            snapshot = await inventoryService.currentSnapshot() ?? .empty(accountId: "")
        }

        return DropsService.mergeInventory(snapshot, into: campaigns)
    }
}
