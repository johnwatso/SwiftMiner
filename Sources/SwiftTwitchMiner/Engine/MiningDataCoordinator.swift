import Foundation

/// Coordinates data flow between multiple miners and the shared CampaignStore.
/// 
/// This class:
/// 1. Creates per-account CampaignDataServices
/// 2. Registers them with AggregatedCampaignDataService
/// 3. Pushes aggregated results to CampaignStore for UI display
/// 4. Handles lifecycle (add/remove miners)
@MainActor
public final class MiningDataCoordinator {
    
    // MARK: - Properties
    
    private let campaignStore: CampaignStore
    private let aggregatedService: AggregatedCampaignDataService
    
    /// Track per-miner data services
    private var minerDataServices: [String: CampaignDataService] = [:]

    /// Track per-miner engines for querying active campaign state
    private var minerEngines: [String: MinerEngine] = [:]

    /// Account ID lookup by miner ID
    private var minerAccountIds: [String: String] = [:]
    
    // MARK: - Initialization
    
    public init(campaignStore: CampaignStore) {
        self.campaignStore = campaignStore
        self.aggregatedService = AggregatedCampaignDataService(campaignStore: campaignStore)
    }
    
    // MARK: - Miner Registration
    
    /// Register a new miner with the coordinator
    /// - Parameters:
    ///   - minerId: Unique miner ID
    ///   - accountId: Account ID
    ///   - username: Display username
    ///   - apiClient: The miner's isolated API client
    ///   - inventoryService: The miner's inventory service
    public func registerMiner(
        minerId: String,
        accountId: String,
        username: String,
        apiClient: TwitchAPIClient,
        inventoryService: InventoryService,
        engine: MinerEngine
    ) {
        // Create per-miner data service
        let dataService = CampaignDataService(
            apiClient: apiClient,
            inventoryService: inventoryService,
            accountId: accountId
        )

        minerDataServices[minerId] = dataService
        minerEngines[minerId] = engine
        minerAccountIds[minerId] = accountId

        // Register with aggregation service
        Task {
            await aggregatedService.registerAccount(
                accountId: accountId,
                username: username,
                service: dataService
            )

            // Trigger initial aggregation
            await refreshAll()
        }
    }

    /// Unregister a miner when removed
    public func unregisterMiner(minerId: String, accountId: String) {
        minerDataServices.removeValue(forKey: minerId)
        minerEngines.removeValue(forKey: minerId)
        minerAccountIds.removeValue(forKey: minerId)

        Task {
            await aggregatedService.unregisterAccount(accountId: accountId)
            await refreshAll()
        }
    }
    
    // MARK: - Data Access

    /// Get all aggregated campaigns across all miners
    public func getAllCampaigns() async -> [AggregatedCampaignDataService.AggregatedCampaign] {
        await aggregatedService.getAllCampaigns()
    }

    /// Get the unified cached campaign feed used by the Drops UI.
    /// This applies the curated feed filter (excludes .irrelevant).
    public func currentCampaigns() async -> [CampaignViewData] {
        await aggregatedService.currentCampaigns()
    }

    /// Get ALL cached campaigns without filtering.
    /// Use this for the "All" tab to show complete campaign history.
    public func allCampaigns() async -> [CampaignViewData] {
        await aggregatedService.allCampaigns()
    }
    
    /// Get eligible campaigns (active, not fully claimed)
    public func getEligibleCampaigns() async -> [AggregatedCampaignDataService.AggregatedCampaign] {
        await aggregatedService.getEligibleCampaigns()
    }
    
    /// Get a specific campaign
    public func getCampaign(id: String) async -> AggregatedCampaignDataService.AggregatedCampaign? {
        await aggregatedService.getCampaign(id: id)
    }
    
    /// Check if a drop is claimed for a specific account
    public func isDropClaimed(benefitID: String, accountId: String) async -> Bool {
        await aggregatedService.isDropClaimed(benefitID: benefitID, accountId: accountId)
    }
    
    /// Get aggregate stats across all miners
    public func getAggregateStats() async -> AggregateStats {
        await aggregatedService.getAggregateStats()
    }
    
    /// Force refresh all miners and update CampaignStore
    public func refreshAll() async {
        // Sync active campaign state from each engine before aggregating
        for (minerId, engine) in minerEngines {
            guard let accountId = minerAccountIds[minerId] else { continue }
            let currentCampaignId = await engine.currentCampaignId
            await aggregatedService.updateActiveCampaign(accountId: accountId, campaignId: currentCampaignId)
        }
        await aggregatedService.refreshAll()
    }

    /// Update whether an account needs manual re-authentication in aggregated UI state.
    public func updateAccountNeedsAuth(accountId: String, needsAuth: Bool) async {
        await aggregatedService.updateAccountNeedsAuth(accountId: accountId, needsAuth: needsAuth)
    }
    
    /// Get the underlying data service for a specific miner (for advanced use)
    public func getDataService(for minerId: String) -> CampaignDataService? {
        minerDataServices[minerId]
    }
}
