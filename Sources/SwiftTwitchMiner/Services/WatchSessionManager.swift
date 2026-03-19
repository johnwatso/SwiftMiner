import Foundation

/// State of a watch session
public enum WatchSessionState: Sendable, Equatable {
    case idle
    case connecting
    case watching
    case paused
    case completed
    case error(String)

    public static func == (lhs: WatchSessionState, rhs: WatchSessionState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.connecting, .connecting), (.watching, .watching),
             (.paused, .paused), (.completed, .completed):
            return true
        case (.error(let lhsMessage), .error(let rhsMessage)):
            return lhsMessage == rhsMessage
        default:
            return false
        }
    }
}

/// Status updates for watch session callbacks
public enum WatchSessionStatus: Sendable {
    case idle
    case connecting
    case watching(Channel, Drop, Double) // channel, drop, progress percentage
    case completed
    case error(TwitchMinerError)
}

/// Represents an active watch session
public class WatchSession: @unchecked Sendable {
    public let id: String
    public let channelId: String
    public let channelName: String
    public let campaignId: String
    /// Live stream broadcast ID — included in the Spade beacon payload.
    /// Nil when the stream ID isn't available; beacon falls back to "0".
    public var broadcastId: String?
    public let startedAt: Date
    public var state: WatchSessionState
    public var totalWatchTimeSeconds: TimeInterval
    public var lastHeartbeatAt: Date?

    public init(
        id: String,
        channelId: String,
        channelName: String,
        campaignId: String,
        broadcastId: String? = nil,
        startedAt: Date = Date(),
        state: WatchSessionState = .connecting,
        totalWatchTimeSeconds: TimeInterval = 0,
        lastHeartbeatAt: Date? = nil
    ) {
        self.id = id
        self.channelId = channelId
        self.channelName = channelName
        self.campaignId = campaignId
        self.broadcastId = broadcastId
        self.startedAt = startedAt
        self.state = state
        self.totalWatchTimeSeconds = totalWatchTimeSeconds
        self.lastHeartbeatAt = lastHeartbeatAt
    }
}

