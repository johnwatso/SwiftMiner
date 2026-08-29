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

/// Immutable-at-module-boundary snapshot of an active watch session.
///
/// Value semantics ensure callbacks and callers cannot race the manager's
/// actor-isolated mutations through a shared reference.
public struct WatchSession: Sendable {
    public let id: String
    public let channelId: String
    public let channelName: String
    public let campaignId: String
    public let gameName: String
    public let gameId: String
    /// Live stream broadcast ID — included in the Spade beacon payload.
    /// Nil when the stream ID isn't available; beacon falls back to "0".
    public internal(set) var broadcastId: String?
    public let startedAt: Date
    public internal(set) var state: WatchSessionState
    public internal(set) var totalWatchTimeSeconds: TimeInterval
    public internal(set) var lastHeartbeatAt: Date?
    public internal(set) var lastHeartbeatTransport: String?
    public internal(set) var consecutiveHeartbeatFailures: Int

    public init(
        id: String,
        channelId: String,
        channelName: String,
        campaignId: String,
        gameName: String = "",
        gameId: String = "",
        broadcastId: String? = nil,
        startedAt: Date = Date(),
        state: WatchSessionState = .connecting,
        totalWatchTimeSeconds: TimeInterval = 0,
        lastHeartbeatAt: Date? = nil,
        lastHeartbeatTransport: String? = nil,
        consecutiveHeartbeatFailures: Int = 0
    ) {
        self.id = id
        self.channelId = channelId
        self.channelName = channelName
        self.campaignId = campaignId
        self.gameName = gameName
        self.gameId = gameId
        self.broadcastId = broadcastId
        self.startedAt = startedAt
        self.state = state
        self.totalWatchTimeSeconds = totalWatchTimeSeconds
        self.lastHeartbeatAt = lastHeartbeatAt
        self.lastHeartbeatTransport = lastHeartbeatTransport
        self.consecutiveHeartbeatFailures = consecutiveHeartbeatFailures
    }
}

