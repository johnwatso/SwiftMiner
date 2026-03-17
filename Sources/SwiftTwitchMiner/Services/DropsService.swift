import Foundation

/// Service for managing Twitch drops campaigns and tracking
public actor DropsService {
    private let apiClient: TwitchAPIClient

    /// Cache of campaigns
    private var campaignsCache: [Campaign] = []
    private var lastCacheUpdate: Date?
    private let cacheDuration: TimeInterval = 300 // 5 minutes

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
        self.campaignsCache = campaigns
        self.lastCacheUpdate = Date()
        return campaigns
    }

    /// Get active campaigns (within time window and has drops to earn)
    public func getActiveCampaigns() async throws -> [Campaign] {
        let campaigns = try await fetchCampaigns()
        let inventory = try await fetchInventory()
        
        // Merge inventory progress into campaigns
        let enriched = campaigns.map { campaign -> Campaign in
            var updated = campaign
            updated.drops = campaign.drops.map { drop -> Drop in
                var d = drop
                if let progress = inventory.first(where: { $0.dropId == drop.id }) {
                    d.progress = progress
                }
                return d
            }
            return updated
        }
        
        // Update cache with enriched data
        self.campaignsCache = enriched

        print("[DropsService] Fetched \(enriched.count) total campaigns")
        for campaign in enriched {
            let p = campaign.drops.filter { $0.progress != nil }.count
            print("[DropsService]   - Campaign: \(campaign.name) | game: \(campaign.gameName) | connected: \(campaign.isAccountConnected) | progress: \(p)/\(campaign.drops.count)")
        }

        let timeActive = enriched.filter { $0.isTimeActive }
        print("[DropsService] \(timeActive.count) campaigns pass isTimeActive check")

        let withDrops = timeActive.filter { !$0.drops.isEmpty }
        print("[DropsService] \(withDrops.count) campaigns pass !drops.isEmpty check")
        
        // Prioritize campaigns where account is connected (claimable)
        let claimable = withDrops.filter { $0.isAccountConnected }
        print("[DropsService] \(claimable.count) campaigns have isAccountConnected=true")
        
        // Return claimable first, then others as fallback
        let result = claimable.isEmpty ? withDrops : claimable
        print("[DropsService] Returning \(result.count) active campaigns with eligible drops")
        return result
    }

    /// Fetch current inventory (drops in progress)
    public func fetchInventory() async throws -> [Progress] {
        try await apiClient.fetchInventory()
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
