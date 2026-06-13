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
    
    /// Pre-computed mining state for a single account on a campaign.
    /// Codex reads this directly — no inference required.
    public enum AccountMiningState: String, Codable, Sendable {
        case mining   // actively watching a channel for this campaign right now
        case claimed  // all drops claimed (benefit IDs confirmed in inventory)
        case idle     // linked but not currently mining this campaign
    }

    /// Represents a campaign with progress across multiple accounts
    public struct AggregatedCampaign: Identifiable, Sendable, Equatable {
        public let id: String
        public let gameName: String
        public let campaignName: String
        public let artworkURL: URL?
        public let status: String
        public let startDate: Date
        public let endDate: Date
        /// Whether at least one account has a connected game account for this campaign
        public let isAccountConnected: Bool
        /// Merged drops from all accounts (used for status calculation)
        public let drops: [Drop]

        /// Total drops in this campaign (shared across all accounts)
        public let totalDrops: Int

        /// Per-account progress information
        public let accountProgress: [String: AccountProgress]

        /// Ordered list of per-account state indicators for Codex avatar row.
        /// Pre-computed — initials, state, and username are all final.
        public let accountStates: [AccountState]

        /// Per-account state indicator — all fields pre-computed for direct rendering.
        public struct AccountState: Sendable, Equatable {
            public let accountId: String
            public let username: String
            /// First two letters of username, uppercased. Pre-computed for display.
            public let initials: String
            public let state: AccountMiningState
        }
        
        /// Maximum progress across all accounts (for display).
        /// Each account progresses independently — showing max is more meaningful than average.
        public var overallProgress: Double {
            guard !accountProgress.isEmpty else { return 0 }
            return accountProgress.values.map { $0.progress }.max() ?? 0
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
            isAccountConnected: Bool,
            drops: [Drop] = [],
            totalDrops: Int,
            accountProgress: [String: AccountProgress],
            accountStates: [AccountState] = []
        ) {
            self.id = id
            self.gameName = gameName
            self.campaignName = campaignName
            self.artworkURL = artworkURL
            self.status = status
            self.startDate = startDate
            self.endDate = endDate
            self.isAccountConnected = isAccountConnected
            self.drops = drops
            self.totalDrops = totalDrops
            self.accountProgress = accountProgress
            self.accountStates = accountStates
        }
    }
    
    // MARK: - Properties
    
    /// Per-account data services
    private var accountServices: [String: CampaignDataService] = [:]

    /// Username lookup by account ID
    private var accountUsernames: [String: String] = [:]

    /// Currently active campaign ID per account (nil = not mining anything)
    /// Updated by MiningDataCoordinator at each refresh.
    private var activeCampaignIds: [String: String?] = [:]

    /// Whether an account needs manual re-authentication before mining can continue.
    private var accountNeedsAuth: [String: Bool] = [:]

    // MARK: - Account Management
    
    /// Optional CampaignStore to push aggregated updates to
    private weak var campaignStore: CampaignStore?
    
    /// Initialize with optional CampaignStore for UI updates
    public init(campaignStore: CampaignStore? = nil) {
        self.campaignStore = campaignStore
    }
    
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
        activeCampaignIds.removeValue(forKey: accountId)
        accountNeedsAuth.removeValue(forKey: accountId)
    }

    /// Update the currently active campaign for an account.
    /// Called by MiningDataCoordinator at each refresh cycle.
    public func updateActiveCampaign(accountId: String, campaignId: String?) {
        activeCampaignIds[accountId] = campaignId
    }

    /// Update whether an account needs manual re-authentication.
    public func updateAccountNeedsAuth(accountId: String, needsAuth: Bool) {
        accountNeedsAuth[accountId] = needsAuth
    }
    
    // MARK: - Aggregation API
    
    /// Get all unique campaigns across all miners with aggregated progress
    public func getAllCampaigns() async -> [AggregatedCampaign] {
        let aggregated = await getAggregatedCampaignsInternal()
        
        // Update CampaignStore with latest aggregated data
        await updateCampaignStore(using: aggregated)
        
        return aggregated
    }

    /// Internal implementation of aggregation to avoid recursion and allow re-use
    private func getAggregatedCampaignsInternal() async -> [AggregatedCampaign] {
        let (viewDataByAccount, bestMetadata) = await collectCurrentCampaignViewData()
        
        // Build aggregated campaigns
        return bestMetadata.values.map { data in
            buildAggregatedCampaign(
                from: data,
                viewDataByAccount: viewDataByAccount
            )
        }.sorted { $0.gameName < $1.gameName }
    }

    /// Returns the unified cached campaign feed used by the Drops UI.
    /// This stays aligned with `CampaignDataService.currentCampaigns()`.
    /// NOTE: This applies the curated feed filter (excludes .irrelevant).
    /// For the "All" tab, use `allCampaigns()` instead.
    public func currentCampaigns() async -> [CampaignViewData] {
        let (viewDataByAccount, bestMetadata) = await collectCurrentCampaignViewData()

        let merged = bestMetadata.values.map { data in
            buildUnifiedCampaignViewData(
                from: data,
                viewDataByAccount: viewDataByAccount
            )
        }

        return CampaignMapper.composeFeed(from: merged)
    }

    /// Returns ALL cached campaigns without filtering.
    /// Use this for the "All" tab to show complete campaign history.
    /// This includes .irrelevant campaigns that are excluded from the curated feed.
    public func allCampaigns() async -> [CampaignViewData] {
        // Use collectAllCampaignViewData() to get unfiltered campaigns from all accounts
        let (viewDataByAccount, bestMetadata) = await collectAllCampaignViewData()

        let merged = bestMetadata.values.map { data in
            buildUnifiedCampaignViewData(
                from: data,
                viewDataByAccount: viewDataByAccount
            )
        }

        // Return all campaigns sorted by game name, no filtering
        return merged.sorted { $0.gameName < $1.gameName }
    }
    
    /// Get campaigns that are eligible for mining (active, not fully claimed)
    public func getEligibleCampaigns() async -> [AggregatedCampaign] {
        let all = await getAggregatedCampaignsInternal()
        return all.filter { campaign in
            campaign.endDate > Date()
                && campaign.isAccountConnected
                && !campaign.isFullyClaimed
                && campaign.drops.contains { !$0.isClaimed }
        }
    }
    
    /// Get a specific campaign with all account progress
    public func getCampaign(id: String) async -> AggregatedCampaign? {
        let all = await getAggregatedCampaignsInternal()
        return all.first { $0.id == id }
    }
    
    /// Check if a drop is claimed for a specific account
    public func isDropClaimed(benefitID: String, accountId: String) async -> Bool {
        guard let service = accountServices[accountId] else { return false }
        return await service.isDropClaimed(benefitID: benefitID)
    }
    
    /// Get aggregated stats across all accounts
    public func getAggregateStats() async -> AggregateStats {
        let campaigns = await getAggregatedCampaignsInternal()
        
        var totalCampaigns = 0
        var activeCampaigns = 0
        var fullyClaimedCampaigns = 0
        
        // Use sets to deduplicate by ID across all campaigns and accounts
        var uniqueDropIds = Set<String>()
        var earnedDropIds = Set<String>()
        var claimedDropIds = Set<String>()
        
        let now = Date()
        
        for campaign in campaigns {
            totalCampaigns += 1
            
            if campaign.endDate > now && campaign.isAccountConnected && !campaign.isFullyClaimed {
                activeCampaigns += 1
            }
            
            if campaign.isFullyClaimed {
                fullyClaimedCampaigns += 1
            }
            
            // Deduplicate drops by ID across all campaigns
            for drop in campaign.drops {
                let dropId = drop.id
                uniqueDropIds.insert(dropId)
                
                // Earned = progress.isComplete
                if drop.progress?.isComplete == true {
                    earnedDropIds.insert(dropId)
                }
                
                // Claimed = isClaimed
                if drop.isClaimed {
                    claimedDropIds.insert(dropId)
                }
            }
        }
        
        return AggregateStats(
            totalCampaigns: totalCampaigns,
            activeCampaigns: activeCampaigns,
            fullyClaimedCampaigns: fullyClaimedCampaigns,
            totalDrops: uniqueDropIds.count,
            totalEarnedDrops: earnedDropIds.count,
            totalClaimedDrops: claimedDropIds.count,
            accountCount: accountServices.count
        )
    }
    
    /// Force refresh for all accounts and update CampaignStore
    public func refreshAll() async {
        let services = Array(accountServices.values)
        await withTaskGroup(of: Void.self) { group in
            for service in services {
                group.addTask { await service.refresh() }
            }
        }
        let aggregated = await getAggregatedCampaignsInternal()
        await updateCampaignStore(using: aggregated)
    }
    
    /// Push aggregated campaigns to CampaignStore (if configured)
    private func updateCampaignStore(using aggregated: [AggregatedCampaign]) async {
        guard let store = campaignStore else { return }
        
        // Convert AggregatedCampaign back to Campaign for CampaignStore
        let campaigns: [Campaign] = aggregated.map { agg in
            // Use the best available metadata
            Campaign(
                id: agg.id,
                name: agg.campaignName,
                game: Game(id: "", name: agg.gameName, boxArtURL: agg.artworkURL),
                status: CampaignStatus(rawValue: agg.status) ?? .active,
                startDate: agg.startDate,
                endDate: agg.endDate,
                drops: agg.drops,
                isAccountConnected: agg.isAccountConnected
            )
        }
        
        await MainActor.run {
            store.updateCampaigns(campaigns)
        }
    }
    
    // MARK: - Private Helpers
    
    private func buildAggregatedCampaign(
        from data: CampaignViewData,
        viewDataByAccount: [String: [CampaignViewData]]
    ) -> AggregatedCampaign {
        var accountProgress: [String: AggregatedCampaign.AccountProgress] = [:]
        var accountStates: [AggregatedCampaign.AccountState] = []
        var anyConnected = false

        let accountCampaigns = viewDataByAccount.compactMap { accountId, campaigns in
            campaigns.first(where: { $0.id == data.id }).map { (accountId, $0) }
        }

        for (accountId, viewData) in accountCampaigns {
            guard let username = accountUsernames[accountId] else {
                continue
            }

            if viewData.isAccountConnected {
                anyConnected = true
            }

            accountProgress[accountId] = AggregatedCampaign.AccountProgress(
                accountId: accountId,
                username: username,
                progress: viewData.progress,
                isClaimed: viewData.isClaimed,
                dropsClaimed: viewData.dropsClaimed,
                dropsTotal: viewData.totalDrops
            )

            let state: AccountMiningState
            if viewData.isClaimed {
                state = .claimed
            } else if activeCampaignIds[accountId] == data.id {
                state = .mining
            } else {
                state = .idle
            }

            accountStates.append(AggregatedCampaign.AccountState(
                accountId: accountId,
                username: username,
                initials: Self.initials(from: username),
                state: state
            ))
        }

        // Sort: mining first, then claimed, then idle — consistent ordering for Codex
        accountStates.sort {
            let order: [AccountMiningState: Int] = [.mining: 0, .claimed: 1, .idle: 2]
            return (order[$0.state] ?? 3) < (order[$1.state] ?? 3)
        }

        // Merge drops for status calculation in CampaignStore
        let mergedDropData = mergeDrops(from: accountCampaigns.map(\.1))
        let drops = mergedDropData.map { d in
            Drop(
                id: d.id,
                name: d.name,
                description: d.description,
                imageURL: d.imageURL,
                requiredMinutes: d.requiredMinutes,
                progress: Progress(
                    id: "",
                    dropId: d.id,
                    dropName: d.name,
                    campaignId: data.id,
                    currentMinutes: d.currentMinutes,
                    requiredMinutes: d.requiredMinutes,
                    isClaimed: d.isClaimed
                ),
                isClaimed: d.isClaimed
            )
        }

        return AggregatedCampaign(
            id: data.id,
            gameName: data.gameName,
            campaignName: data.campaignName,
            artworkURL: data.artworkURL,
            status: data.status,
            startDate: data.startDate,
            endDate: data.endDate,
            isAccountConnected: anyConnected,
            drops: drops,
            totalDrops: data.totalDrops,
            accountProgress: accountProgress,
            accountStates: accountStates
        )
    }

    private func collectCurrentCampaignViewData() async -> ([String: [CampaignViewData]], [String: CampaignViewData]) {
        var viewDataByAccount: [String: [CampaignViewData]] = [:]
        var bestMetadata: [String: CampaignViewData] = [:]

        for (accountId, service) in accountServices {
            // Use allCampaigns() instead of currentCampaigns() to get unfiltered data
            // This ensures we see connected campaigns even if they are currently .irrelevant
            let viewData = await service.allCampaigns()
            viewDataByAccount[accountId] = viewData

            for data in viewData {
                if let existing = bestMetadata[data.id] {
                    if shouldReplaceMetadata(existing: existing, incoming: data) {
                        bestMetadata[data.id] = data
                    }
                } else {
                    bestMetadata[data.id] = data
                }
            }
        }

        return (viewDataByAccount, bestMetadata)
    }
    
    /// Collects ALL campaigns from all accounts without filtering.
    /// Use this for the "All" tab to include campaigns excluded from the curated feed.
    private func collectAllCampaignViewData() async -> ([String: [CampaignViewData]], [String: CampaignViewData]) {
        var viewDataByAccount: [String: [CampaignViewData]] = [:]
        var bestMetadata: [String: CampaignViewData] = [:]

        for (accountId, service) in accountServices {
            // Use allCampaigns() instead of currentCampaigns() to get unfiltered data
            let viewData = await service.allCampaigns()
            viewDataByAccount[accountId] = viewData

            for data in viewData {
                if let existing = bestMetadata[data.id] {
                    if shouldReplaceMetadata(existing: existing, incoming: data) {
                        bestMetadata[data.id] = data
                    }
                } else {
                    bestMetadata[data.id] = data
                }
            }
        }

        return (viewDataByAccount, bestMetadata)
    }

    private func buildUnifiedCampaignViewData(
        from data: CampaignViewData,
        viewDataByAccount: [String: [CampaignViewData]]
    ) -> CampaignViewData {
        let accountCampaigns = viewDataByAccount.compactMap { accountId, campaigns in
            campaigns.first(where: { $0.id == data.id }).map { (accountId, $0) }
        }

        // Progress should NOT be averaged across accounts.
        // Each account has independent progress. Show the maximum progress for overview,
        // with per-account progress available via accountStates.
        let progressValues = accountCampaigns.map { $0.1.progress }
        let aggregateProgress = progressValues.isEmpty
            ? data.progress
            : progressValues.max() ?? data.progress  // Use max progress, not average

        let anyConnected = accountCampaigns.contains { $0.1.isAccountConnected }
        let drops = mergeDrops(from: accountCampaigns.map(\.1))
        let accountStates = buildCampaignAccountStates(
            for: data.id,
            accountCampaigns: accountCampaigns
        )
        let allClaimed = !accountStates.isEmpty
            ? accountStates.allSatisfy { $0.miningStatus == .claimed || $0.miningStatus == .claimedUnlinked }
            : (!accountCampaigns.isEmpty && accountCampaigns.allSatisfy { $0.1.isClaimed })
        let miningStatus = mergedMiningStatus(
            for: data,
            campaigns: accountCampaigns.map(\.1),
            allClaimed: allClaimed,
            anyConnected: anyConnected
        )
        let relevance = mergedRelevance(
            for: data,
            campaigns: accountCampaigns.map(\.1),
            miningStatus: miningStatus,
            allClaimed: allClaimed,
            anyConnected: anyConnected
        )

        return CampaignViewData(
            id: data.id,
            gameId: data.gameId,
            gameName: data.gameName,
            campaignName: data.campaignName,
            artworkURL: data.artworkURL,
            progress: aggregateProgress,
            isClaimed: allClaimed,
            dropsClaimed: accountCampaigns.map { $0.1.dropsClaimed }.max() ?? data.dropsClaimed,
            totalDrops: accountCampaigns.map { $0.1.totalDrops }.max() ?? data.totalDrops,
            timeRemaining: accountCampaigns.compactMap { $0.1.timeRemaining }.min() ?? data.timeRemaining,
            status: mergeCampaignStatus(for: data, campaigns: accountCampaigns.map(\.1)),
            miningStatus: miningStatus,
            isAccountConnected: anyConnected,
            relevance: relevance,
            startDate: data.startDate,
            endDate: data.endDate,
            drops: drops,
            accountStates: accountStates
        )
    }

    private func buildCampaignAccountStates(
        for campaignId: String,
        accountCampaigns: [(String, CampaignViewData)]
    ) -> [AccountState] {
        let campaignsByAccount = Dictionary(uniqueKeysWithValues: accountCampaigns)

        return accountUsernames.keys.compactMap { accountId -> AccountState? in
            let username = accountUsernames[accountId] ?? accountId
            let campaign = campaignsByAccount[accountId]
            let needsAuth = accountNeedsAuth[accountId] == true
            let isActiveOnThis = activeCampaignIds[accountId] == campaignId

            // Hide accounts with no record for this campaign and no other reason to surface them.
            // They aren't eligible / never saw it, so showing them as "waiting" is misleading.
            if campaign == nil && !needsAuth && !isActiveOnThis {
                return nil
            }

            let state: AccountMiningStatus
            let claimedDropCount: Int

            if needsAuth {
                state = .needsAuth
            } else if campaign?.isClaimed == true || campaign?.miningStatus == .claimed {
                // Claimed, but the reward can't reach the game until linked.
                state = campaign?.isAccountConnected == false ? .claimedUnlinked : .claimed
            } else if isActiveOnThis {
                state = .mining
            } else if campaign?.isAccountConnected == false {
                state = .blocked
            } else if campaign?.miningStatus == .available || campaign?.miningStatus == .inProgress || campaign?.miningStatus == .claimable {
                state = .ready
            } else {
                state = .idle
            }

            if let campaign {
                claimedDropCount = max(
                    campaign.dropsClaimed,
                    campaign.drops.filter(\.isClaimed).count
                )
            } else {
                claimedDropCount = 0
            }

            return AccountState(
                accountId: accountId,
                username: username,
                initials: Self.initials(from: username),
                miningStatus: state,
                claimedDropCount: claimedDropCount,
                progressFraction: campaign.flatMap(Self.progressFraction(for:))
            )
        }
        .sorted { lhs, rhs in
            let order: [AccountMiningStatus: Int] = [.needsAuth: 0, .blocked: 1, .mining: 2, .ready: 3, .claimedUnlinked: 4, .claimed: 5, .idle: 6]
            return (order[lhs.miningStatus] ?? 4) < (order[rhs.miningStatus] ?? 4)
        }
    }

    private func mergeDrops(from campaigns: [CampaignViewData]) -> [DropViewData] {
        var bestDrops: [String: DropViewData] = [:]
        var order: [String] = []

        for campaign in campaigns {
            for drop in campaign.drops {
                if bestDrops[drop.id] == nil {
                    order.append(drop.id)
                    bestDrops[drop.id] = drop
                } else if let existing = bestDrops[drop.id] {
                    bestDrops[drop.id] = mergeDrop(existing: existing, incoming: drop)
                }
            }
        }

        return order.compactMap { bestDrops[$0] }
    }

    private func mergeDrop(existing: DropViewData, incoming: DropViewData) -> DropViewData {
        DropViewData(
            id: existing.id,
            name: existing.name.isEmpty ? incoming.name : existing.name,
            description: existing.description ?? incoming.description,
            imageURL: existing.imageURL ?? incoming.imageURL,
            rewardType: existing.rewardType,
            requiredMinutes: max(existing.requiredMinutes, incoming.requiredMinutes),
            currentMinutes: max(existing.currentMinutes, incoming.currentMinutes),
            progress: max(existing.progress, incoming.progress),
            isClaimed: existing.isClaimed || incoming.isClaimed,
            isClaimable: existing.isClaimable || incoming.isClaimable,
            isEarnable: existing.isEarnable || incoming.isEarnable
        )
    }

    private static func progressFraction(for campaign: CampaignViewData) -> Double? {
        guard !campaign.isClaimed else { return 1.0 }

        let progress = min(max(campaign.progress, 0), 1)
        if progress > 0 {
            return progress
        }

        let dropProgress = campaign.drops
            .filter { !$0.isClaimed }
            .map(\.progress)
            .max() ?? 0

        return dropProgress > 0 ? min(max(dropProgress, 0), 1) : nil
    }

    private func mergedMiningStatus(
        for data: CampaignViewData,
        campaigns: [CampaignViewData],
        allClaimed: Bool,
        anyConnected: Bool
    ) -> MiningCampaignStatus {
        if allClaimed {
            return .claimed
        }

        let hasClaimableRewards = campaigns.contains { campaign in
            campaign.drops.contains { $0.isClaimable && !$0.isClaimed }
        }
        if hasClaimableRewards {
            return .claimable
        }

        let hasActivelyMiningAccount = activeCampaignIds.values.contains { $0 == data.id }
        let hasStartedProgress = campaigns.contains { campaign in
            campaign.progress > 0
                || campaign.dropsClaimed > 0
                || campaign.drops.contains { ($0.currentMinutes > 0) && !$0.isClaimed }
        }

        if hasActivelyMiningAccount || hasStartedProgress {
            return .inProgress
        }

        let hasUnclaimedRewards = campaigns.contains { campaign in
            let knownTotals = campaign.totalDrops > 0 && campaign.dropsClaimed < campaign.totalDrops
            let knownDrops = campaign.drops.contains { !$0.isClaimed }
            return knownTotals || knownDrops
        }
        if anyConnected && hasUnclaimedRewards {
            return .available
        }

        if campaigns.allSatisfy({ $0.endDate <= Date() }) {
            return .expired
        }

        return data.miningStatus
    }

    private func mergedRelevance(
        for data: CampaignViewData,
        campaigns: [CampaignViewData],
        miningStatus: MiningCampaignStatus,
        allClaimed: Bool,
        anyConnected: Bool
    ) -> CampaignRelevance {
        if campaigns.contains(where: { $0.relevance == .prioritised }) {
            return .prioritised
        }

        // 1. Active check — must be connected AND in an active-earnable state
        if anyConnected && (miningStatus == .available ||
            miningStatus == .inProgress ||
            miningStatus == .claimable) {
            return .active
        }

        // 2. Claimed/Recent check — if claimed OR explicitly marked recent by any account
        if allClaimed || miningStatus == .claimed || campaigns.contains(where: { $0.relevance == .recent }) {
            return .recent
        }

        // 3. Closed check
        if miningStatus == .expired || campaigns.contains(where: { $0.relevance == .closed }) {
            return .closed
        }

        // Fallback for connected campaigns: always show at least in 'All' tab (not .irrelevant)
        if anyConnected {
            return .recent
        }

        return data.relevance
    }

    private func mergeCampaignStatus(for data: CampaignViewData, campaigns: [CampaignViewData]) -> String {
        if campaigns.contains(where: { $0.status == CampaignStatus.active.rawValue }) {
            return CampaignStatus.active.rawValue
        }

        if campaigns.contains(where: { $0.status == CampaignStatus.upcoming.rawValue }) {
            return CampaignStatus.upcoming.rawValue
        }

        if campaigns.contains(where: { $0.status == CampaignStatus.expired.rawValue }) {
            return CampaignStatus.expired.rawValue
        }

        return data.status
    }

    private func shouldReplaceMetadata(existing: CampaignViewData, incoming: CampaignViewData) -> Bool {
        if existing.artworkURL == nil && incoming.artworkURL != nil {
            return true
        }

        if incoming.totalDrops > existing.totalDrops {
            return true
        }

        return incoming.drops.count > existing.drops.count
    }

    /// Pre-computes display initials from a username.
    /// "john doe" → "JD", "johndoe" → "JO"
    private static func initials(from username: String) -> String {
        let parts = username.split(separator: " ")
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(username.prefix(2)).uppercased()
    }
}

// MARK: - Supporting Types

public struct AggregateStats: Sendable {
    public let totalCampaigns: Int
    public let activeCampaigns: Int
    public let fullyClaimedCampaigns: Int
    public let totalDrops: Int
    public let totalEarnedDrops: Int
    public let totalClaimedDrops: Int
    public let accountCount: Int
    
    public var completionPercentage: Double {
        guard totalDrops > 0 else { return 0 }
        return Double(totalEarnedDrops) / Double(totalDrops) * 100
    }
    
    public init(
        totalCampaigns: Int,
        activeCampaigns: Int,
        fullyClaimedCampaigns: Int,
        totalDrops: Int,
        totalEarnedDrops: Int,
        totalClaimedDrops: Int,
        accountCount: Int
    ) {
        self.totalCampaigns = totalCampaigns
        self.activeCampaigns = activeCampaigns
        self.fullyClaimedCampaigns = fullyClaimedCampaigns
        self.totalDrops = totalDrops
        self.totalEarnedDrops = totalEarnedDrops
        self.totalClaimedDrops = totalClaimedDrops
        self.accountCount = accountCount
    }
}
