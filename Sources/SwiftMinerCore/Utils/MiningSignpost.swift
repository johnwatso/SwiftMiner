import Foundation
import os.signpost

/// Instruments signposts for the mining loop.
///
/// The existing `PerformanceDiagnostics` samples aggregate CPU, which tells you *that* the app is
/// burning it — one diagnostic showed 44% average while the fleet was idle and mining nothing —
/// but never *where*. Signposts give Instruments named intervals to attribute that time to.
///
/// Zero cost when nothing is recording: `OSSignposter` checks `isEnabled` before formatting, and
/// these are all `.pointsOfInterest`/interval markers rather than log messages.
///
/// Profile a Release build — Debug adds enough overhead to move the numbers you are trying to
/// read. Open Instruments, choose the Points of Interest and CPU Profiler instruments, and filter
/// on the `com.swiftminer` subsystem.
public enum MiningSignpost {
    public static let signposter = OSSignposter(
        subsystem: "com.swiftminer",
        category: .pointsOfInterest
    )

    /// Names kept stable so Instruments traces stay comparable across builds.
    /// `StaticString` cannot back a raw-value enum, so the name is carried explicitly.
    public enum Interval {
        /// One full pass of the mining loop for a single miner.
        case miningCycle
        /// Fetching and enriching campaign data.
        case campaignRefresh
        /// Choosing a channel: directory scan, verification and ACL probes.
        case channelSelection
        /// Liveness probing of a restricted campaign's approved channels.
        case aclProbe
        /// The idle wait between cycles when nothing was selected.
        case idleWait

        var name: StaticString {
            switch self {
            case .miningCycle: return "MiningCycle"
            case .campaignRefresh: return "CampaignRefresh"
            case .channelSelection: return "ChannelSelection"
            case .aclProbe: return "ACLProbe"
            case .idleWait: return "IdleWait"
            }
        }
    }

    /// Runs `body` inside a named signpost interval.
    public static func measure<T>(
        _ interval: Interval,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let name = interval.name
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        defer { signposter.endInterval(name, state) }
        return try await body()
    }

    /// Begins an interval, for call sites where a closure would trip strict concurrency
    /// (wrapping a task group, for instance).
    public static func begin(_ interval: Interval) -> OSSignpostIntervalState {
        signposter.beginInterval(interval.name, id: signposter.makeSignpostID())
    }

    /// Ends an interval started with `begin`.
    public static func end(_ interval: Interval, _ state: OSSignpostIntervalState) {
        signposter.endInterval(interval.name, state)
    }

    /// Marks a one-off event worth seeing on the Instruments timeline.
    public static func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }
}
