import Foundation

/// Service for automatically claiming Twitch Community Points
public actor CommunityPointsService {
    private let apiClient: TwitchAPIClient
    private var isRunning = false
    private var autoClaimTask: Task<Void, Never>?
    private let checkInterval: TimeInterval = 30 // 30 seconds
    
    public init(apiClient: TwitchAPIClient) {
        self.apiClient = apiClient
    }
    
    /// Start automatic claiming for a channel
    public func startAutoClaim(channelLogin: String, channelId: String) {
        stopAutoClaim()
        isRunning = true
        
        autoClaimTask = Task { [weak self] in
            guard let self = self else { return }
            while await self.isActive() && !Task.isCancelled {
                do {
                    if let context = try await self.apiClient.getChannelPointsContext(channelLogin: channelLogin),
                       let claimId = context.availableClaimId {
                        try await self.apiClient.claimCommunityPoints(channelId: channelId, claimId: claimId)
                    }
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
