import Foundation

/// Represents a Twitch channel/stream
public struct Channel: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let login: String
    public let displayName: String
    public let description: String?
    public let profileImageUrl: URL?
    public let isLive: Bool
    public let viewerCount: Int?
    public let gameId: String?
    public let gameName: String?
    public let tags: [String]
    public let hasDropsEnabled: Bool
    
    /// The broadcaster type (e.g., "partner", "affiliate", "")
    public let broadcasterType: String
    
    /// Whether this channel is from the campaign's ACL (Access Control List).
    /// ACL-based channels are prioritized for selection as they're explicitly approved
    /// by the campaign owner and tend to be more reliable.
    public let aclBased: Bool

    public init(
        id: String,
        login: String,
        displayName: String,
        description: String? = nil,
        profileImageUrl: URL? = nil,
        isLive: Bool = false,
        viewerCount: Int? = nil,
        gameId: String? = nil,
        gameName: String? = nil,
        tags: [String] = [],
        hasDropsEnabled: Bool = false,
        broadcasterType: String = "",
        aclBased: Bool = false
    ) {
        self.id = id
        self.login = login
        self.displayName = displayName
        self.description = description
        self.profileImageUrl = profileImageUrl
        self.isLive = isLive
        self.viewerCount = viewerCount
        self.gameId = gameId
        self.gameName = gameName
        self.tags = tags
        self.hasDropsEnabled = hasDropsEnabled
        self.broadcasterType = broadcasterType
        self.aclBased = aclBased
    }

    /// Convenience init used by GQL response parsing (profileImageURL variant)
    public init(id: String, login: String, displayName: String, profileImageURL: URL?) {
        self.id = id
        self.login = login
        self.displayName = displayName
        self.description = nil
        self.profileImageUrl = profileImageURL
        self.isLive = false
        self.viewerCount = nil
        self.gameId = nil
        self.gameName = nil
        self.tags = []
        self.hasDropsEnabled = false
        self.broadcasterType = ""
        self.aclBased = false
    }
}
