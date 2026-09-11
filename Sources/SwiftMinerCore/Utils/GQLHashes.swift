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
        guard hash != query.bundledHash, hash != override(for: query) else {
            defaults.removeObject(forKey: key("candidate", query))
            defaults.removeObject(forKey: key("candidateDate", query))
            return true
        }
        defaults.set(hash, forKey: key("candidate", query))
        defaults.set(Date().timeIntervalSince1970, forKey: key("candidateDate", query))
        return true
    }

    /// Promote the exact candidate used by a successful Twitch request.
    public func accept(_ hash: String, for query: GQLQuery) {
        guard candidate(for: query) == hash else { return }
        defaults.set(hash, forKey: key("override", query))
        defaults.set(Date().timeIntervalSince1970, forKey: key("acceptedDate", query))
        defaults.removeObject(forKey: key("candidate", query))
        defaults.removeObject(forKey: key("candidateDate", query))
        defaults.removeObject(forKey: key("rejectedDate", query))
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
            defaults.set(Date().timeIntervalSince1970, forKey: key("rejectedDate", query))
        }
        return removed
    }

    public func reset(_ query: GQLQuery) {
        for kind in ["candidate", "candidateDate", "override", "acceptedDate", "rejectedDate"] {
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
