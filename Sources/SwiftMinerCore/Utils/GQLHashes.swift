import Foundation

/// Twitch persisted queries whose hashes can be replaced at runtime.
/// The raw value is Twitch's operation name, shared by browser observations
/// and API requests so unknown operations can never enter the store.
public enum GQLQuery: String, CaseIterable, Codable, Identifiable, Sendable {
    case directoryGameRedirect = "DirectoryGameRedirect"
    case viewerDropsDashboard = "ViewerDropsDashboard"
    case dropCampaignDetails = "DropCampaignDetails"
    case inventory = "Inventory"
    case dropsPageClaimDropRewards = "DropsPage_ClaimDropRewards"
    case playbackAccessToken = "PlaybackAccessToken"
    case directoryPageGame = "DirectoryPage_Game"
    case videoPlayerStreamInfoOverlayChannel = "VideoPlayerStreamInfoOverlayChannel"
    case dropCurrentSessionContext = "DropCurrentSessionContext"
    case dropsHighlightServiceAvailableDrops = "DropsHighlightService_AvailableDrops"
    case channelPointsContext = "ChannelPointsContext"
    case claimCommunityPoints = "ClaimCommunityPoints"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .directoryGameRedirect: return "Game redirect"
        case .viewerDropsDashboard: return "Drops dashboard"
        case .dropCampaignDetails: return "Campaign details"
        case .inventory: return "Drops inventory"
        case .dropsPageClaimDropRewards: return "Claim drop"
        case .playbackAccessToken: return "Playback access"
        case .directoryPageGame: return "Game directory"
        case .videoPlayerStreamInfoOverlayChannel: return "Stream information"
        case .dropCurrentSessionContext: return "Drop progress"
        case .dropsHighlightServiceAvailableDrops: return "Available drops"
        case .channelPointsContext: return "Channel points"
        case .claimCommunityPoints: return "Claim channel points"
        }
    }

    /// The query text to send when the persisted hash for this operation is gone.
    ///
    /// A persisted hash is a *reference* to a document Twitch has stored. When Twitch
    /// retires one there is nothing to look up, and every miner built on that hash stops
    /// until someone ships a replacement — the days-long outage this whole feature exists
    /// to shorten. But the hash was only ever an optimisation: `SendSpadeEvents` has always
    /// posted its document inline, with no hash at all, and Twitch answers it. So an
    /// operation whose document SwiftMiner can state itself never has to wait for anyone.
    ///
    /// Written out only where the document is known exactly. A document that is merely
    /// close would parse into the wrong shape, which is worse than not trying — the
    /// response contract above is the backstop where one exists, and the operation's own
    /// parser is the backstop where it does not.
    public var documentFallback: String? {
        switch self {
        case .dropsPageClaimDropRewards:
            // `dropInstanceID` in, `status` out — exactly what `claimDrop` sends and reads.
            return """
            mutation DropsPage_ClaimDropRewards($input: ClaimDropRewardsInput!) {
              claimDropRewards(input: $input) {
                status
              }
            }
            """
        default:
            return nil
        }
    }

    /// Response shapes that prove the document behind a hash is the one SwiftMiner reads.
    ///
    /// Twitch keys persisted queries by document, not by operation name, so a hash can be
    /// registered, answer 200, and still be a *different* query wearing the same name —
    /// which is exactly how a swapped `Inventory` hash marked every claimed drop unclaimed.
    /// Any one path being present and non-null is enough.
    ///
    /// Only ever consulted for a *discovered* hash. The bundled document is never judged,
    /// so a contract that is too strict can at worst decline an automatic update; it can
    /// never break a working install. An empty list means "no contract yet" and preserves
    /// the old behaviour of trusting the transport.
    ///
    /// Left empty on purpose where a correct response can legitimately omit the field:
    /// `DropCampaignDetails` returns a null `dropCampaign` for a campaign the account
    /// cannot see, and `PlaybackAccessToken` returns nothing for a restricted channel.
    /// Asserting those would retire good hashes on ordinary days.
    public var responseContracts: [[String]] {
        switch self {
        case .inventory:
            return [["data", "currentUser", "inventory", "gameEventDrops"]]
        case .viewerDropsDashboard:
            // Twitch has served this under `currentUser` and at the root; either is fine.
            return [
                ["data", "currentUser", "dropCampaigns"],
                ["data", "dropCampaigns"]
            ]
        default:
            return []
        }
    }

    /// Whether a response body carries what this operation is parsed for.
    /// Vacuously true for an operation with no contract.
    public func responseSatisfiesContract(_ body: Data) -> Bool {
        let contracts = responseContracts
        guard !contracts.isEmpty else { return true }
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return false
        }
        return contracts.contains { path in
            var node: Any? = json
            for key in path {
                guard let dictionary = node as? [String: Any],
                      let next = dictionary[key],
                      !(next is NSNull) else {
                    return false
                }
                node = next
            }
            return true
        }
    }

    public var bundledHash: String {
        switch self {
        case .directoryGameRedirect: return GQLHashes.directoryGameRedirect
        case .viewerDropsDashboard: return GQLHashes.viewerDropsDashboard
        case .dropCampaignDetails: return GQLHashes.dropCampaignDetails
        case .inventory: return GQLHashes.inventory
        case .dropsPageClaimDropRewards: return GQLHashes.dropsPage_ClaimDropRewards
        case .playbackAccessToken: return GQLHashes.playbackAccessToken
        case .directoryPageGame: return GQLHashes.directoryPage_Game
        case .videoPlayerStreamInfoOverlayChannel: return GQLHashes.videoPlayerStreamInfoOverlayChannel
        case .dropCurrentSessionContext: return GQLHashes.currentDrop
        case .dropsHighlightServiceAvailableDrops: return GQLHashes.availableDrops
        case .channelPointsContext: return GQLHashes.channelPointsContext
        case .claimCommunityPoints: return GQLHashes.claimCommunityPoints
        }
    }
}

