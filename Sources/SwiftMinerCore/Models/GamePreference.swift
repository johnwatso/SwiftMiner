import Foundation

/// Preference state for a game in the mining selection
public enum PreferenceState: String, Codable, Sendable {
    case preferred
    case excluded
    case neutral
}

/// How a saved game rule identifies campaigns. Exact games retain the existing
/// category-ID/name matching; a family follows a small, explicit set of game
/// series that SwiftMiner can recognise as new titles arrive on Twitch.
public enum GamePreferenceMatch: String, Codable, Sendable {
    case exact
    case gameFamily
}

/// Supported game families. A family is deliberately curated rather than a
/// free-form substring: the rule must be predictable enough to decide what the
/// miner is allowed to watch.
public enum GameFamily: String, Codable, CaseIterable, Sendable {
    case callOfDuty

    private static let tokenPrefix = "swiftminer:family:"

    public var displayName: String {
        switch self {
        case .callOfDuty: return "Call of Duty"
        }
    }

    public var matchingDescription: String {
        switch self {
        case .callOfDuty: return "Matches current and future Call of Duty titles"
        }
    }

    /// An opaque priority-list value. The string pipeline predates family
    /// rules; keeping the transport representation opaque lets existing
    /// per-account and engine APIs remain source-compatible.
    public var priorityToken: String { Self.tokenPrefix + rawValue }

    public init?(priorityToken: String) {
        guard priorityToken.hasPrefix(Self.tokenPrefix) else { return nil }
        self.init(rawValue: String(priorityToken.dropFirst(Self.tokenPrefix.count)))
    }

    public static func matching(searchQuery: String) -> [GameFamily] {
        let query = normalized(searchQuery)
        guard !query.isEmpty else { return [] }
        return allCases.filter { normalized($0.displayName).contains(query) || query.contains(normalized($0.displayName)) }
    }

    /// The normalised franchise name a title must equal or start with, followed
    /// by a word boundary. Exposed so clients that cannot call `matches` (the web
    /// dashboard) apply the same rule rather than guessing at one.
    public var matchPrefix: String {
        switch self {
        case .callOfDuty: return "call of duty"
        }
    }

    public func matches(gameName: String) -> Bool {
        // Normalising punctuation makes "Call of Duty: Black Ops" and
        // "Call of Duty – Warzone" behave identically, while the word
        // boundary avoids accepting an unrelated category such as
        // "Call of Dutylike".
        let name = Self.normalized(gameName)
        let prefix = matchPrefix
        return name == prefix || name.hasPrefix(prefix + " ")
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            .reduce(into: "") { result, character in
                if character == " " {
                    if result.last != " " { result.append(character) }
                } else {
                    result.append(character)
                }
            }
            .trimmingCharacters(in: .whitespaces)
    }
}

/// A saved broad-match rule. Curated families keep their stable legacy tokens,
/// while a user can create a safe prefix wildcard from any game-series search
/// such as "NBA" or "FIFA".
public struct GameWildcard: Codable, Hashable, Sendable, Identifiable {
    private static let tokenPrefix = "swiftminer:wildcard:"

    public let displayName: String
    public let matchPrefix: String
    private let family: GameFamily?

    public var id: String { priorityToken }

    public init(family: GameFamily) {
        self.displayName = family.displayName
        self.matchPrefix = Self.normalized(family.displayName)
        self.family = family
    }

    private init(displayName: String, matchPrefix: String, family: GameFamily?) {
        self.displayName = displayName
        self.matchPrefix = matchPrefix
        self.family = family
    }

    /// Makes a prefix wildcard from a deliberate search term. Very short terms
    /// are too broad to be a useful rule (for example, "A").
    public init?(searchQuery: String) {
        let displayName = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = Self.normalized(displayName)
        guard normalized.count >= 2 else { return nil }

        if let family = GameFamily.allCases.first(where: {
            Self.normalized($0.displayName) == normalized
        }) {
            self.init(family: family)
            return
        }

        self.init(displayName: displayName, matchPrefix: normalized, family: nil)
    }

    /// Reads both the original curated token and the generic wildcard token so
    /// existing Call of Duty priorities remain compatible.
    public init?(priorityToken: String) {
        if let family = GameFamily(priorityToken: priorityToken) {
            self.init(family: family)
            return
        }

        guard priorityToken.hasPrefix(Self.tokenPrefix),
              let data = Data(base64Encoded: String(priorityToken.dropFirst(Self.tokenPrefix.count))),
              let displayName = String(data: data, encoding: .utf8) else {
            return nil
        }
        self.init(searchQuery: displayName)
    }

    public var priorityToken: String {
        if let family { return family.priorityToken }
        return Self.tokenPrefix + Data(displayName.utf8).base64EncodedString()
    }

    public var matchingDescription: String {
        family?.matchingDescription ?? "Matches game titles beginning with \(displayName)"
    }

    public func matches(gameName: String) -> Bool {
        if let family { return family.matches(gameName: gameName) }
        let name = Self.normalized(gameName)
        return name == matchPrefix || name.hasPrefix(matchPrefix + " ")
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            .reduce(into: "") { result, character in
                if character == " " {
                    if result.last != " " { result.append(character) }
                } else {
                    result.append(character)
                }
            }
            .trimmingCharacters(in: .whitespaces)
    }
}

/// One parsing and matching point for the legacy `[String]` priority pipeline.
/// Family tokens are only ever persisted by `GamePreference`; ordinary strings
/// remain exact game IDs or names exactly as they behaved before this feature.
public struct PriorityGameMatcher: Sendable {
    public let rules: [String]

    public init(_ rules: [String]) {
        self.rules = rules
    }

