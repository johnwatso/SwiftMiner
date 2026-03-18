import Foundation

/// Service for managing Twitch drops campaigns and tracking
public actor DropsService {
    private let apiClient: TwitchAPIClient

    /// Cache of campaigns
    private var campaignsCache: [Campaign] = []
    private var lastCacheUpdate: Date?
    private let cacheDuration: TimeInterval = 300 // 5 minutes

    /// Cache of inventory (progress)
    private var inventoryCache: [Progress] = []
    private var lastInventoryUpdate: Date?
    private let inventoryCacheDuration: TimeInterval = 60 // 1 minute

    public init(apiClient: TwitchAPIClient) {
        self.apiClient = apiClient
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

        let campaigns = try await apiClient.fetchDropCampaigns()

        // Ensure we merge existing progress into these new objects immediately
        let inventory = try? await fetchInventory()
        let claimedBenefits = await apiClient.getClaimedBenefits()
        let enriched = mergeInventory(inventory ?? inventoryCache, into: campaigns, claimedBenefits: claimedBenefits)

        self.campaignsCache = enriched
        self.lastCacheUpdate = Date()
        return enriched
    }

    /// Get active campaigns (within time window, linked, and has earnable drops)
    /// Active = isMiningEligible
    public func getActiveCampaigns() async throws -> [Campaign] {
        let campaigns = try await fetchCampaigns()
        let inventory = try await fetchInventory()
        let claimedBenefits = await apiClient.getClaimedBenefits()

        // Merge inventory progress into campaigns, with gameEventDrops fallback for claimed detection
        let enriched = mergeInventory(inventory, into: campaigns, claimedBenefits: claimedBenefits)

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
    public func fetchDropStates(for accountId: String) async throws -> [DropState] {
        let campaigns = try await fetchCampaigns()
        let inventory = try await fetchInventory()
        let claimedBenefits = await apiClient.getClaimedBenefits()

        let enriched = mergeInventory(inventory, into: campaigns, claimedBenefits: claimedBenefits)

        return enriched.flatMap { campaign in
            campaign.drops.map { drop in
                let progress = drop.progress
                let state = DropState(
                    dropId: drop.id,
                    accountId: accountId,
                    progressMinutes: progress?.currentMinutes ?? 0,
                    requiredMinutes: drop.requiredMinutes,
                    isClaimed: progress?.isClaimed ?? false,
                    isEligible: campaign.isAccountConnected,
                    lastUpdated: progress?.lastUpdated ?? Date()
                )
                print("[State] Drop \(drop.name) → status=\(state.status) eligible=\(campaign.isAccountConnected)")
                return state
            }
        }
    }

    /// Merges inventory progress into campaigns and applies Python's two-tier claimed detection:
    ///
    /// Tier 1 (authoritative): `self.isClaimed` from DropCampaignDetails — already stored in `drop.progress`
    ///                         from parseDrop(). Used for in-progress drops.
    ///
    /// Tier 2 (fallback): `gameEventDrops` benefit IDs + metadata from Inventory.
    ///                    Twitch omits `self` for fully-claimed drops, so we check:
    ///                    1. Primary: ANY drop.benefitIds appear in claimedBenefits (by ID)
    ///                    2. Fallback: drop name + required minutes match any entry in claimedBenefits
    internal func mergeInventory(
        _ inventory: [Progress],
        into campaigns: [Campaign],
        claimedBenefits: [String: TwitchAPIClient.ClaimedBenefit] = [:]
    ) -> [Campaign] {
        let allClaimed = Array(claimedBenefits.values)
        
        return campaigns.map { campaign in
            var updated = campaign
            updated.drops = campaign.drops.map { drop in
                var d = drop
                if let progress = inventory.first(where: { $0.dropId == drop.id }) {
                    // Inventory has live progress — use it (includes isClaimed for in-progress drops)
                    d.progress = progress
                } else if d.progress == nil {
                    // No `self` field from DropCampaignDetails and not in dropCampaignsInProgress.
                    
                    // 1. Primary: Match by Benefit ID
                    let matchedById = drop.benefitIds.first { claimedBenefits[$0] != nil }
                    
                    if let bid = matchedById {
                        print("[DropsService] mergeInventory: '\(drop.name)' → CLAIMED via benefitId matching (\(bid))")
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
                        // 2. Fallback: Match by benefit name (reward name, not drop name)
                        // gameEventDrops[].name = benefit/reward name (e.g. "Free Advice")
                        // drop.reward?.name    = benefit name from benefitEdges[0] (same field)
                        // These should match when IDs differ due to GQL endpoint format differences.
                        let dropRewardName = drop.reward?.name.lowercased()
                        let matchedByName = dropRewardName.flatMap { rName in
                            allClaimed.first { $0.name.lowercased() == rName }
                        }

                        if let benefit = matchedByName {
                            print("[DropsService] mergeInventory: '\(drop.name)' → matched=0/1 (fallback used) → CLAIMED via benefit name '\(benefit.name)'")
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
                            print("[DropsService] mergeInventory: '\(drop.name)' rewardName=\(drop.reward?.name ?? "nil") — no match in \(allClaimed.map(\.name))")
                        }
                    }
                }
                return d
            }
            return updated
        }
    }

    /// Fetch current inventory (drops in progress)
    public func fetchInventory(forceRefresh: Bool = false) async throws -> [Progress] {
        if !forceRefresh,
           let lastUpdate = lastInventoryUpdate,
           Date().timeIntervalSince(lastUpdate) < inventoryCacheDuration,
           !inventoryCache.isEmpty {
            return inventoryCache
        }
        
        let inventory = try await apiClient.fetchInventory()
        self.inventoryCache = inventory
        self.lastInventoryUpdate = Date()
        return inventory
    }

    /// Get a specific campaign by ID
    public func getCampaign(id: String) async throws -> Campaign {
        let campaigns = try await fetchCampaigns()

        guard let campaign = campaigns.first(where: { $0.id == id }) else {
            throw TwitchMinerError.campaignNotFound
        }

        return campaign
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
        let inventory = try await fetchInventory()

        let activeCampaigns = campaigns.filter { $0.isTimeActive }
        let totalDrops = campaigns.reduce(0) { $0 + $1.drops.count }
        let claimedDrops = inventory.filter { $0.isClaimed }.count
        let pendingDrops = inventory.filter { !$0.isClaimed }.count
        let totalWatchTime = inventory.reduce(into: 0) { $0 += $1.currentMinutes }

        let campaignProgresses = activeCampaigns.map { campaign in
            let campaignInventory = inventory.filter { $0.campaignId == campaign.id }
            let claimedInCampaign = campaignInventory.filter { $0.isClaimed }.count

            return CampaignProgress(
                campaignId: campaign.id,
                campaignName: campaign.name,
                gameName: campaign.gameName,
                totalDrops: campaign.drops.count,
                claimedDrops: claimedInCampaign,
                dropProgress: campaignInventory
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
        inventoryCache = []
        lastInventoryUpdate = nil
    }

    /// Fetch active campaigns (convenience method for MinerEngine)
    public func fetchActiveCampaigns() async throws -> [Campaign] {
        try await getActiveCampaigns()
    }
    
    /// Find live channels for a specific game
    public func findLiveChannels(forGame gameName: String) async throws -> [Channel] {
        let slug = try await apiClient.getGameSlug(name: gameName)
        return try await apiClient.getLiveChannels(gameSlug: slug)
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
