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
        for discovered in snapshot.discoveredCampaigns {
            if let index = allCampaigns.firstIndex(where: { $0.id == discovered.id }) {
                let existing = allCampaigns[index]
                let merged = mergeDashboardCampaign(existing, withInventory: discovered)
                if merged.isAccountConnected && !existing.isAccountConnected {
                    Logger.campaigns.info("Inventory confirmed connection for \(discovered.name)")
                }
                if existing.channels.isEmpty && !merged.channels.isEmpty {
                    Logger.campaigns.info("Inventory supplied \(merged.channels.count) approved channel(s) for \(discovered.name)")
                }
                allCampaigns[index] = merged
            } else {
                Logger.campaigns.info("Discovered campaign from inventory: \(discovered.name)")
                allCampaigns.append(discovered)
            }
        }

        return DropsService.mergeInventory(snapshot, into: allCampaigns)
    }

    /// Combines the broad dashboard campaign with account-specific Inventory metadata.
    /// Inventory is allowed to fill fields that the dashboard omitted, especially approved
    /// channels for short-lived esports campaigns.
    internal static func mergeDashboardCampaign(
        _ dashboard: Campaign,
        withInventory inventory: Campaign
    ) -> Campaign {
        Campaign(
            id: dashboard.id,
            name: dashboard.name.isEmpty ? inventory.name : dashboard.name,
            game: dashboard.game.name.isEmpty ? inventory.game : dashboard.game,
            status: dashboard.status,
            startDate: dashboard.startDate,
            endDate: dashboard.endDate,
            drops: dashboard.drops.isEmpty ? inventory.drops : dashboard.drops,
            channels: dashboard.channels.isEmpty ? inventory.channels : dashboard.channels,
            isAccountConnected: dashboard.isAccountConnected || inventory.isAccountConnected,
            allowIsEnabled: dashboard.allowIsEnabled ?? inventory.allowIsEnabled,
            isPrioritised: dashboard.isPrioritised
        )
    }
}
