import Foundation

/// Service for automatically claiming Twitch Community Points
public actor CommunityPointsService {
    private let apiClient: TwitchAPIClient
    private let isEnabled: @Sendable () async -> Bool
    private var isRunning = false
    private var autoClaimTask: Task<Void, Never>?
    private let checkInterval: TimeInterval = 30 // 30 seconds
    
    public init(
        apiClient: TwitchAPIClient,
        isEnabled: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.apiClient = apiClient
        self.isEnabled = isEnabled
    }
    
    /// Start automatic claiming for a channel
    public func startAutoClaim(channelLogin: String, channelId: String) {
        stopAutoClaim()
        isRunning = true
        
        autoClaimTask = Task { [weak self] in
            guard let self = self else { return }
            while await self.isActive() && !Task.isCancelled {
                do {
                    try await self.claimAvailablePoints(channelLogin: channelLogin, channelId: channelId)
                } catch {
                    // Non-fatal, just wait for next cycle
                }
                
                do {
                    try await RuntimeClock.continuous.sleep(
                        nanoseconds: RuntimeClock.nanoseconds(checkInterval)
                    )
                } catch {
                    break
                }
            }
        }
    }
    
    /// Read the live preference on every poll and again after fetching a bonus. A settings
    /// change or channel switch during the request must not trigger a stale claim.
    func claimAvailablePoints(channelLogin: String, channelId: String) async throws {
        guard await isEnabled(), !Task.isCancelled else { return }
        guard let context = try await apiClient.getChannelPointsContext(channelLogin: channelLogin),
              let claimId = context.availableClaimId else { return }
        guard await isEnabled(), !Task.isCancelled else { return }
        try await apiClient.claimCommunityPoints(channelId: channelId, claimId: claimId)
    }

    /// Stop automatic claiming
    public func stopAutoClaim() {
        isRunning = false
        autoClaimTask?.cancel()
        autoClaimTask = nil
    }
    
    private func isActive() -> Bool {
        isRunning
    }
}
