import Foundation

/// The single answer to "what is this miner doing right now".
///
/// This exists because there wasn't one. A miner's state was derived independently in at least
/// two places — `ManagedMiner.statusLabel` read `resolvedPrimaryState` (per-game, and only for
/// *prioritised* games), while the activity card read `MinerStatus` (the engine's actual session
/// state). Nothing forced them to agree, and they didn't: a miner waiting for a stream reported
/// "Looking for Streams" on its card and "Drops complete" in its details at the same time. That
/// contradiction was fixed twice at two different layers before it held, because each fix
/// addressed one derivation and left the other intact.
///
/// Every surface now resolves through `resolve(for:)` and only chooses its own wording. New
/// surfaces get the precedence for free, and a precedence change happens in exactly one place.
///
/// The ordering below is the precedence, highest first — operational faults outrank everything,
/// because a stalled miner that reports "Up to Date" hides a real problem.
public enum MinerPresentedState: Equatable, Sendable {
    /// The worker is being restarted and rebuilt.
    case recovering
    /// Running, but it has stopped reporting activity while other miners are healthy.
    case unresponsive
    /// Running, but has not reported liveness recently enough to trust.
    case noRecentActivity
    /// Watching, but Twitch is not crediting progress.
    case notEarning
    /// Not running yet, still coming up.
    case starting
    /// Not running and not coming up.
    case stopped
    /// Deliberately paused by the user.
    case paused
    /// Blocked on something only the user can resolve, such as re-authentication.
    case needsAttention
    /// Re-establishing the Twitch session.
    case reconnecting
    /// Refreshing campaigns and drop progress.
    case updating
    /// Pinned to a specific streamer by a manual override.
    case watchingOverride(login: String)
    /// Actively watching an eligible stream.
    case watching(gameName: String?)
    /// Claiming a completed reward.
    case claiming
    /// Has eligible work but no live channel for it yet.
    case lookingForStreams(gameName: String?)
    /// Nothing left that watching can earn.
    case upToDate

    /// Whether this state asserts the miner has work in flight. Used to prove surfaces never
    /// simultaneously claim the miner is finished and working.
    public var representsActiveWork: Bool {
        switch self {
        case .watching, .watchingOverride, .claiming, .lookingForStreams, .notEarning:
            return true
        case .recovering, .unresponsive, .noRecentActivity, .starting, .stopped, .paused,
             .needsAttention, .reconnecting, .updating, .upToDate:
            return false
        }
    }

    /// Whether this state asserts there is nothing left to do.
    public var representsCompletion: Bool {
        if case .upToDate = self { return true }
        return false
    }

    /// Whether this state reflects a fault the user may need to act on.
    public var isOperationalFault: Bool {
        switch self {
        case .recovering, .unresponsive, .noRecentActivity, .needsAttention:
            return true
        default:
            return false
        }
    }
}

public extension MinerPresentedState {

    /// Resolves the canonical state for a miner.
    ///
    /// Operational health is checked before anything derived from campaign data, because campaign
    /// bookkeeping is meaningless if the worker itself is unhealthy. Only once the miner is known
    /// to be running normally does the engine's session status decide, with per-game state used
    /// solely to name the game — never to override what the engine says it is doing. Deriving the
    /// *state* from per-game data was the original defect: those states only cover prioritised
    /// games, so a miner working a non-prioritised campaign described itself from games it had
    /// already finished.
    @MainActor
    static func resolve(for miner: MinerManager.ManagedMiner) -> MinerPresentedState {
        if miner.workerState.isRecovering { return .recovering }
        if miner.isStalled { return .unresponsive }
        if miner.showsNoRecentActivityAttention { return .noRecentActivity }
        if miner.showsNotEarningAttention { return .notEarning }

        if !miner.isRunning {
            switch miner.status {
            case .authenticating: return .starting
            case .paused: return .paused
            case .error: return .needsAttention
            case .idle, .fetchingCampaigns, .watching, .claiming, .waitingForStream,
                 .idleNoEligibleCampaigns, .blockedAccountNotLinked:
                return .stopped
            }
        }

        if miner.needsAuth { return .needsAttention }

        if let overrideLogin = miner.streamOverrideLogin, !overrideLogin.isEmpty {
            return .watchingOverride(login: overrideLogin)
        }

        switch miner.status {
        case .watching:
            return .watching(gameName: activeGameName(for: miner))
        case .claiming:
            return .claiming
        case .waitingForStream:
            return .lookingForStreams(gameName: activeGameName(for: miner))
        case .fetchingCampaigns:
            return .updating
        case .authenticating:
            return .reconnecting
        case .paused:
            return .paused
        case .error:
            return .needsAttention
        case .idle, .idleNoEligibleCampaigns, .blockedAccountNotLinked:
            return .upToDate
        }
    }

    /// The game the miner is currently working, if one can be named.
    ///
    /// Prefers the live watch target, then the most recent channel-availability probe. The probe
    /// map is what makes a waiting miner nameable at all: the no-channel path clears the watch
    /// target before waiting, so during a wait it is the only durable record of the campaign the
    /// miner is waiting on.
    @MainActor
    private static func activeGameName(for miner: MinerManager.ManagedMiner) -> String? {
        if let currentId = miner.currentCampaignId,
           let campaign = miner.allCampaigns.first(where: { $0.id == currentId }) {
            return campaign.game.name
        }

        let recentProbes = miner.gameChannelAvailability.values.sorted { $0.checkedAt > $1.checkedAt }
        for probe in recentProbes {
            guard let campaignId = probe.campaignId,
                  let campaign = miner.allCampaigns.first(where: { $0.id == campaignId }) else { continue }
            return campaign.game.name
        }
        return nil
    }
}
