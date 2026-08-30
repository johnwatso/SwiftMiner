import Foundation

/// Service that provides UI-ready campaign data with offline-first support.
/// This is the primary data interface for the UI layer.
///
/// Features:
/// - Offline-first: Returns cached data immediately, refreshes in background
/// - Per-account isolation: Each account has isolated campaign + inventory cache
/// - Atomic operations: Disk writes are atomic to prevent corruption
/// - Versioned cache: Handles schema migrations gracefully
public actor CampaignDataService {
    
    // MARK: - Dependencies
    
    private let apiClient: TwitchAPIClient
    private let inventoryService: InventoryService
    private let accountId: String
    
    // MARK: - Cache Configuration
    
    /// Cache version for schema migrations
    private static let cacheVersion = 1
    /// Campaign cache validity: 1 minute
    private static let campaignCacheDuration: TimeInterval = 60
    /// Inventory cache validity: 1 minute
    private static let inventoryCacheDuration: TimeInterval = 60
    /// Refresh unchanged disk snapshots periodically so launch seeding remains current.
    private static let persistenceRefreshInterval: TimeInterval = 30 * 60
    
    // MARK: - State
    
    private var lastCampaignLoad: Date?
    private var lastInventoryLoad: Date?
    private var lastCleanupDate: Date?
    private var cachedCampaigns: [Campaign]?
    private var refreshTask: Task<Void, Never>?
    private var lastCampaignPersistenceAt: Date?
    /// Cleanup runs at most once per day to avoid unnecessary disk writes.
    private static let cleanupInterval: TimeInterval = 86400
    
    // MARK: - Initialization
    
    public init(
        apiClient: TwitchAPIClient,
        inventoryService: InventoryService,
        accountId: String
    ) {
        self.apiClient = apiClient
        self.inventoryService = inventoryService
        self.accountId = accountId
    }
    
    // MARK: - Public API: UI-Ready Data Access
    
    /// Get all campaigns as UI-ready view data.
    /// Returns cached data immediately if available, then refreshes in background.
    public func getAllCampaigns() async -> [CampaignViewData] {
        // Try to get cached campaigns
        let cachedCampaigns = loadCachedCampaigns()
        let cachedInventory = await inventoryService.currentSnapshot()

        // Map to view data using cached data
        let viewData = CampaignMapper.map(
            campaigns: cachedCampaigns,
            inventory: cachedInventory
        )

        // Trigger background refresh if cache is stale
        if shouldRefreshCampaigns() || shouldRefreshInventory() {
            Task {
                await refresh()
            }
        }

        return viewData
    }

    /// Get only mining-eligible campaigns as UI-ready view data.
    /// Filters to campaigns that are:
    /// - Active (time window)
    /// - Account linked
    /// - Have unclaimed drops
    public func getEligibleCampaigns() async -> [CampaignViewData] {
        let all = await getAllCampaigns()
        return all.filter { viewData in
            // A campaign is eligible for mining if:
            // 1. It's active
            // 2. Not all drops are claimed
            // 3. Account is linked (this is checked at the campaign level in DropsService)
            viewData.status == "ACTIVE" && !viewData.isClaimed
        }
    }

    /// Get a single campaign by ID as UI-ready view data.
    /// Returns nil if campaign not found in cache or API.
    public func getCampaign(id: String) async -> CampaignViewData? {
        // Check cache first
        let cached = loadCachedCampaigns()
        if let campaign = cached.first(where: { $0.id == id }) {
            let inventory = await inventoryService.currentSnapshot()
            return CampaignMapper.mapSingle(campaign: campaign, inventory: inventory)
        }

        // If not in cache, try to refresh
        await refresh()

        // Check again after refresh
        let refreshed = loadCachedCampaigns()
        guard let campaign = refreshed.first(where: { $0.id == id }) else {
            return nil
        }
        
        let inventory = await inventoryService.currentSnapshot()
        return CampaignMapper.mapSingle(campaign: campaign, inventory: inventory)
    }
    
    /// Check if a specific drop is claimed using benefit ID.
    /// Works offline using cached inventory.
    public func isDropClaimed(benefitID: String) async -> Bool {
        await inventoryService.isDropClaimed(benefitID: benefitID)
    }
    
    // MARK: - Public API (Parts 9)

    /// Returns cached campaigns immediately — never waits for the network.
    /// This is the synchronous entry point for app launch / UI binding.
    /// NOTE: This applies the curated feed filter (excludes .irrelevant campaigns).
    public func currentCampaigns() async -> [CampaignViewData] {
        let cached = loadCachedCampaigns()
        let inventory = await inventoryService.currentSnapshot()
        let composed = CampaignMapper.composeFeed(from: CampaignMapper.map(campaigns: cached, inventory: inventory))
        return composed
    }
    
    /// Returns ALL cached campaigns without filtering.
    /// Use this for the "All" tab to show complete campaign history.
    /// This includes campaigns that would be excluded from the curated feed.
    public func allCampaigns() async -> [CampaignViewData] {
        let cached = loadCachedCampaigns()
        let inventory = await inventoryService.currentSnapshot()
        // Don't use composeFeed() — return all campaigns including .irrelevant
        return CampaignMapper.map(campaigns: cached, inventory: inventory)
    }

    /// Performs an async fetch + merge, then updates the disk cache.
    /// Safe to call at any time; will not block callers of currentCampaigns().
    public func refreshCampaigns() async {
        await refresh()
    }

    /// Force a refresh of campaigns and inventory.
    /// Merges fresh API data into the existing cache — never replaces it wholesale.
    public func refresh() async {
        if let refreshTask {
            await refreshTask.value
            return
        }

        let task = Task { await self.performRefresh() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        do {
            // Parallelize fetching inventory and campaigns
            async let inventoryTask = try? inventoryService.fetchInventory(forceRefresh: true)
            async let campaignsTask = apiClient.fetchDropCampaigns()

            let inventory = await inventoryTask
            let dashboardCampaigns = try await campaignsTask

            if inventory != nil { lastInventoryLoad = Date() }

            // Merge discovered campaigns from inventory (some campaigns like CDL are missing from dashboard)
            // Also trust inventory for isAccountConnected status
            var fresh = dashboardCampaigns
            if let snapshot = inventory {
                for discovered in snapshot.discoveredCampaigns {
                    if let index = fresh.firstIndex(where: { $0.id == discovered.id }) {
                        let existing = fresh[index]
                        let merged = CampaignService.mergeDashboardCampaign(existing, withInventory: discovered)
                        if merged.isAccountConnected && !existing.isAccountConnected {
                            Logger.campaigns.info("Inventory confirmed connection for \(discovered.name)")
                        }
                        if existing.channels.isEmpty && !merged.channels.isEmpty {
                            Logger.campaigns.info("Inventory supplied \(merged.channels.count) approved channel(s) for \(discovered.name)")
                        }
                        fresh[index] = merged
                    } else {
                        Logger.campaigns.info("Discovered campaign from inventory: \(discovered.name)")
                        fresh.append(discovered)
                    }
                }
            }

            // Load existing cache to merge against.
            let cached = loadCachedCampaigns()
            
            // Fix: handle async outside of potential autoclosure/if-expression
            let current = await inventoryService.currentSnapshot()
            let snapshot: InventorySnapshot? = inventory ?? current

            // Merge: API wins for shared IDs; preserved campaigns follow merge rules.
            let merged = CampaignMergeEngine.merge(fresh: fresh, cached: cached, inventory: snapshot)
            Logger.campaigns.info("Refresh (@\(accountId)): fetched \(fresh.count), merged \(merged.count) campaigns")
            for c in fresh {
                Logger.campaigns.debug("  + Fresh: \(c.name) (Connected: \(c.isAccountConnected))")
            }
            saveCampaignsToCache(merged)
            lastCampaignLoad = Date()

            // Cleanup runs at most once per day to avoid unnecessary disk writes.
            let shouldCleanup = lastCleanupDate.map { Date().timeIntervalSince($0) > Self.cleanupInterval } ?? true
            if shouldCleanup {
                let cleaned = CampaignDiskCache.cleanup(
                    campaigns: merged,
                    accountId: accountId,
                    inventory: snapshot
                )
                cachedCampaigns = cleaned
                if !cleaned.persistenceElementsEqual(merged) {
                    lastCampaignPersistenceAt = Date()
                }
                lastCleanupDate = Date()
            }

        } catch {
            Logger.campaigns.error("Refresh failed: \(error) — cached data preserved.")
            // Don't throw — callers continue to see cached data.
        }
    }
    
    /// Clear all cached data for this account.
    public func clearCache() async {
        CampaignDiskCache.clear(accountId: accountId)
        await inventoryService.clearCache()
        cachedCampaigns = nil
        lastCampaignPersistenceAt = nil
        lastCampaignLoad = nil
        lastInventoryLoad = nil
    }

    /// Clear all cached campaign and inventory snapshots across accounts.
    public static func clearAllCachedDropData() {
        CampaignDiskCache.clearAll()
        InventoryDiskCache.clearAll()
        CampaignDetailsDiskCache.clearAll()
    }
    
    // MARK: - Private: Cache Management
    
    private func loadCachedCampaigns() -> [Campaign] {
        // Always load cached campaigns — the cache is never invalidated by age alone.
        // Stale data triggers a background refresh but is still returned to the UI.
        if let cachedCampaigns {
            return cachedCampaigns
        }
        let loaded = CampaignDiskCache.loadWithMetadata(accountId: accountId)
        cachedCampaigns = loaded.campaigns
        lastCampaignPersistenceAt = loaded.savedAt
        return loaded.campaigns
    }
    
    private func saveCampaignsToCache(_ campaigns: [Campaign]) {
        let contentChanged = !(cachedCampaigns?.persistenceElementsEqual(campaigns) ?? false)
        cachedCampaigns = campaigns
        let now = Date()
        let needsFreshTimestamp = lastCampaignPersistenceAt.map {
            now.timeIntervalSince($0) >= Self.persistenceRefreshInterval
        } ?? true
        guard contentChanged || needsFreshTimestamp else { return }

        CampaignDiskCache.save(campaigns: campaigns, accountId: accountId)
        lastCampaignPersistenceAt = now
    }
    
    private func shouldRefreshCampaigns() -> Bool {
        guard let lastLoad = lastCampaignLoad else { return true }
        return Date().timeIntervalSince(lastLoad) > Self.campaignCacheDuration
    }
    
    private func shouldRefreshInventory() -> Bool {
        guard let lastLoad = lastInventoryLoad else { return true }
        return Date().timeIntervalSince(lastLoad) > Self.inventoryCacheDuration
    }
    
    private func shouldInvalidateCampaignCache() -> Bool {
        // Check if cache envelope indicates stale data
        !CampaignDiskCache.isValid(accountId: accountId, maxAge: Self.campaignCacheDuration)
    }
}

// MARK: - Enhanced Campaign Disk Cache

/// Enhanced disk cache for campaigns with per-account isolation and versioning.
enum CampaignDiskCache {
    private static let directoryName = "com.swiftminer"
    private static let campaignsFolder = "campaigns"
    private static let currentVersion = 1
    
    private struct CacheEnvelope: Codable {
        let version: Int
        let savedAt: Date
        let accountId: String
        let campaigns: [Campaign]
    }
    
    private static func directoryURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(campaignsFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    private static func fileURL(accountId: String) -> URL {
        directoryURL().appendingPathComponent("\(accountId).json")
    }
    
    /// Save campaigns to disk for a specific account.
    /// Uses atomic writes to prevent corruption.
    static func save(campaigns: [Campaign], accountId: String) {
        guard !accountId.isEmpty else { return }
        
        let envelope = CacheEnvelope(
            version: currentVersion,
            savedAt: Date(),
            accountId: accountId,
            campaigns: campaigns
        )
        
        do {
            let data = try JSONEncoder().encode(envelope)
            let fileURL = fileURL(accountId: accountId)

            // Clean up stale legacy temp file from older write strategy.
            let staleTempURL = fileURL.appendingPathExtension("tmp")
            if FileManager.default.fileExists(atPath: staleTempURL.path) {
                try? FileManager.default.removeItem(at: staleTempURL)
            }

            // Atomic replace in-place. This safely overwrites existing cache files.
            try data.write(to: fileURL, options: .atomic)
            
        } catch {
            Logger.campaigns.error("[CampaignDiskCache] Save failed: \(error)")
        }
    }
    
    /// Load campaigns from disk for a specific account.
    /// Returns empty array if cache is invalid or missing.
    static func load(accountId: String) -> [Campaign] {
        loadWithMetadata(accountId: accountId).campaigns
    }

    static func loadWithMetadata(accountId: String) -> (campaigns: [Campaign], savedAt: Date?) {
        guard !accountId.isEmpty else { return ([], nil) }

        let fileURL = fileURL(accountId: accountId)

        guard let data = try? Data(contentsOf: fileURL),
              let envelope = try? JSONDecoder().decode(CacheEnvelope.self, from: data) else {
            return ([], nil)
        }

        // Validate version
        guard envelope.version == currentVersion else {
            Logger.campaigns.warning("[CampaignDiskCache] Version mismatch, ignoring cache")
            clear(accountId: accountId)
            return ([], nil)
        }

        // Validate account ID matches
        guard envelope.accountId == accountId else {
            Logger.campaigns.warning("[CampaignDiskCache] Account ID mismatch, ignoring cache")
            return ([], nil)
        }

        return (envelope.campaigns, envelope.savedAt)
    }
    
    /// Check if cache is valid (exists, correct version, not expired).
    static func isValid(accountId: String, maxAge: TimeInterval) -> Bool {
        guard !accountId.isEmpty else { return false }
        
        let fileURL = fileURL(accountId: accountId)
        
        guard let data = try? Data(contentsOf: fileURL),
              let envelope = try? JSONDecoder().decode(CacheEnvelope.self, from: data) else {
            return false
        }
        
        // Check version
        guard envelope.version == currentVersion else { return false }
        
        // Check account ID
        guard envelope.accountId == accountId else { return false }
        
        // Check age
        return Date().timeIntervalSince(envelope.savedAt) < maxAge
    }

    /// Clear cached campaigns for a specific account.
    static func clear(accountId: String) {
        guard !accountId.isEmpty else { return }
        try? FileManager.default.removeItem(at: fileURL(accountId: accountId))
    }
    
    /// Clear all cached campaigns across all accounts.
    static func clearAll() {
        try? FileManager.default.removeItem(at: directoryURL())
    }
    
    // MARK: - Cleanup (Phase 8)
    
    /// Removes campaigns that are expired >14 days AND not in inventory.
    /// Call this periodically (e.g., on app launch or background refresh) to prevent cache bloat.
    /// - Parameters:
    ///   - accountId: The account ID to cleanup
    ///   - inventory: The current inventory snapshot (to check for claimed drops)
    @discardableResult
    static func cleanup(
        campaigns: [Campaign],
        accountId: String,
        inventory: InventorySnapshot?
    ) -> [Campaign] {
        guard !accountId.isEmpty else { return campaigns }

        let fourteenDays: TimeInterval = 14 * 24 * 3600
        let expirationCutoff = Date().addingTimeInterval(-fourteenDays)
        
        // Keep campaigns that are:
        // 1. Not expired (endDate > now)
        // 2. OR expired <14 days ago (endDate > cutoff)
        // 3. OR have drops in inventory (preservation rule)
        let kept = campaigns.filter { campaign in
            // If not expired, keep
            if campaign.endDate > Date() { return true }
            
            // If expired but <14 days ago, keep
            if campaign.endDate > expirationCutoff { return true }
            
            // If expired >14 days ago but has drops in inventory, keep
            let inInventory = campaign.drops.contains { drop in
                inventory?.benefitIDs.contains(drop.benefitID) ?? false
            }
            if inInventory { return true }
            
            // Expired >14 days ago and not in inventory -> remove
            Logger.campaigns.debug("[CampaignDiskCache] Cleanup: Removing campaign \(campaign.name) (expired \(campaign.endDate))")
            return false
        }
        
        let removed = campaigns.count - kept.count
        if removed > 0 {
            Logger.campaigns.info("[CampaignDiskCache] Cleanup: Removed \(removed) old campaigns, kept \(kept.count)")
            save(campaigns: kept, accountId: accountId)
        }
        return kept
    }
}
