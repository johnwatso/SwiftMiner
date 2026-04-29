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
    
    public func start() async {
        await refresh()
        startAutoRefresh()
    }
    
    public func stop() {
        stopAutoRefresh()
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
            print("[AccountStateStore/\(username)] Refreshed: \(states.count) states")
        } catch {
            self.lastError = error
            print("[AccountStateStore/\(username)] Refresh failed: \(error)")
        }
    }

    // MARK: - Auto-refresh

    private func startAutoRefresh() {
        stopAutoRefresh()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64((self?.refreshInterval ?? 300) * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }
    }

    public func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }
}