/// Immutable fallbacks compiled into SwiftMiner.
public enum GQLHashes {
    public static let directoryGameRedirect = "1f0300090caceec51f33c5e20647aceff9017f740f223c3c532ba6fa59f6b6cc"
    public static let viewerDropsDashboard = "c16bb890cc8ce7647a96ee69cd313d423a378a3dedadf630a1017cde18975feb"
    public static let dropCampaignDetails = "039277bf98f3130929262cc7c6efd9c141ca3749cb6dca442fc8ead9a53f77c1"
    public static let inventory = "8337eb8541b314040b0edde0c09c5c7a2783ba1960aa9edfbf3bac16d0fec404"
    public static let dropsPage_ClaimDropRewards = "a455deea71bdc9015b78eb49f4acfbce8baa7ccbedd28e549bb025bd0f751930"
    public static let playbackAccessToken = "ed230aa1e33e07eebb8928504583da78a5173989fadfb1ac94be06a04f3cdbe9"
    public static let directoryPage_Game = "86bcceb4e8b1a51256ff8eed8bd8aae4acacf80d737efe904f84f3aeadf8cafd"
    public static let videoPlayerStreamInfoOverlayChannel = "198492e0857f6aedead9665c81c5a06d67b25b58034649687124083ff288597d"
    public static let currentDrop = "4d06b702d25d652afb9ef835d2a550031f1cf762b193523a92166f40ea3d142b"
    public static let availableDrops = "782dad0f032942260171d2d80a654f88bdd0c5a9dddc392e9bc92218a0f42d20"
    public static let channelPointsContext = "374314de591e69925fce3ddc2bcf085796f56ebb8cad67a0daa3165c03adc345"
    public static let claimCommunityPoints = "46aaeebe02c99afdf4fc97c7c0cba964124bf6b0af229395f1f6d1feed05b3d0"
}

public enum TwitchQueryHashSource: String, Sendable {
    case bundled
    case override
    case candidate
}

public struct TwitchQueryHashResolution: Equatable, Sendable {
    public let hash: String
    public let source: TwitchQueryHashSource
}

public enum TwitchQueryHashDate: String, Sendable {
    case observed = "observedDate"
    case candidate = "candidateDate"
    case accepted = "acceptedDate"
    case rejected = "rejectedDate"
}

