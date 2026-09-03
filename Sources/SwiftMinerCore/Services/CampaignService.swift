import Foundation

/// Stateless service for fetching and enriching Twitch drop campaigns.
public enum CampaignService {
    
    /// Fetch all drop campaigns and enrich them with account-specific inventory data.
    /// - Parameters:
    ///   - apiClient: The authenticated API client to use for the fetch.
    ///   - inventoryService: The account-specific inventory service for enrichment.
    /// - Returns: The enriched campaigns and the inventory snapshot they were merged against.
    ///   The snapshot is returned rather than re-read by the caller so that every decision in
    ///   one refresh — enrichment, and the caller's own preservation pass — is made against
    ///   the same account state.
    public static func fetchCampaigns(
        using apiClient: TwitchAPIClient,
        inventoryService: InventoryService,
        forceInventoryRefresh: Bool = false
    ) async throws -> (campaigns: [Campaign], inventory: InventorySnapshot) {
        // Parallelize fetching campaigns and inventory to speed up discovery
        async let campaignsTask = apiClient.fetchDropCampaigns()
        async let inventoryTask: InventorySnapshot = {
            if forceInventoryRefresh {
                // The post-claim campaign refresh must not reconcile restored definitions
                // against a pre-claim snapshot. A forced inventory failure is safer to
                // surface than to make a mining decision from stale claimed state.
                return try await inventoryService.fetchInventory(forceRefresh: true)
            }
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

        // Inventory can be the sole source for campaigns omitted by the dashboard. Route
        // those entities through the same refresh policy too; otherwise reconciliation only
        // protects dashboard-backed campaigns.
        var reconciled: [Campaign] = []
        reconciled.reserveCapacity(allCampaigns.count)
        for campaign in allCampaigns {
            reconciled.append(await apiClient.reconcilingCampaign(campaign))
        }

        return (DropsService.mergeInventory(snapshot, into: reconciled), snapshot)
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
