import Foundation

/// Observable store for account-specific drop states (Phase 2).
///
/// `AccountStateStore` manages progress and claimed status for a single user account.
/// It works independently of global campaign discovery and handles mapping
/// Twitch inventory to internal state.
@Observable
@MainActor
public final class AccountStateStore: Identifiable {
    
    // MARK: - Public state
    
    public let accountId: String
    public let username: String
    
    public private(set) var dropStates: [DropState] = []
    public private(set) var isLoading = false
    public private(set) var lastError: Error?
    public private(set) var lastUpdated: Date?

    // MARK: - Private
    
    private let dropsService: DropsService
    private var refreshTask: Task<Void, Never>?
    private let refreshInterval: TimeInterval = 60 // 1 minute

    // MARK: - Init
    
    public init(accountId: String, username: String, dropsService: DropsService) {
        self.accountId = accountId
        self.username = username
        self.dropsService = dropsService
    }

    // MARK: - Lifecycle
    
    /// Start account-state hydration without blocking miner startup.
    ///
    /// Mining is the critical path at launch. A full drop-state refresh can require
    /// dozens of campaign-detail requests, so it runs after an initial grace period
    /// and then continues on the normal refresh cadence.
    public func start(initialDelay: TimeInterval = 0) {
        stopAutoRefresh()
        refreshTask = Task { [weak self] in
            if initialDelay > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(initialDelay * 1_000_000_000))
                } catch {
                    return
                }
            }

            guard !Task.isCancelled, let self else { return }
            await self.refresh()

            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(self.refreshInterval * 1_000_000_000))
                } catch {
                    return
                }
                guard !Task.isCancelled else { break }
                await self.refresh()
            }
        }
    }
    
    public func stop() {
        stopAutoRefresh()
    }

    /// Populates drop states from cached campaigns at launch, so progress figures
    /// aren't zero for the ~60s before the first hydration lands.
    ///
    /// Needs no cache of its own: `DropState` is derived entirely from campaigns
    /// plus an inventory snapshot, and both of those are already on disk. This
    /// mirrors the mapping in `DropsService.fetchDropStates` against caller-supplied
    /// campaigns that have had the cached inventory merged in.
    ///
    /// Leaves `lastUpdated` nil — nothing has been verified with Twitch yet, and
    /// claiming otherwise would misreport freshness.
    public func seed(from campaigns: [Campaign]) {
        guard dropStates.isEmpty else { return }

        dropStates = campaigns.flatMap { campaign in
            campaign.drops.map { drop in
                DropState(
                    dropId: drop.id,
                    accountId: accountId,
                    progressMinutes: drop.progress?.currentMinutes ?? 0,
                    requiredMinutes: drop.requiredMinutes,
                    isClaimed: drop.isClaimed,
                    isEligible: campaign.isAccountConnected,
                    lastUpdated: drop.progress?.lastUpdated ?? Date()
                )
            }
        }
    }

    // MARK: - Refresh
    
    public func refresh(forceRefresh: Bool = false) async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            // In Phase 2, we update existing DropsService to provide these states.
            // We need to provide campaigns to mergeInventory to correctly map IDs,
            // so we might still need to fetch campaigns once here or have them passed in.
            let states = try await dropsService.fetchDropStates(for: accountId, forceRefresh: forceRefresh)
            self.dropStates = states
            self.lastUpdated = Date()
            self.lastError = nil
            Logger.storage.debug("[\(username)] Refreshed: \(states.count) states")
        } catch {
            self.lastError = error
            Logger.storage.error("[\(username)] Refresh failed: \(error)")
        }
    }

    // MARK: - Auto-refresh

    public func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }
}
