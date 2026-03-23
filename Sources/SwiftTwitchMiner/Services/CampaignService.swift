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
        // Parallelize fetching campaigns and inventory to speed up discovery
        async let campaignsTask = apiClient.fetchDropCampaigns()
        async let inventoryTask: InventorySnapshot = {
            do {
                return try await inventoryService.fetchInventory()
            } catch {
                return await inventoryService.currentSnapshot() ?? .empty(accountId: "")
            }
        }()

        let (dashboardCampaigns, snapshot) = try await (campaignsTask, inventoryTask)
        
        // Merge discovered campaigns from inventory (some campaigns like CDL are missing from dashboard)
        // Also trust inventory for isAccountConnected status (often more accurate than dashboard)
        var allCampaigns = dashboardCampaigns
        let dashboardIds = Set(dashboardCampaigns.map { $0.id })
        
        for discovered in snapshot.discoveredCampaigns {
            if let index = allCampaigns.firstIndex(where: { $0.id == discovered.id }) {
                // If inventory says we are connected, trust it! 
                // This fix addresses the CDL Major 2 "false negative" where dashboard says false but inventory shows progress.
                if discovered.isAccountConnected && !allCampaigns[index].isAccountConnected {
                    print("[CampaignService] Inventory confirmed connection for \(discovered.name)")
                    let existing = allCampaigns[index]
                    allCampaigns[index] = Campaign(
                        id: existing.id,
                        name: existing.name,
                        game: existing.game,
                        status: existing.status,
                        startDate: existing.startDate,
                        endDate: existing.endDate,
                        drops: existing.drops,
                        channels: existing.channels,
                        isAccountConnected: true,
                        isPrioritised: existing.isPrioritised
                    )
                }
            } else {
                print("[CampaignService] Discovered campaign from inventory: \(discovered.name)")
                allCampaigns.append(discovered)
            }
        }

        return DropsService.mergeInventory(snapshot, into: allCampaigns)
    }
}