/// Persistent runtime overrides shared by SwiftMiner and its Safari extension.
///
/// A candidate is tried by the normal API path. A successful response promotes
/// it to an override; a persisted-query rejection removes it and retries with
/// the immutable bundled value. Each operation has its own defaults key so
/// simultaneous app/extension writes do not replace unrelated observations.
public struct TwitchQueryHashStore: @unchecked Sendable {
    public static let suiteName = "group.com.swiftminer.shared"
    public static let automaticDiscoveryKey = "TwitchQueryHash.automaticDiscovery"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public static var standard: TwitchQueryHashStore {
        #if DEBUG
        TwitchQueryHashStore(defaults: .standard)
        #else
        TwitchQueryHashStore(defaults: UserDefaults(suiteName: suiteName) ?? .standard)
        #endif
    }

    public static func isValidHash(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    public func resolution(for query: GQLQuery) -> TwitchQueryHashResolution {
        if let candidate = candidate(for: query) {
            return TwitchQueryHashResolution(hash: candidate, source: .candidate)
        }
        if let override = override(for: query) {
            return TwitchQueryHashResolution(hash: override, source: .override)
        }
        return TwitchQueryHashResolution(hash: query.bundledHash, source: .bundled)
    }

    public func candidate(for query: GQLQuery) -> String? {
        let candidateKey = key("candidate", query)
        guard let value = validStoredHash(forKey: candidateKey) else { return nil }
        guard value != query.bundledHash,
              value != validStoredHash(forKey: key("override", query)) else {
            defaults.removeObject(forKey: candidateKey)
            defaults.removeObject(forKey: key("candidateDate", query))
            return nil
        }
        return value
    }

    public func override(for query: GQLQuery) -> String? {
        let overrideKey = key("override", query)
        guard let value = validStoredHash(forKey: overrideKey) else { return nil }
        guard value != query.bundledHash else {
            defaults.removeObject(forKey: overrideKey)
            defaults.removeObject(forKey: key("acceptedDate", query))
            return nil
        }
        return value
    }

    @discardableResult
    public func submitCandidate(_ hash: String, for query: GQLQuery) -> Bool {
        guard Self.isValidHash(hash) else { return false }
        // A hash that has already been tried and failed is not a candidate. `clearObservations`
        // lifts this, so an explicit re-check is still a genuine retry.
        guard hash != rejectedHash(for: query) else { return false }
        guard hash != query.bundledHash, hash != override(for: query) else {
            defaults.removeObject(forKey: key("candidate", query))
            defaults.removeObject(forKey: key("candidateDate", query))
            return true
        }
        defaults.set(hash, forKey: key("candidate", query))
        defaults.set(Date().timeIntervalSince1970, forKey: key("candidateDate", query))
        return true
    }

    /// Record that Twitch used this hash, even when it still matches the
    /// bundled fallback. Observation metadata powers the live Safari-check UI;
    /// the value remains an untrusted candidate until Twitch accepts it through
    /// SwiftMiner's normal request path.
    @discardableResult
    public func recordObservation(_ hash: String, for query: GQLQuery) -> Bool {
        guard Self.isValidHash(hash) else { return false }
        defaults.set(hash, forKey: key("observed", query))
        defaults.set(Date().timeIntervalSince1970, forKey: key("observedDate", query))
        return submitCandidate(hash, for: query)
    }

    public func observedHash(for query: GQLQuery) -> String? {
        validStoredHash(forKey: key("observed", query))
    }

    public func clearObservations() {
        for query in GQLQuery.allCases {
            defaults.removeObject(forKey: key("observed", query))
            defaults.removeObject(forKey: key("observedDate", query))
            // Deliberate: an explicit re-check means "try again", so a hash refused last
            // time gets another go rather than being permanently written off.
            defaults.removeObject(forKey: key("rejected", query))
            defaults.removeObject(forKey: key("rejectedDate", query))
        }
    }

    /// Promote the exact candidate used by a successful Twitch request.
    public func accept(_ hash: String, for query: GQLQuery) {
        guard candidate(for: query) == hash else { return }
        defaults.set(hash, forKey: key("override", query))
        defaults.set(Date().timeIntervalSince1970, forKey: key("acceptedDate", query))
        defaults.removeObject(forKey: key("candidate", query))
        defaults.removeObject(forKey: key("candidateDate", query))
        defaults.removeObject(forKey: key("rejected", query))
        defaults.removeObject(forKey: key("rejectedDate", query))
        defaults.removeObject(forKey: key("recoveryNeeded", query))
    }

    /// The last hash that was tried for this query and did not work.
    public func rejectedHash(for query: GQLQuery) -> String? {
        validStoredHash(forKey: key("rejected", query))
    }

    /// Remove a rejected runtime value only when it is still the value that failed.
    /// `source` keeps one miner's stale candidate failure from removing the same
    /// hash after another miner has already promoted it to a validated override.
    @discardableResult
    public func reject(
        _ hash: String,
        for query: GQLQuery,
        source: TwitchQueryHashSource? = nil
    ) -> Bool {
        var removed = false
        if source == nil || source == .candidate, candidate(for: query) == hash {
            defaults.removeObject(forKey: key("candidate", query))
            defaults.removeObject(forKey: key("candidateDate", query))
            removed = true
        }
        if source == nil || source == .override, override(for: query) == hash {
            defaults.removeObject(forKey: key("override", query))
            defaults.removeObject(forKey: key("acceptedDate", query))
            removed = true
        }
        if removed {
            // Remember the value, not just the moment. Twitch keeps serving the same hash
            // on every page load, so without this the extension re-queues a hash that has
            // already failed the moment the user opens Twitch again — try, fail, retire,
            // repeat, with the status row flickering between "validating" and "changed"
            // and never settling.
            defaults.set(hash, forKey: key("rejected", query))
            defaults.set(Date().timeIntervalSince1970, forKey: key("rejectedDate", query))
        }
        return removed
    }

    /// Note that SwiftMiner's own bundled hash for this query has stopped working.
    ///
    /// This is the signal the whole feature exists for: Twitch retired the document, every
    /// miner using it is broken, and a release is days away. The replacement Twitch's own
    /// site moved to is a *successor* of that document, so adopting it is both safe and the
    /// point. A query whose bundled hash still works is never marked, which is what keeps
    /// an unrelated sibling query from being copied over a healthy one.
    public func recordRecoveryNeeded(for query: GQLQuery) {
        guard defaults.double(forKey: key("recoveryNeeded", query)) == 0 else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: key("recoveryNeeded", query))
    }

