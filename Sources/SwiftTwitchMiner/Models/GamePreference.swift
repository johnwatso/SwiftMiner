import Foundation

/// Preference state for a game in the mining selection
public enum PreferenceState: String, Codable, Sendable {
    case preferred
    case excluded
}

/// A user's preference for a specific Twitch game.
/// Persisted as JSON in @AppStorage via Settings.
public struct GamePreference: Codable, Sendable, Identifiable, Equatable {
    public var id: String { gameId }
    public let gameId: String
    public let gameName: String
    public let boxArtURL: URL?
    public var state: PreferenceState

    public init(gameId: String, gameName: String, boxArtURL: URL? = nil, state: PreferenceState) {
        self.gameId = gameId
        self.gameName = gameName
        self.boxArtURL = boxArtURL
        self.state = state
    }
}
