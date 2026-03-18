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
    /// Campaign cache validity: 1 hour
    private static let campaignCacheDuration: TimeInterval = 3600
    /// Inventory cache validity: 5 minutes (more volatile)
    private static let inventoryCacheDuration: TimeInterval = 300
    
    // MARK: - State
    
    private var lastCampaignLoad: Date?
    private var lastInventoryLoad: Date?
    private var isRefreshing = false
    
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
    
    /// Force a refresh of campaigns and inventory.
    /// Updates disk cache with fresh data.
    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        
        do {
            // Fetch campaigns from API
            let campaigns = try await apiClient.fetchDropCampaigns()
            saveCampaignsToCache(campaigns)
            lastCampaignLoad = Date()
            
            // Fetch inventory (this also updates its own disk cache)
            _ = try await inventoryService.fetchInventory(forceRefresh: true)
            lastInventoryLoad = Date()
            
        } catch {
            print("[CampaignDataService] Refresh failed: \(error)")
            // Don't throw - cached data is still available
        }
    }
    
    /// Clear all cached data for this account.
    public func clearCache() {
        CampaignDiskCache.clear(accountId: accountId)
        inventoryService.clearCache()
        lastCampaignLoad = nil
        lastInventoryLoad = nil
    }
    
    // MARK: - Private: Cache Management
    
    private func loadCachedCampaigns() -> [Campaign] {
        guard !shouldInvalidateCampaignCache() else {
            return []
        }
        return CampaignDiskCache.load(accountId: accountId)
    }
    
    private func saveCampaignsToCache(_ campaigns: [Campaign]) {
        CampaignDiskCache.save(campaigns: campaigns, accountId: accountId)
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
    private static let directoryName = "com.swifttwitchminer"
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
            
            // Atomic write: write to temp file, then move
            let tempURL = fileURL.appendingPathExtension("tmp")
            try data.write(to: tempURL, options: .atomic)
            try FileManager.default.moveItem(at: tempURL, to: fileURL)
            
        } catch {
            print("[CampaignDiskCache] Save failed: \(error)")
        }
    }
    
    /// Load campaigns from disk for a specific account.
    /// Returns empty array if cache is invalid or missing.
    static func load(accountId: String) -> [Campaign] {
        guard !accountId.isEmpty else { return [] }
        
        let fileURL = fileURL(accountId: accountId)
        
        guard let data = try? Data(contentsOf: fileURL),
              let envelope = try? JSONDecoder().decode(CacheEnvelope.self, from: data) else {
            return []
        }
        
        // Validate version
        guard envelope.version == currentVersion else {
            print("[CampaignDiskCache] Version mismatch, ignoring cache")
            clear(accountId: accountId)
            return []
        }
        
        // Validate account ID matches
        guard envelope.accountId == accountId else {
            print("[CampaignDiskCache] Account ID mismatch, ignoring cache")
            return []
        }
        
        return envelope.campaigns
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
}
