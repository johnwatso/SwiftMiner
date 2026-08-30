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

    /// Last known result of `allCampaigns()` — available synchronously so views can
    /// render immediately on recreation without waiting for the async re-fetch.
    public private(set) var lastKnownAllCampaigns: [CampaignViewData] = []

    /// Last known result of `currentCampaigns()` — same purpose as above.
    public private(set) var lastKnownCurrentCampaigns: [CampaignViewData] = []

    /// Tail of the registration/teardown chain, so those two never overtake each other.
    ///
    /// Both hops have to reach `aggregatedService`, which is an actor, so both suspend before
    /// they do anything. Firing them as independent tasks let a removal land before the
    /// registration it was meant to undo — leaving a dead account wired into aggregation for the
    /// rest of the session — and let two registrations for the same account interleave. Chaining
    /// each new hop behind the previous one keeps them in call order.
    private var coordinationChain: Task<Void, Never>?

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
        enqueueCoordination {
            await self.aggregatedService.registerAccount(
                accountId: accountId,
                username: username,
                service: dataService
            )

            // Registration is what makes the per-account disk caches reachable —
            // `allCampaigns()` reads them through `accountServices`. The Drops view
            // asks for campaigns as soon as a miner appears in the list, which is
            // strictly before this Task runs, so its first read came back empty and
            // it sat on the loading splash until the network refresh below finally
            // posted an update. Telling it now lets it paint from disk immediately.
            NotificationCenter.default.post(name: .dropsCampaignsDidUpdate, object: self)

            // Fake accounts created by hosted unit tests must remain inert.
            if !SwiftMinerRuntime.isRunningTests {
                // Trigger initial aggregation
                await self.refreshAll()
            }
        }
    }

    /// Unregister a miner when removed
    public func unregisterMiner(minerId: String, accountId: String) {
        minerDataServices.removeValue(forKey: minerId)
        minerEngines.removeValue(forKey: minerId)
        minerAccountIds.removeValue(forKey: minerId)

        enqueueCoordination {
            await self.aggregatedService.unregisterAccount(accountId: accountId)
            // Fake accounts created by hosted unit tests must remain inert.
            if !SwiftMinerRuntime.isRunningTests {
                await self.refreshAll()
            }
        }
    }

    /// Waits until every coordination hop queued so far — including the most recent one — has
    /// finished. Test-only; production callers are fire-and-forget by design.
    func drainPendingCoordination() async {
        await coordinationChain?.value
    }

    /// Runs `work` after every previously queued coordination hop has completed.
    private func enqueueCoordination(_ work: @escaping @MainActor () async -> Void) {
        let previous = coordinationChain
        coordinationChain = Task { @MainActor in
            await previous?.value
            await work()
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
        let result = await aggregatedService.currentCampaigns()
        lastKnownCurrentCampaigns = result
        return result
    }

    /// Get ALL cached campaigns without filtering.
    /// Use this for the "All" tab to show complete campaign history.
    public func allCampaigns() async -> [CampaignViewData] {
        let result = await aggregatedService.allCampaigns()
        lastKnownAllCampaigns = result
        return result
    }

    /// Clears persisted campaign/inventory snapshots used for Drops history.
    /// The next refresh repopulates from whatever Twitch still exposes.
    public func clearCachedDropHistory() async {
        CampaignDataService.clearAllCachedDropData()
        for service in minerDataServices.values {
            await service.clearCache()
        }
        lastKnownAllCampaigns.removeAll()
        lastKnownCurrentCampaigns.removeAll()
        campaignStore.updateCampaigns([])
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
    
    /// Search Twitch categories (games) by name across registered miner API clients.
    /// Tries clients in stable miner-ID order so one stale account does not block search.
    /// Returns an empty array when at least one client responds successfully with no matches.
    public func searchCategories(query: String) async throws -> [Game] {
        guard !minerEngines.isEmpty else { return [] }

        let orderedEngines = minerEngines
            .sorted { $0.key < $1.key }
            .map(\.value)

        var lastError: Error?
        var hadSuccessfulResponse = false

        for engine in orderedEngines {
            do {
                let results = try await engine.getAPIClient().searchCategories(query: query)
                hadSuccessfulResponse = true
                if !results.isEmpty {
                    return results
                }
            } catch {
                lastError = error
            }
        }

        if hadSuccessfulResponse {
            return []
        }
        if let lastError {
            throw lastError
        }
        return []
    }

    /// Force refresh all miners and update CampaignStore
    public func refreshAll() async {
        // Sync active campaign state from each engine before aggregating
        for (minerId, engine) in minerEngines {
            guard let accountId = minerAccountIds[minerId] else { continue }
            let currentCampaignId = await engine.currentCampaignId
            await aggregatedService.updateActiveCampaign(accountId: accountId, campaignId: currentCampaignId)
        }
        let allCampaigns = await aggregatedService.refreshAll()
        lastKnownAllCampaigns = allCampaigns
        lastKnownCurrentCampaigns = CampaignMapper.composeFeed(from: allCampaigns)
    }

    /// Force refresh one miner's campaign and inventory data, then update the
    /// shared CampaignStore without issuing requests for the other accounts.
    public func refreshMiner(minerId: String) async {
        guard let accountId = minerAccountIds[minerId] else { return }

        if let engine = minerEngines[minerId] {
            let currentCampaignId = await engine.currentCampaignId
            await aggregatedService.updateActiveCampaign(accountId: accountId, campaignId: currentCampaignId)
        }

        if let allCampaigns = await aggregatedService.refreshAccount(accountId: accountId) {
            lastKnownAllCampaigns = allCampaigns
            lastKnownCurrentCampaigns = CampaignMapper.composeFeed(from: allCampaigns)
        }
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