    public func clearRecoveryNeeded(for query: GQLQuery) {
        defaults.removeObject(forKey: key("recoveryNeeded", query))
    }

    public func queriesNeedingRecovery() -> [GQLQuery] {
        GQLQuery.allCases.filter { defaults.double(forKey: key("recoveryNeeded", $0)) > 0 }
    }

    /// When a refresh was last forced to settle a pending candidate.
    public var lastSettleAttempt: Date? {
        let value = defaults.double(forKey: "TwitchQueryHash.lastSettleAttempt")
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }

    public func recordSettleAttempt(at date: Date = Date()) {
        defaults.set(date.timeIntervalSince1970, forKey: "TwitchQueryHash.lastSettleAttempt")
    }

    /// When discovery was last sent looking, so a broken query cannot reopen Safari on a loop.
    public var lastRecoveryAttempt: Date? {
        let value = defaults.double(forKey: "TwitchQueryHash.lastRecoveryAttempt")
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }

    public func recordRecoveryAttempt(at date: Date = Date()) {
        defaults.set(date.timeIntervalSince1970, forKey: "TwitchQueryHash.lastRecoveryAttempt")
    }

    public func reset(_ query: GQLQuery) {
        for kind in ["observed", "observedDate", "candidate", "candidateDate", "override", "acceptedDate", "rejected", "rejectedDate", "recoveryNeeded"] {
            defaults.removeObject(forKey: key(kind, query))
        }
    }

    public func date(for kind: TwitchQueryHashDate, query: GQLQuery) -> Date? {
        let value = defaults.double(forKey: key(kind.rawValue, query))
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }

    public var automaticDiscoveryEnabled: Bool {
        get { defaults.bool(forKey: Self.automaticDiscoveryKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.automaticDiscoveryKey) }
    }

    private func validStoredHash(forKey key: String) -> String? {
        guard let value = defaults.string(forKey: key), Self.isValidHash(value) else {
            return nil
        }
        return value
    }

    private func key(_ kind: String, _ query: GQLQuery) -> String {
        "TwitchQueryHash.\(kind).\(query.rawValue)"
    }
}
