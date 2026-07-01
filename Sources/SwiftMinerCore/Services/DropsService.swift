import Foundation

/// Service for managing Twitch drops campaigns and tracking
public actor DropsService {
    private let apiClient: TwitchAPIClient
    private let inventoryService: InventoryService

    /// Cache of campaigns
    private var campaignsCache: [Campaign] = []
    private var lastCacheUpdate: Date?
    private let cacheDuration: TimeInterval = 60 // 1 minute

    public init(apiClient: TwitchAPIClient, inventoryService: InventoryService? = nil) {
        self.apiClient = apiClient
        self.inventoryService = inventoryService ?? InventoryService(apiClient: apiClient)
    }

    public func setAccountId(_ accountId: String) async {
        await inventoryService.setAccountId(accountId)
    }

    public func getInventoryService() -> InventoryService {
        inventoryService
    }

    /// Fetch all drop campaigns
    /// - Parameter forceRefresh: Force refresh even if cache is valid
    /// - Returns: Array of Campaign objects
    public func fetchCampaigns(forceRefresh: Bool = false) async throws -> [Campaign] {
        // Return cached campaigns if still valid
        if !forceRefresh,
           let lastUpdate = lastCacheUpdate,
           Date().timeIntervalSince(lastUpdate) < cacheDuration,
           !campaignsCache.isEmpty {
            return campaignsCache
        }

        let enriched = try await CampaignService.fetchCampaigns(
            using: apiClient,
            inventoryService: inventoryService
        )

        self.campaignsCache = enriched
        self.lastCacheUpdate = Date()
        return enriched
    }

    /// Get active campaigns (within time window, linked, and has earnable drops)
    /// Active = isMiningEligible
    public func getActiveCampaigns() async throws -> [Campaign] {
        let campaigns = try await fetchCampaigns()
        let snapshot = try await inventoryService.fetchInventory()

        let enriched = Self.mergeInventory(snapshot, into: campaigns)

        // Update cache with enriched data
        self.campaignsCache = enriched

        print("[DropsService] Fetched \(enriched.count) total campaigns")

        // Filter: must be mining-eligible (active, linked, and has drops still needing progress)
        let active = enriched.filter { $0.isMiningEligible }

        print("[DropsService] Returning \(active.count) mining-eligible campaigns")
        return active
    }

    /// Fetch account-specific drop states for ALL drops in active campaigns.
    /// Returns a DropState for every drop (notStarted, inProgress, claimable, or claimed).
    /// Drops never disappear — state drives display, not presence.
    public func fetchDropStates(for accountId: String, forceRefresh: Bool = false) async throws -> [DropState] {
        let campaigns = try await fetchCampaigns()
        // Fetch inventory once with fallback to cached snapshot
        let snapshot: InventorySnapshot
        do {
            snapshot = try await inventoryService.fetchInventory(forceRefresh: forceRefresh)
        } catch {
            snapshot = await inventoryService.currentSnapshot() ?? .empty(accountId: accountId)
        }
        let enriched = Self.mergeInventory(snapshot, into: campaigns)

        return enriched.flatMap { campaign in
            campaign.drops.map { drop in
                let progress = drop.progress
                let state = DropState(
                    dropId: drop.id,
                    accountId: accountId,
                    progressMinutes: progress?.currentMinutes ?? 0,
                    requiredMinutes: drop.requiredMinutes,
                    isClaimed: drop.isClaimed,
                    isEligible: campaign.isAccountConnected,
                    lastUpdated: progress?.lastUpdated ?? Date()
                )
                print("[State] Drop \(drop.name) → status=\(state.status) eligible=\(campaign.isAccountConnected)")
                return state
            }
        }
    }

    /// Merges inventory progress into campaigns using Twitch inventory benefit IDs
    /// as the SOLE source of truth for claimed state.
    internal static func mergeInventory(
        _ snapshot: InventorySnapshot,
        into campaigns: [Campaign]
    ) -> [Campaign] {
        let progressByDropId = Dictionary(uniqueKeysWithValues: snapshot.progress.map { ($0.dropId, $0) })

        return campaigns.map { campaign in
            var updated = campaign
            updated.drops = campaign.drops.map { drop in
                var d = drop
                // SOURCE OF TRUTH: Only check inventory benefit IDs. 
                // Ignore transient 'isClaimed' flags in progress dicts.
                let knownBenefitIds = drop.benefitIds.isEmpty
                    ? (drop.benefitID.isEmpty ? [] : [drop.benefitID])
                    : drop.benefitIds
                let claimedFromInventory = knownBenefitIds.contains { snapshot.benefitIDs.contains($0) }
                d.isClaimed = claimedFromInventory

                if let progress = progressByDropId[drop.id] {
                    d.progress = Progress(
                        id: progress.id,
                        dropId: progress.dropId,
                        dropName: progress.dropName,
                        campaignId: progress.campaignId,
                        currentMinutes: progress.currentMinutes,
                        requiredMinutes: progress.requiredMinutes,
                        isClaimed: claimedFromInventory, // Force sync with inventory
                        lastUpdated: progress.lastUpdated
                    )
                } else if claimedFromInventory {
                    // Claimed but no progress entry (Twitch often hides 'self' for claimed drops)
                    d.progress = Progress(
                        id: drop.id,
                        dropId: drop.id,
                        dropName: drop.name,
                        campaignId: campaign.id,
                        currentMinutes: drop.requiredMinutes,
                        requiredMinutes: drop.requiredMinutes,
                        isClaimed: true
                    )
                } else {
                    d.progress = nil
                }

                if claimedFromInventory {
                    print("[DropsService] mergeInventory: '\(drop.name)' → CLAIMED via inventory benefit ID \(drop.benefitID)")
                }
                return d
            }
            return updated
        }
    }

    /// Fetch current inventory (drops in progress)
    public func fetchInventory(forceRefresh: Bool = false) async throws -> [Progress] {
        let snapshot = try await inventoryService.fetchInventory(forceRefresh: forceRefresh)
        return snapshot.progress
    }

    /// Get a specific campaign by ID
    public func getCampaign(id: String) async throws -> Campaign {
        let campaigns = try await fetchCampaigns()

        guard let campaign = campaigns.first(where: { $0.id == id }) else {
            throw TwitchMinerError.campaignNotFound
        }

        return campaign
    }

    /// Returns UI-ready CampaignViewData for all campaigns, combining live campaign data
    /// with the current inventory snapshot. Falls back to cached data when offline so the
    /// UI remains functional even when the miner is not running.
    public func getCampaignViewData(forceRefresh: Bool = false) async throws -> [CampaignViewData] {
        // Fetch campaigns — falls back to in-memory cache automatically
        let campaigns = try await fetchCampaigns(forceRefresh: forceRefresh)
        // Prefer a fresh inventory fetch; fall back to cached snapshot for offline support
        let snapshot: InventorySnapshot?
        do {
            snapshot = try await inventoryService.fetchInventory(forceRefresh: forceRefresh)
        } catch {
            snapshot = await inventoryService.currentSnapshot()
        }
        // composeFeed orders: prioritised → active → recent (never empty if data exists)
        let mapped = CampaignMapper.map(campaigns: campaigns, inventory: snapshot)
        return CampaignMapper.composeFeed(from: mapped)
    }

    /// Returns UI-ready CampaignViewData for a single campaign by ID.
    /// Searches all campaigns (not just the composed feed) so claimed/irrelevant ones are still findable.
    public func getCampaignViewData(for campaignId: String) async throws -> CampaignViewData? {
        let campaigns = try await fetchCampaigns()
        let snapshot: InventorySnapshot?
        do {
            snapshot = try await inventoryService.fetchInventory()
        } catch {
            snapshot = await inventoryService.currentSnapshot()
        }
        let all = CampaignMapper.map(campaigns: campaigns, inventory: snapshot)
        return all.first { $0.id == campaignId }
    }

    /// Get drops that are ready to claim (100% complete but not claimed)
    public func getClaimableDrops() async throws -> [Progress] {
        let inventory = try await fetchInventory()
        return inventory.filter { $0.isComplete && !$0.isClaimed }
    }

    /// Get drops that are in progress (not complete, not claimed)
    public func getInProgressDrops() async throws -> [Progress] {
        let inventory = try await fetchInventory()
        return inventory.filter { !$0.isComplete && !$0.isClaimed }
    }

    /// Get overall progress across all campaigns
    public func getOverallProgress() async throws -> OverallProgress {
        let campaigns = try await fetchCampaigns()
        // Fetch inventory once with fallback to cached snapshot
        let snapshot: InventorySnapshot
        do {
            snapshot = try await inventoryService.fetchInventory()
        } catch {
            snapshot = await inventoryService.currentSnapshot() ?? .empty(accountId: "")
        }
        let enriched = Self.mergeInventory(snapshot, into: campaigns)

        let activeCampaigns = enriched.filter { $0.isTimeActive }
        let allDrops = enriched.flatMap(\.drops)
        let totalDrops = allDrops.count
        let claimedDrops = allDrops.filter(\.isClaimed).count
        let pendingDrops = totalDrops - claimedDrops
        let totalWatchTime = enriched
            .flatMap(\.drops)
            .reduce(into: 0) { total, drop in
                total += drop.progress?.currentMinutes ?? 0
            }

        let campaignProgresses = activeCampaigns.map { campaign in
            let campaignProgress = campaign.drops.compactMap(\.progress)
            let claimedInCampaign = campaign.drops.filter(\.isClaimed).count

            return CampaignProgress(
                campaignId: campaign.id,
                campaignName: campaign.name,
                gameName: campaign.gameName,
                totalDrops: campaign.drops.count,
                claimedDrops: claimedInCampaign,
                dropProgress: campaignProgress
            )
        }

        return OverallProgress(
            totalCampaigns: campaigns.count,
            activeCampaigns: activeCampaigns.count,
            totalDrops: totalDrops,
            claimedDrops: claimedDrops,
            pendingDrops: pendingDrops,
            totalWatchTimeMinutes: totalWatchTime,
            campaigns: campaignProgresses
        )
    }

    /// Clear the campaigns cache
    public func clearCache() {
        campaignsCache = []
        lastCacheUpdate = nil
        Task {
            await inventoryService.clearCache()
        }
    }

    /// Fetch active campaigns (convenience method for MinerEngine)
    public func fetchActiveCampaigns() async throws -> [Campaign] {
        try await getActiveCampaigns()
    }
    
    /// Find live channels for a specific game
    public func findLiveChannels(forGame gameName: String) async throws -> [Channel] {
        try await findLiveChannels(forGame: Game(id: "", name: gameName))
    }

    /// Find live channels for a specific Twitch game/category.
    public func findLiveChannels(forGame game: Game) async throws -> [Channel] {
        let expectedGameId = game.id.trimmingCharacters(in: .whitespacesAndNewlines)
        var attemptedSlugs = Set<String>()

        let primarySlugs = try await apiClient.getGameSlugCandidates(
            for: game,
            includeCategorySearch: false
        )
        for slug in primarySlugs {
            let slugKey = slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !slugKey.isEmpty, attemptedSlugs.insert(slugKey).inserted else { continue }
            let channels = try await apiClient.getLiveChannels(
                gameSlug: slug,
                expectedGameId: expectedGameId.isEmpty ? nil : expectedGameId
            )
            if !channels.isEmpty {
                return channels
            }
        }

        let expandedSlugs = try await apiClient.getCategorySearchGameSlugCandidates(for: game)
        for slug in expandedSlugs {
            let slugKey = slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !slugKey.isEmpty, attemptedSlugs.insert(slugKey).inserted else { continue }
            let channels = try await apiClient.getLiveChannels(
                gameSlug: slug,
                expectedGameId: expectedGameId.isEmpty ? nil : expectedGameId
            )
            if !channels.isEmpty {
                return channels
            }
        }
        return []
    }

    /// Get best campaign to mine (simple implementation)
    public func getBestCampaignToMine(from campaigns: [Campaign]) -> Campaign? {
        // Sort by fewest claimed drops (prioritize campaigns with more progress available)
        return campaigns
            .filter { $0.hasClaimableDrops }
            .sorted { $0.unclaimedDrops.count > $1.unclaimedDrops.count }
            .first
    }
}