/// Manager for watch sessions that simulate watching streams
public actor WatchSessionManager {
    private let apiClient: TwitchAPIClient
    private let spadeBeacon: SpadeBeaconService
    private let communityPointsService: CommunityPointsService
    private var activeSession: WatchSession?
    private var heartbeatTask: Task<Void, Never>?

    /// 59-second watch interval — matches the Python reference implementation
    private let heartbeatInterval: TimeInterval = SpadeBeaconService.watchInterval

    /// Session identifier generator
    private var sessionCounter: UInt64 = 0

    /// The authenticated user ID — required for the Spade beacon payload
    public var userId: String = ""

    /// Set the user ID (actor-isolated setter for cross-actor use)
    public func setUserId(_ id: String) { userId = id }

    /// Callbacks
    public var onProgressUpdate: (@Sendable (Progress) -> Void)?
    public var onStatusChange: (@Sendable (WatchSessionStatus) -> Void)?
    public var onError: (@Sendable (TwitchMinerError) -> Void)?

    public init(apiClient: TwitchAPIClient) {
        self.spadeBeacon = SpadeBeaconService()
        self.apiClient = apiClient
        self.communityPointsService = CommunityPointsService(apiClient: apiClient)
    }

    /// Start watching a channel for a specific campaign
    /// - Parameters:
    ///   - channel: The channel to watch
    ///   - campaignId: The campaign ID we're watching for
    /// - Returns: The created WatchSession
    public func startWatching(channel: Channel, campaignId: String) async throws -> WatchSession {
        // Check if session is already active
        if activeSession != nil {
            throw TwitchMinerError.watchSessionFailed("Session already active")
        }

        // Validate channel
        guard !channel.id.isEmpty else {
            throw TwitchMinerError.channelNotFound
        }

        // TDM PARITY: Fetch Playback Access Token to verify session stability
        // If this fails, the channel might be restricted or user ghost-banned from earning.
        _ = try await apiClient.fetchPlaybackAccessToken(channelLogin: channel.login)
        print("[WatchSessionManager] Playback access token verified for \(channel.login)")

        // Fetch broadcast ID for accurate Spade beacons
        let broadcastId = try? await apiClient.fetchBroadcastId(channelLogin: channel.login)
        if broadcastId != nil {
            onStatusChange?(.connecting)
        }

        // Create session
        sessionCounter += 1
        let session = WatchSession(
            id: "session_\(sessionCounter)_\(Date().timeIntervalSince1970)",
            channelId: channel.id,
            channelName: channel.login,
            campaignId: campaignId,
            broadcastId: broadcastId ?? "0",
            state: .connecting
        )

        activeSession = session

        // Start heartbeat loop
        startHeartbeatLoop()

        // Start community points auto-claim
        await communityPointsService.startAutoClaim(channelLogin: channel.login, channelId: channel.id)

        // Update session state to watching
        activeSession?.state = .watching
        activeSession?.lastHeartbeatAt = Date()

        return activeSession!
    }

    /// Stop the current watch session
    public func stopWatching() async {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        await communityPointsService.stopAutoClaim()
        activeSession?.state = .completed
        onStatusChange?(.completed)
        activeSession = nil
    }

    /// Pause the current watch session
    public func pauseWatching() async throws {
        guard activeSession != nil else {
            throw TwitchMinerError.sessionNotStarted
        }

        heartbeatTask?.cancel()
        heartbeatTask = nil
        activeSession?.state = .paused
    }

    /// Resume a paused watch session
    public func resumeWatching() async throws {
        guard let session = activeSession, session.state == .paused else {
            throw TwitchMinerError.sessionNotStarted
        }

        session.state = .watching
        activeSession = session
        startHeartbeatLoop()
    }

    /// Get the current active session
    public var currentSession: WatchSession? {
        activeSession
    }

    /// Check if currently watching
    public var isWatching: Bool {
        activeSession?.state == .watching
    }

    /// Get total watch time in seconds
    public var totalWatchTime: TimeInterval {
        activeSession?.totalWatchTimeSeconds ?? 0
    }

    // MARK: - Public Methods for MinerEngine

    /// Start watching a channel for a specific campaign and drop
    public func startWatching(campaign: Campaign, channel: Channel, drop: Drop) async {
        // Check if session is already active
        if activeSession != nil {
            await stopWatching()
        }

        // Create session
        sessionCounter += 1
        let session = WatchSession(
            id: "session_\(sessionCounter)_\(Date().timeIntervalSince1970)",
            channelId: channel.id,
            channelName: channel.login,
            campaignId: campaign.id,
            state: .connecting
        )

        activeSession = session

        // Notify status change
        onStatusChange?(.connecting)

        // Start heartbeat loop
        startHeartbeatLoop()

        // Start community points auto-claim
        await communityPointsService.startAutoClaim(channelLogin: channel.login, channelId: channel.id)

        // Update session state to watching
        activeSession?.state = .watching
        activeSession?.lastHeartbeatAt = Date()

        // Notify watching status
        onStatusChange?(.watching(channel, drop, 0.0))
    }

    // MARK: - Private Methods

    private func startHeartbeatLoop() {
        heartbeatTask?.cancel()

        heartbeatTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(heartbeatInterval * 1_000_000_000))

                    if Task.isCancelled { break }

                    await sendHeartbeat()
                } catch {
                    break
                }
            }
        }
    }

    private func sendHeartbeat() async {
        guard let session = activeSession, session.state == .watching else {
            return
        }

        do {
            // Send Spade beacon — the real mechanism Twitch uses to credit watch time
            try await spadeBeacon.sendBeacon(
                channelLogin: session.channelName,
                channelId:    session.channelId,
                broadcastId:  session.broadcastId ?? "0",
                userId:       userId
            )

            // Update session stats
            session.lastHeartbeatAt = Date()
            session.totalWatchTimeSeconds += heartbeatInterval
            activeSession = session

        } catch {
            // Non-fatal: log the failure but keep the session alive.
            // The Python reference also continues on beacon errors.
            onError?(.watchSessionFailed("Beacon failed: \(error.localizedDescription)"))
        }
    }
}
