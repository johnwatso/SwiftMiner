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
    case browsePagePopular = "BrowsePage_Popular"

    public var id: String { rawValue }

    /// Persisted queries that Twitch has repeatedly rotated in TwitchDropsMiner's
    /// public history, ordered by observed churn through September 2026.
    ///
    /// The Safari recovery scan deliberately concentrates on this set instead of
    /// opening pages for every operation SwiftMiner knows. TDM has recorded nine
    /// `DirectoryPage_Game` changes, five each for `ViewerDropsDashboard`, `Inventory`
    /// and `AvailableDrops`, and four for `DropCampaignDetails`. Every other shared
    /// operation changed at most twice over the same period.
    public static let frequentlyRotated: [GQLQuery] = [
        .directoryPageGame,
        .viewerDropsDashboard,
        .inventory,
        .dropsHighlightServiceAvailableDrops,
        .dropCampaignDetails,
    ]

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
        case .browsePagePopular: return "Live channels"
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
        case .directoryPageGame:
            // Twitch renamed this response field from `directoryPageGame` to `game`.
            // Both variants must still contain the stream edge list SwiftMiner parses.
            return [
                ["data", "game", "streams", "edges"],
                ["data", "directoryPageGame", "streams", "edges"]
            ]
        case .dropsHighlightServiceAvailableDrops:
            return [["data", "channel", "viewerDropCampaigns"]]
        case .browsePagePopular:
            return [["data", "streams", "edges"]]
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
        case .browsePagePopular: return GQLHashes.browsePagePopular
        }
    }
}

/// Current hashes published by TwitchDropsMiner (TDM), whose public history also defines
/// the small set of operations SwiftMiner actively watches for rotations.
///
/// Twitch's website does not always issue the same persisted document that mining clients
/// use. In particular, its `Inventory` request currently shares the operation name but not
/// the document. The recovery session therefore carries TDM's exact operation/hash pair as
/// a fallback. It is still only a candidate: SwiftMiner's normal Twitch request and response
/// contract must accept it before it can become an override.
public enum TwitchDropsMinerQueryCatalog {
    public static let sourceURL = URL(
        string: "https://raw.githubusercontent.com/DevilXD/TwitchDropsMiner/master/constants.py"
    )!

    public enum FetchError: Error {
        case invalidResponse
        case responseTooLarge
        case invalidText
    }

    /// Downloads the current public TDM catalog. Failure is intentionally recoverable: the
    /// Safari session can still collect whatever Twitch's own pages genuinely issue.
    public static func fetch(
        for queries: Set<GQLQuery>,
        using session: URLSession = .shared
    ) async throws -> [GQLQuery: String] {
        var request = URLRequest(
            url: sourceURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 10
        )
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FetchError.invalidResponse
        }
        guard data.count <= 1_000_000 else { throw FetchError.responseTooLarge }
        guard let source = String(data: data, encoding: .utf8) else {
            throw FetchError.invalidText
        }
        return hashes(in: source, for: queries)
    }

    /// Parses only an exact TDM dictionary key + Twitch operation + 64-hex hash tuple.
    /// Python variables, comments, and every other value in the file are ignored.
    public static func hashes(
        in source: String,
        for queries: Set<GQLQuery>
    ) -> [GQLQuery: String] {
        var result: [GQLQuery: String] = [:]
        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)

        for query in queries {
            guard let key = tdmKey[query] else { continue }
            let escapedKey = NSRegularExpression.escapedPattern(for: key)
            let escapedOperation = NSRegularExpression.escapedPattern(for: query.rawValue)
            let pattern = #""\#(escapedKey)"\s*:\s*GQLPersistedQuery\(\s*"\#(escapedOperation)"\s*,\s*"([0-9a-f]{64})""#
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: source, range: fullRange),
                  let hashRange = Range(match.range(at: 1), in: source) else {
                continue
            }
            result[query] = String(source[hashRange])
        }
        return result
    }

    private static let tdmKey: [GQLQuery: String] = [
        .directoryPageGame: "GameDirectory",
        .viewerDropsDashboard: "Campaigns",
        .inventory: "Inventory",
        .dropsHighlightServiceAvailableDrops: "AvailableDrops",
        .dropCampaignDetails: "CampaignDetails",
    ]
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
    /// Browse → Live Channels. Captured from twitch.tv on 2026-09-25; accepts the
    /// `DROPS_ENABLED` system filter across every game.
    public static let browsePagePopular = "97fed6737c9ef90e8552fb7d02bf4e5d20da0af3cad2a5492d9c93f94e95c29e"
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

