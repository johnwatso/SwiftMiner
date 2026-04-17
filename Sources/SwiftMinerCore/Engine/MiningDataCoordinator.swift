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

    /// Steam portrait artwork overrides populated during enrichment.
    /// Key = gameName (as returned by Twitch), Value = Steam CDN portrait URL.
    /// Used by views that consume raw Campaign objects (e.g. ContentView overview rail).
    public private(set) var steamArtworkOverrides: [String: URL] = [:]

    /// Steam hero banner overrides populated during enrichment.
    /// Key = gameName, Value = Steam CDN hero URL (landscape, freshest art).
    /// Used for full-bleed blurred backgrounds in the Drops view.
    public private(set) var steamHeroOverrides: [String: URL] = [:]

    /// Last known result of `allCampaigns()` — available synchronously so views can
    /// render immediately on recreation without waiting for the async re-fetch.
    public private(set) var lastKnownAllCampaigns: [CampaignViewData] = []

    /// Last known result of `currentCampaigns()` — same purpose as above.
    public private(set) var lastKnownCurrentCampaigns: [CampaignViewData] = []
    
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
    /// Pass `preferSteamArtwork: true` to substitute Steam CDN artwork where available.
    public func currentCampaigns(preferSteamArtwork: Bool = false) async -> [CampaignViewData] {
        let campaigns = await aggregatedService.currentCampaigns()
        let result = preferSteamArtwork ? await enrichWithSteamArtwork(campaigns) : campaigns
        lastKnownCurrentCampaigns = result
        return result
    }

    /// Get ALL cached campaigns without filtering.
    /// Use this for the "All" tab to show complete campaign history.
    /// Pass `preferSteamArtwork: true` to substitute Steam CDN artwork where available.
    public func allCampaigns(preferSteamArtwork: Bool = false) async -> [CampaignViewData] {
        let campaigns = await aggregatedService.allCampaigns()
        let result = preferSteamArtwork ? await enrichWithSteamArtwork(campaigns) : campaigns
        lastKnownAllCampaigns = result
        return result
    }

    // MARK: - Steam Artwork Enrichment

    /// Clears the Steam artwork override cache and re-enriches from scratch.
    /// Called when the user taps "Refresh Artwork".
    public func clearSteamArtworkCache() async {
        await SteamArtworkService.shared.clearCache()
        steamArtworkOverrides.removeAll()
        steamHeroOverrides.removeAll()
    }

    /// Substitutes Steam CDN artwork into a list of campaigns.
    /// Populates `steamArtworkOverrides` (portrait) and `steamHeroOverrides` (hero banner)
    /// so all views can do a sync lookup without an async call.
    /// 
    /// Uses TaskGroup for parallel enrichment — significantly faster for multiple campaigns.
    private func enrichWithSteamArtwork(_ campaigns: [CampaignViewData]) async -> [CampaignViewData] {
        // Create lookup tables for quick index access
        let gameNames = campaigns
            .map { $0.gameName }
            .filter { SteamArtworkService.supportsSteamArtwork(forGameName: $0) }
        
        // Structure to hold enrichment results
        struct EnrichmentResult {
            let gameName: String
            let portraitURL: URL?
            let heroURL: URL?
        }
        
        // Parallel enrichment using TaskGroup
        let results: [EnrichmentResult] = await withTaskGroup(of: EnrichmentResult.self) { group in
            for gameName in gameNames {
                group.addTask {
                    async let portrait = SteamArtworkService.shared.portraitURL(for: gameName)
                    async let hero = SteamArtworkService.shared.heroURL(for: gameName)
                    return EnrichmentResult(
                        gameName: gameName,
                        portraitURL: await portrait,
                        heroURL: await hero
                    )
                }
            }
            
            var results: [EnrichmentResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        
        // Build lookup dictionaries from results
        var portraitURLs: [String: URL] = [:]
        var heroURLs: [String: URL] = [:]
        for result in results {
            if let url = result.portraitURL {
                portraitURLs[result.gameName] = url
            }
            if let url = result.heroURL {
                heroURLs[result.gameName] = url
            }
        }
        
        // Update override caches
        steamArtworkOverrides.merge(portraitURLs) { _, new in new }
        steamHeroOverrides.merge(heroURLs) { _, new in new }
        
        // Apply to campaigns
        return campaigns.map { campaign in
            if let url = portraitURLs[campaign.gameName] {
                return campaign.withArtworkURL(url)
            }
            return campaign
        }
    }
    
    /// Enriches `steamArtworkOverrides` / `steamHeroOverrides` for a list of bare game names
    /// that may not appear in the active campaign feed (e.g. preferred games with no live campaign).
    /// Safe to call repeatedly — `SteamArtworkService` caches App ID lookups persistently.
    public func enrichGameNames(_ names: [String]) async {
        let supportedNames = names.filter { SteamArtworkService.supportsSteamArtwork(forGameName: $0) }
        guard !supportedNames.isEmpty else { return }
        struct EnrichmentResult {
            let gameName: String
            let portraitURL: URL?
            let heroURL: URL?
        }
        let results: [EnrichmentResult] = await withTaskGroup(of: EnrichmentResult.self) { group in
            for name in supportedNames {
                group.addTask {
                    async let portrait = SteamArtworkService.shared.portraitURL(for: name)
                    async let hero = SteamArtworkService.shared.heroURL(for: name)
                    return EnrichmentResult(gameName: name, portraitURL: await portrait, heroURL: await hero)
                }
            }
            var results: [EnrichmentResult] = []
            for await result in group { results.append(result) }
            return results
        }
        for result in results {
            if let url = result.portraitURL { steamArtworkOverrides[result.gameName] = url }
            if let url = result.heroURL { steamHeroOverrides[result.gameName] = url }
        }
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