/// Manager for watch sessions that simulate watching streams
public actor WatchSessionManager {
private let apiClient: TwitchAPIClient
private let spadeBeacon: SpadeBeaconService
private let communityPointsService: CommunityPointsService
private var activeSession: WatchSession?
private var heartbeatTask: Task<Void, Never>?
private let heartbeatFailureThreshold: Int
private let runtimeClock: RuntimeClock

/// 59-second watch interval — matches the Python reference implementation
private let heartbeatInterval: TimeInterval

/// Session identifier generator
private var sessionCounter: UInt64 = 0

/// The authenticated user ID — required for the Spade beacon payload
public var userId: String = ""

/// Set the user ID (actor-isolated setter for cross-actor use). Also
/// switches the Spade beacon to the sticky-per-account UA so this miner's
/// watch traffic shares a fingerprint with its auth/API requests.
///
/// The beacon hop is awaited rather than detached: it used to run in a loose `Task`, so a
/// re-login could hand the beacon the previous account's ID after this manager had already
/// moved on, and the next heartbeat would go out under the wrong fingerprint.
public func setUserId(_ id: String) async {
    userId = id
    await spadeBeacon.setAccountId(id)
}

/// Callbacks
public var onProgressUpdate: (@Sendable (Progress) -> Void)?
public var onStatusChange: (@Sendable (WatchSessionStatus) -> Void)?
public var onError: (@Sendable (TwitchMinerError) -> Void)?
public var onHeartbeatSent: (@Sendable (WatchSession) -> Void)?

public func setErrorHandler(_ handler: (@Sendable (TwitchMinerError) -> Void)?) {
    onError = handler
}

public func setHeartbeatSentHandler(_ handler: (@Sendable (WatchSession) -> Void)?) {
    onHeartbeatSent = handler
}

public init(
    apiClient: TwitchAPIClient,
    urlSession: URLSession = .shared,
    heartbeatInterval: TimeInterval = SpadeBeaconService.watchInterval
) {
    self.spadeBeacon = SpadeBeaconService(urlSession: urlSession)
    self.apiClient = apiClient
    self.communityPointsService = CommunityPointsService(apiClient: apiClient)
    self.heartbeatInterval = heartbeatInterval
    self.heartbeatFailureThreshold = 3
    self.runtimeClock = .continuous
}

/// Test seam for deterministic heartbeat timing and failure budgets.
init(
    apiClient: TwitchAPIClient,
    urlSession: URLSession,
    heartbeatInterval: TimeInterval,
    heartbeatFailureThreshold: Int,
    runtimeClock: RuntimeClock
) {
    self.spadeBeacon = SpadeBeaconService(urlSession: urlSession)
    self.apiClient = apiClient
    self.communityPointsService = CommunityPointsService(apiClient: apiClient)
    self.heartbeatInterval = heartbeatInterval
    self.heartbeatFailureThreshold = max(1, heartbeatFailureThreshold)
    self.runtimeClock = runtimeClock
}

    /// Start watching a channel for a specific campaign
    /// - Parameters:
    ///   - channel: The channel to watch
    ///   - campaignId: The campaign ID we're watching for
    /// - Returns: The created WatchSession
    public func startWatching(
        channel: Channel,
        campaignId: String,
        gameName: String = "",
        gameId: String = ""
    ) async throws -> WatchSession {
        // A rescan can reach this boundary just as a previous watch is winding
        // down. Replace that residual session instead of turning a recoverable
        // ordering race into a failed miner worker.
        if activeSession != nil {
            Logger.engine.info("Replacing residual watch session before starting a new one")
            await stopWatching()
        }

        // Validate channel
        guard !channel.id.isEmpty else {
            throw TwitchMinerError.channelNotFound
        }

        // TDM PARITY: Fetch Playback Access Token to verify session stability
        // If this fails, the channel might be restricted or user ghost-banned from earning.
        _ = try await apiClient.fetchPlaybackAccessToken(channelLogin: channel.login)
        Logger.engine.debug("Playback access token verified for \(channel.login)")

        // Fetch broadcast ID for accurate Spade beacons
        let broadcastId = try? await apiClient.fetchBroadcastId(channelLogin: channel.login)
        if broadcastId != nil {
            onStatusChange?(.connecting)
        }

        // Create session
        sessionCounter += 1
        var session = WatchSession(
            id: "session_\(sessionCounter)_\(Date().timeIntervalSince1970)",
            channelId: channel.id,
            channelName: channel.login,
            campaignId: campaignId,
            gameName: gameName,
            gameId: gameId,
            broadcastId: broadcastId ?? "0",
            state: .connecting
        )

        session.state = .watching
        activeSession = session

        // Start heartbeat loop once the session is watchable so the first beacon is sent immediately.
        startHeartbeatLoop()

        // Start community points auto-claim
        await communityPointsService.startAutoClaim(channelLogin: channel.login, channelId: channel.id)

        return session
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
        guard var session = activeSession, session.state == .paused else {
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
        var session = WatchSession(
            id: "session_\(sessionCounter)_\(Date().timeIntervalSince1970)",
            channelId: channel.id,
            channelName: channel.login,
            campaignId: campaign.id,
            gameName: campaign.game.name,
            gameId: campaign.game.id,
            state: .connecting
        )

        // Notify status change
        onStatusChange?(.connecting)

        session.state = .watching
        activeSession = session

        // Start heartbeat loop once the session is watchable so the first beacon is sent immediately.
        startHeartbeatLoop()

        // Start community points auto-claim
        await communityPointsService.startAutoClaim(channelLogin: channel.login, channelId: channel.id)

        // Notify watching status
        onStatusChange?(.watching(channel, drop, 0.0))
    }

    // MARK: - Private Methods

    private func startHeartbeatLoop() {
        heartbeatTask?.cancel()

        heartbeatTask = Task {
            await sendHeartbeat()

            while !Task.isCancelled, activeSession?.state == .watching {
                do {
                    try await runtimeClock.sleep(nanoseconds: UInt64(heartbeatInterval * 1_000_000_000))

                    if Task.isCancelled { break }

                    await sendHeartbeat()
                } catch {
                    break
                }
            }
        }
    }

    private func sendHeartbeat() async {
        guard var session = activeSession, session.state == .watching else {
            return
        }

        do {
            do {
                // Direct Spade is TwitchDropsMiner's current primary watch transport.
                try await spadeBeacon.sendBeacon(
                    channelLogin: session.channelName,
                    channelId:    session.channelId,
                    broadcastId:  session.broadcastId ?? "0",
                    userId:       userId,
                    gameName:     session.gameName,
                    gameId:       session.gameId
                )
                session.lastHeartbeatTransport = "Spade"
            } catch {
                // Retain Twitch's GQL mutation as a fallback if the direct endpoint is
                // transiently unavailable or rejects the beacon.
                try await apiClient.sendSpadeEvents(
                    channelLogin: session.channelName,
                    channelId: session.channelId,
                    broadcastId: session.broadcastId ?? "0",
                    userId: userId,
                    gameName: session.gameName,
                    gameId: session.gameId
                )
                session.lastHeartbeatTransport = "Twitch GQL fallback"
            }

            // Update session stats
            session.lastHeartbeatAt = Date()
            session.totalWatchTimeSeconds += heartbeatInterval
            session.consecutiveHeartbeatFailures = 0
            activeSession = session
            onHeartbeatSent?(session)

        } catch is CancellationError {
            // Expected when a refresh or shutdown cancels an in-flight beacon.
            // It must not count toward the heartbeat failure budget.
            return
        } catch {
            guard !Task.isCancelled else { return }
            session.consecutiveHeartbeatFailures += 1
            activeSession = session

            let category = Self.heartbeatFailureCategory(error)
            if session.consecutiveHeartbeatFailures >= heartbeatFailureThreshold {
                let failure = TwitchMinerError.watchSessionFailed(
                    "Repeated heartbeat delivery failure [\(category)] after \(session.consecutiveHeartbeatFailures) attempts: \(error.localizedDescription)"
                )
                session.state = .error(failure.localizedDescription)
                activeSession = session
                await communityPointsService.stopAutoClaim()
                onStatusChange?(.error(failure))
                onError?(failure)
            } else {
                onError?(.watchSessionFailed(
                    "Beacon failed [\(category)] (\(session.consecutiveHeartbeatFailures)/\(heartbeatFailureThreshold)): \(error.localizedDescription)"
                ))
            }
        }
    }

    static func heartbeatFailureCategory(_ error: Error) -> String {
        if let twitchError = error as? TwitchMinerError {
            switch twitchError {
            case .tokenExpired, .authenticationFailed:
                return "authentication"
            case .rateLimited:
                return "rate-limit"
            case .networkError:
                return "network"
            default:
                break
            }
        }
        if error is URLError { return "network" }
        return "transport"
    }
}
