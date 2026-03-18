import Foundation

/// Aggregates campaign data across multiple miners/accounts.
/// Provides a unified view of all campaigns with per-account progress.
///
/// Features:
/// - Merges campaigns from all miners (deduplicated by campaign ID)
/// - Shared campaign metadata (name, artwork, drops)
/// - Per-account progress and claimed state
/// - Offline-first: Uses cached data from each miner
public actor AggregatedCampaignDataService {
    
    // MARK: - Types
    
    /// Represents a campaign with progress across multiple accounts
    public struct AggregatedCampaign: Identifiable, Sendable, Equatable {
        public let id: String
        public let gameName: String
        public let campaignName: String
        public let artworkURL: URL?
        public let status: String
        public let startDate: Date
        public let endDate: Date
        
        /// Total drops in this campaign (shared across all accounts)
        public let totalDrops: Int
        
        /// Per-account progress information
        public let accountProgress: [String: AccountProgress]
        
        /// Aggregated progress across all accounts (for display)
        public var overallProgress: Double {
            guard !accountProgress.isEmpty else { return 0 }
            let total = accountProgress.values.reduce(0) { $0 + $1.progress }
            return total / Double(accountProgress.count)
        }
        
        /// True if all drops are claimed across ALL accounts
        public var isFullyClaimed: Bool {
            guard !accountProgress.isEmpty else { return false }
            return accountProgress.values.allSatisfy { $0.isClaimed }
        }
        
        /// True if this campaign is claimed for a specific account
        public func isClaimed(for accountId: String) -> Bool {
            accountProgress[accountId]?.isClaimed ?? false
        }
        
        /// Progress for a specific account (0.0 - 1.0)
        public func progress(for accountId: String) -> Double {
            accountProgress[accountId]?.progress ?? 0
        }
        
        /// Drops claimed for a specific account
        public func dropsClaimed(for accountId: String) -> Int {
            accountProgress[accountId]?.dropsClaimed ?? 0
        }
        
        public struct AccountProgress: Sendable, Equatable {
            public let accountId: String
            public let username: String
            public let progress: Double
            public let isClaimed: Bool
            public let dropsClaimed: Int
            public let dropsTotal: Int
            
            public init(
                accountId: String,
                username: String,
                progress: Double,
                isClaimed: Bool,
                dropsClaimed: Int,
                dropsTotal: Int
            ) {
                self.accountId = accountId
                self.username = username
                self.progress = progress
                self.isClaimed = isClaimed
                self.dropsClaimed = dropsClaimed
                self.dropsTotal = dropsTotal
            }
        }
        
        public init(
            id: String,
            gameName: String,
            campaignName: String,
            artworkURL: URL?,
            status: String,
            startDate: Date,
            endDate: Date,
            totalDrops: Int,
            accountProgress: [String: AccountProgress]
        ) {
            self.id = id
            self.gameName = gameName
            self.campaignName = campaignName
            self.artworkURL = artworkURL
            self.status = status
            self.startDate = startDate
            self.endDate = endDate
            self.totalDrops = totalDrops
            self.accountProgress = accountProgress
        }
    }
    
    // MARK: - Properties
    
    /// Per-account data services
    private var accountServices: [String: CampaignDataService] = [:]
    
    /// Username lookup by account ID
    private var accountUsernames: [String: String] = [:]
    
    // MARK: - Account Management
    
    /// Register a miner's data service
    public func registerAccount(
        accountId: String,
        username: String,
        service: CampaignDataService
    ) {
        accountServices[accountId] = service
        accountUsernames[accountId] = username
    }
    
    /// Unregister an account when removed
    public func unregisterAccount(accountId: String) {
        accountServices.removeValue(forKey: accountId)
        accountUsernames.removeValue(forKey: accountId)
    }
    
    // MARK: - Aggregation API
    
    /// Get all unique campaigns across all miners with aggregated progress
    public func getAllCampaigns() async -> [AggregatedCampaign] {
        // Collect campaigns from all accounts
        var campaignsById: [String: Campaign] = [:]
        var viewDataByAccount: [String: [CampaignViewData]] = [:]
        
        for (accountId, service) in accountServices {
            let viewData = await service.getAllCampaigns()
            viewDataByAccount[accountId] = viewData
            
            // Store campaign metadata (shared across accounts)
            for data in viewData {
                if campaignsById[data.id] == nil {
                    // Create a Campaign from view data for storage
                    campaignsById[data.id] = Campaign(
                        id: data.id,
                        name: data.campaignName,
                        game: Game(id: "", name: data.gameName, boxArtURL: data.artworkURL),
                        status: CampaignStatus(rawValue: data.status) ?? .active,
                        startDate: Date(), // Will be populated from actual campaign
                        endDate: Date().addingTimeInterval(86400), // Will be populated
                        drops: [], // Drops loaded separately if needed
                        isAccountConnected: true
                    )
                }
            }
        }
        
        // Build aggregated campaigns
        return campaignsById.values.map { campaign in
            buildAggregatedCampaign(
                campaign: campaign,
                viewDataByAccount: viewDataByAccount
            )
        }.sorted { $0.gameName < $1.gameName }
    }
    
    /// Get campaigns that are eligible for mining (active, not fully claimed)
    public func getEligibleCampaigns() async -> [AggregatedCampaign] {
        let all = await getAllCampaigns()
        return all.filter { campaign in
            campaign.status == "ACTIVE" && !campaign.isFullyClaimed
        }
    }
    
    /// Get a specific campaign with all account progress
    public func getCampaign(id: String) async -> AggregatedCampaign? {
        let all = await getAllCampaigns()
        return all.first { $0.id == id }
    }
    
    /// Check if a drop is claimed for a specific account
    public func isDropClaimed(benefitID: String, accountId: String) async -> Bool {
        guard let service = accountServices[accountId] else { return false }
        return await service.isDropClaimed(benefitID: benefitID)
    }
    
    /// Get aggregated stats across all accounts
    public func getAggregateStats() async -> AggregateStats {
        let campaigns = await getAllCampaigns()
        
        var totalCampaigns = 0
        var activeCampaigns = 0
        var fullyClaimedCampaigns = 0
        var totalDrops = 0
        var totalClaimedDrops = 0
        
        for campaign in campaigns {
            totalCampaigns += 1
            totalDrops += campaign.totalDrops
            
            if campaign.status == "ACTIVE" {
                activeCampaigns += 1
            }
            
            if campaign.isFullyClaimed {
                fullyClaimedCampaigns += 1
            }
            
            // Sum claimed drops across all accounts
            for (_, progress) in campaign.accountProgress {
                totalClaimedDrops += progress.dropsClaimed
            }
        }
        
        return AggregateStats(
            totalCampaigns: totalCampaigns,
            activeCampaigns: activeCampaigns,
            fullyClaimedCampaigns: fullyClaimedCampaigns,
            totalDrops: totalDrops,
            totalClaimedDrops: totalClaimedDrops,
            accountCount: accountServices.count
        )
    }
    
    /// Force refresh for all accounts
    public func refreshAll() async {
        for (_, service) in accountServices {
            await service.refresh()
        }
    }
    
    // MARK: - Private Helpers
    
    private func buildAggregatedCampaign(
        campaign: Campaign,
        viewDataByAccount: [String: [CampaignViewData]]
    ) -> AggregatedCampaign {
        var accountProgress: [String: AggregatedCampaign.AccountProgress] = [:]
        
        for (accountId, viewDataList) in viewDataByAccount {
            guard let viewData = viewDataList.first(where: { $0.id == campaign.id }),
                  let username = accountUsernames[accountId] else {
                continue
            }
            
            accountProgress[accountId] = AggregatedCampaign.AccountProgress(
                accountId: accountId,
                username: username,
                progress: viewData.progress,
                isClaimed: viewData.isClaimed,
                dropsClaimed: viewData.dropsClaimed,
                dropsTotal: viewData.totalDrops
            )
        }
        
        return AggregatedCampaign(
            id: campaign.id,
            gameName: campaign.game.name,
            campaignName: campaign.name,
            artworkURL: campaign.game.boxArtURL,
            status: campaign.status.rawValue,
            startDate: campaign.startDate,
            endDate: campaign.endDate,
            totalDrops: campaign.drops.count,
            accountProgress: accountProgress
        )
    }
}

// MARK: - Supporting Types

public struct AggregateStats: Sendable {
    public let totalCampaigns: Int
    public let activeCampaigns: Int
    public let fullyClaimedCampaigns: Int
    public let totalDrops: Int
    public let totalClaimedDrops: Int
    public let accountCount: Int
    
    public var completionPercentage: Double {
        guard totalDrops > 0 else { return 0 }
        return Double(totalClaimedDrops) / Double(totalDrops) * 100
    }
    
    public init(
        totalCampaigns: Int,
        activeCampaigns: Int,
        fullyClaimedCampaigns: Int,
        totalDrops: Int,
        totalClaimedDrops: Int,
        accountCount: Int
    ) {
        self.totalCampaigns = totalCampaigns
        self.activeCampaigns = activeCampaigns
        self.fullyClaimedCampaigns = fullyClaimedCampaigns
        self.totalDrops = totalDrops
        self.totalClaimedDrops = totalClaimedDrops
        self.accountCount = accountCount
    }
}