/// The last browser collection run acknowledged by the native extension handler.
/// This is deliberately separate from query acceptance: it says which operations Safari
/// observed, not whether SwiftMiner later promoted their hashes.
public struct TwitchQueryHashSessionResult: Equatable, Sendable {
    public let succeeded: [GQLQuery]
    public let failed: [GQLQuery]
    public let finishedAt: Date

    public init(succeeded: [GQLQuery], failed: [GQLQuery], finishedAt: Date) {
        self.succeeded = succeeded
        self.failed = failed
        self.finishedAt = finishedAt
    }
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
    /// The Team-ID-prefixed form is supported by macOS without a provisioning
    /// profile. Both the app and its embedded extension are signed by this team.
    public static let suiteName = "FHXMYC956U.com.swiftminer.shared"

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
        }
        clearRejections()
    }

    /// Forget which values were refused, without forgetting what Twitch was last seen using.
    ///
    /// This is what an explicit re-check needs. "Try again" has to mean a hash refused last
    /// time gets another go — but it must not mean throwing away the comparison the screen
    /// is built from, because then an update that fails to deliver anything leaves the user
    /// knowing *less* than before they asked. New observations overwrite the old ones as
    /// they arrive, so there is nothing stale to clear first.
    public func clearRejections() {
        for query in GQLQuery.allCases {
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
    ///
    /// Recording it only reports the state. Going to look for the replacement is an
    /// explicit “Update via Safari…” in Settings → Advanced, never automatic.
    public func recordRecoveryNeeded(for query: GQLQuery) {
        guard defaults.double(forKey: key("recoveryNeeded", query)) == 0 else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: key("recoveryNeeded", query))
    }

    public func clearRecoveryNeeded(for query: GQLQuery) {
        // Called on every successful request, so only write when there is something to clear.
        guard defaults.double(forKey: key("recoveryNeeded", query)) > 0 else { return }
        defaults.removeObject(forKey: key("recoveryNeeded", query))
    }

    /// When this query was first found broken, or nil while it works. Lets a caller wait out
    /// the one transient cause — a single edge node answering from a stale cache — before
    /// interrupting anyone: the next good reply clears the mark.
    public func recoveryNeededSince(for query: GQLQuery) -> Date? {
        let value = defaults.double(forKey: key("recoveryNeeded", query))
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
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

    /// Store the browser run's transport result so the UI can distinguish an extension
    /// that did not answer from one that answered but never saw a particular Twitch query.
    public func recordSessionResult(
        succeeded: [GQLQuery],
        failed: [GQLQuery],
        at date: Date = Date()
    ) {
        var seen = Set<GQLQuery>()
        let uniqueSucceeded = succeeded.filter { seen.insert($0).inserted }
        let uniqueFailed = failed.filter { seen.insert($0).inserted }
        defaults.set(uniqueSucceeded.map(\.rawValue), forKey: "TwitchQueryHash.session.succeeded")
        defaults.set(uniqueFailed.map(\.rawValue), forKey: "TwitchQueryHash.session.failed")
        defaults.set(date.timeIntervalSince1970, forKey: "TwitchQueryHash.session.finishedDate")
    }

    public var latestSessionResult: TwitchQueryHashSessionResult? {
        let timestamp = defaults.double(forKey: "TwitchQueryHash.session.finishedDate")
        guard timestamp > 0 else { return nil }
        let succeeded = (defaults.stringArray(forKey: "TwitchQueryHash.session.succeeded") ?? [])
            .compactMap(GQLQuery.init(rawValue:))
        let succeededSet = Set(succeeded)
        let failed = (defaults.stringArray(forKey: "TwitchQueryHash.session.failed") ?? [])
            .compactMap(GQLQuery.init(rawValue:))
            .filter { !succeededSet.contains($0) }
        return TwitchQueryHashSessionResult(
            succeeded: succeeded,
            failed: failed,
            finishedAt: Date(timeIntervalSince1970: timestamp)
        )
    }

    public func clearSessionResult() {
        defaults.removeObject(forKey: "TwitchQueryHash.session.succeeded")
        defaults.removeObject(forKey: "TwitchQueryHash.session.failed")
        defaults.removeObject(forKey: "TwitchQueryHash.session.finishedDate")
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
