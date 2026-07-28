import Foundation

/// Preference state for a game in the mining selection
public enum PreferenceState: String, Codable, Sendable {
    case preferred
    case excluded
    case neutral
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

    public init(
        gameId: String,
        gameName: String,
        boxArtURL: URL? = nil,
        customArtworkURL: URL? = nil,
        state: PreferenceState
    ) {
        self.gameId = gameId
        self.gameName = gameName
        self.boxArtURL = Self.durableArtworkURL(boxArtURL)
        self.customArtworkURL = customArtworkURL
        self.state = state
    }

    /// `boxArtURL` is written from whatever artwork the UI had resolved at the time,
    /// which — with Steam artwork preferred — is a `file://` path inside
    /// `~/Library/Caches`. That directory is purgeable by macOS, so preferences
    /// persisted a link that could simply evaporate, leaving a permanently blank
    /// tile with no route back to the remote image. Only remote URLs are durable
    /// enough to store here; artwork the user deliberately uploaded lives in
    /// `customArtworkURL` under Application Support and is left alone.
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
