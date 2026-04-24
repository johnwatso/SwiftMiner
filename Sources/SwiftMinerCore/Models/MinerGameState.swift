import Foundation

// MARK: - MinerGameActivityState

/// The concrete activity state of a miner for a specific game.
public enum MinerGameActivityState: String, Equatable, Sendable {
    /// Actively mining/earning for this game.
    case watching
    /// No eligible campaigns or nothing to do for this game.
    case idle
    /// Blocked by a resolvable condition (e.g. not linked, no campaign).
    case blocked
}

// MARK: - MinerGameStateReason

/// Optional reason why a miner is in a particular state for a game.
public enum MinerGameStateReason: String, Equatable, Sendable {
    case none
    /// Account not linked for this campaign.
    case notLinked
    /// No active campaigns for this game.
    case noCampaign
    /// No eligible campaigns for this game (e.g. all filtered out or none found).
    case noEligibleCampaign
    /// Campaign has expired.
    case campaignExpired
    /// All drops claimed or none available.
    case noDropsAvailable
    /// No participating channels are currently live for the selected campaign.
    case noLiveStreams
}

// MARK: - MinerGameState

/// Per-miner, per-game state record.
///
/// Resolves the ambiguity of generic "Watching"/"Waiting" labels by
/// explicitly tying miner activity to a specific game and reason.
public struct MinerGameState: Equatable, Sendable {
    /// The miner account this state belongs to.
    public let minerId: String
    /// The game identifier (game ID).
    public let gameId: String
    /// The game name for display.
    public let gameName: String
    /// The current activity state for this game.
    public let state: MinerGameActivityState
    /// Optional reason explaining why the miner is in this state.
    public let reason: MinerGameStateReason
    /// The campaign ID associated with this state, if any.
    public let campaignId: String?

    public init(
        minerId: String,
        gameId: String,
        gameName: String,
        state: MinerGameActivityState,
        reason: MinerGameStateReason = .none,
        campaignId: String? = nil
    ) {
        self.minerId = minerId
        self.gameId = gameId
        self.gameName = gameName
        self.state = state
        self.reason = reason
        self.campaignId = campaignId
    }

    /// Returns `true` if this state represents a blocked condition.
    public var isBlocking: Bool {
        state == .blocked
    }

    /// Returns `true` if the miner is actively watching/earning for this game.
    public var isActive: Bool {
        state == .watching
    }

    /// Returns `true` if the miner is idle for this game.
    public var isIdle: Bool {
        state == .idle
    }
}

// MARK: - ResolvedPrimaryState

/// The resolved primary state for a miner, derived from the full per-game state list.
///
/// Priority order: **watching > ready idle > blocked > other idle**.
public struct ResolvedPrimaryState: Equatable, Sendable {
    /// The single resolved game state that should be shown as the primary visible state.
    public let resolved: MinerGameState?
    /// The full per-game breakdown.
    public let allStates: [MinerGameState]

    public init(gameStates: [MinerGameState]) {
        self.allStates = gameStates

        // Priority: watching > ready idle > blocked > other idle. Blocked campaigns are
        // still listed per game, but they should not prevent mining another earnable
        // prioritised game.
        var blocked: MinerGameState?
        var readyIdle: MinerGameState?
        var fallbackIdle: MinerGameState?
        var watching: MinerGameState?

        for gs in gameStates {
            if gs.isActive, watching == nil {
                watching = gs
            } else if gs.isIdle && gs.reason == .none && readyIdle == nil {
                readyIdle = gs
            } else if gs.isBlocking, blocked == nil {
                blocked = gs
            } else if gs.isIdle && fallbackIdle == nil {
                fallbackIdle = gs
            }
            if watching != nil, readyIdle != nil, blocked != nil, fallbackIdle != nil {
                break
            }
        }

        if let watching {
            self.resolved = watching
        } else if let readyIdle {
            self.resolved = readyIdle
        } else if let blocked {
            self.resolved = blocked
        } else {
            self.resolved = fallbackIdle ?? gameStates.first
        }
    }
}