    public func priorityIndex(gameId: String, gameName: String) -> Int {
        let normalizedID = Self.normalized(gameId)
        let normalizedName = Self.normalized(gameName)
        return rules.firstIndex { rule in
            if let wildcard = GameWildcard(priorityToken: rule) {
                return wildcard.matches(gameName: gameName)
            }
            let key = Self.normalized(rule)
            return !key.isEmpty && (key == normalizedID || key == normalizedName)
        } ?? .max
    }

    public func matches(gameId: String, gameName: String) -> Bool {
        priorityIndex(gameId: gameId, gameName: gameName) != .max
    }

    /// Discovery still needs a human-readable category lookup term. A family
    /// starts with its stable franchise name; the regular all-games discovery
    /// pass then fills in every active title it finds.
    public var discoveryGames: [String] {
        var seen = Set<String>()
        return rules.compactMap { rule in
            let value = GameWildcard(priorityToken: rule)?.displayName ?? rule
            let key = Self.normalized(value)
            return !key.isEmpty && seen.insert(key).inserted ? value : nil
        }
    }

    public static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// A user's preference for a specific Twitch game.
/// Persisted as JSON in @AppStorage via Settings.
public struct GamePreference: Codable, Sendable, Identifiable, Equatable {
    public var id: String {
        gameId.isEmpty ? gameName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : gameId
    }
    public let gameId: String
    public let gameName: String
    public let boxArtURL: URL?
    public let customArtworkURL: URL?
    public var state: PreferenceState
    public let match: GamePreferenceMatch

    public var gameFamily: GameFamily? {
        guard match == .gameFamily else { return nil }
        return GameFamily.allCases.first { $0.displayName.caseInsensitiveCompare(gameName) == .orderedSame }
    }

    /// Includes both the original curated family and a wildcard the user made
    /// from a series search term.
    public var wildcard: GameWildcard? {
        guard match == .gameFamily else { return nil }
        if let wildcard = GameWildcard(priorityToken: gameId) { return wildcard }
        guard let family = gameFamily else { return nil }
        return GameWildcard(family: family)
    }

    public var isWildcard: Bool { wildcard != nil }

    public var priorityToken: String {
        wildcard?.priorityToken ?? gameName
    }

    public init(
        gameId: String,
        gameName: String,
        boxArtURL: URL? = nil,
        customArtworkURL: URL? = nil,
        state: PreferenceState,
        match: GamePreferenceMatch = .exact
    ) {
        self.gameId = gameId
        self.gameName = gameName
        self.boxArtURL = TwitchBoxArt.sized(Self.durableArtworkURL(boxArtURL))
        self.customArtworkURL = customArtworkURL
        self.state = state
        self.match = match
    }

    /// Preferences live in `@AppStorage` and outlive app updates, so one written before box-art
    /// sizing existed still holds Twitch's small default. Decoding through the initialiser
    /// upgrades it in place — without this, prioritised tiles stay soft on an existing install
    /// while a fresh one looks correct.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            gameId: try container.decode(String.self, forKey: .gameId),
            gameName: try container.decode(String.self, forKey: .gameName),
            boxArtURL: try container.decodeIfPresent(URL.self, forKey: .boxArtURL),
            customArtworkURL: try container.decodeIfPresent(URL.self, forKey: .customArtworkURL),
            state: try container.decode(PreferenceState.self, forKey: .state),
            match: try container.decodeIfPresent(GamePreferenceMatch.self, forKey: .match) ?? .exact
        )
    }

    /// `boxArtURL` is written from whatever artwork the UI had resolved at the time, which for a
    /// while could be a `file://` path inside `~/Library/Caches`. That directory is purgeable by
    /// macOS, so preferences persisted a link that could simply evaporate, leaving a permanently
    /// blank tile with no route back to the remote image. Only remote URLs are durable enough to
    /// store here; artwork the user deliberately uploaded lives in `customArtworkURL` under
    /// Application Support and is left alone.
    private static func durableArtworkURL(_ url: URL?) -> URL? {
        guard let url, url.isFileURL else { return url }
        return nil
    }

    /// `boxArtURL` as it should actually be rendered. Preferences written before
    /// cache paths were rejected may still hold one, and that file may be gone —
    /// treat a missing file as absent so callers fall back to live artwork.
    public var resolvedBoxArtURL: URL? {
        guard let boxArtURL else { return nil }
        guard boxArtURL.isFileURL else { return boxArtURL }
        return FileManager.default.fileExists(atPath: boxArtURL.path) ? boxArtURL : nil
    }
}

/// Optional game-scoped fallback streamer used only after verified drop progress stalls.
public struct GameFailoverStreamer: Codable, Sendable, Identifiable, Equatable {
    public var id: String {
        gameId.isEmpty ? gameName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : gameId
    }

    public let gameId: String
    public let gameName: String
    public let streamerLogin: String
    public var enabled: Bool

    public init(
        gameId: String,
        gameName: String,
        streamerLogin: String,
        enabled: Bool = true
    ) {
        self.gameId = gameId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.gameName = gameName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.streamerLogin = Self.normalizedStreamerLogin(streamerLogin) ?? ""
        self.enabled = enabled
    }

    public static func normalizedStreamerLogin(_ login: String?) -> String? {
        guard let login else { return nil }
        var value = login.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let hostRange = value.range(of: "twitch.tv/", options: [.caseInsensitive]) {
            value = String(value[hostRange.upperBound...])
        }

        if let stop = value.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            value = String(value[..<stop])
        }

        let cleaned = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            .lowercased()
        return cleaned.isEmpty ? nil : cleaned
    }
}
