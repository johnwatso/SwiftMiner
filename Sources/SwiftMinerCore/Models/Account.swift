import Foundation

/// Represents a Twitch account with authentication tokens
public struct Account: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let username: String
    public let nickname: String?
    public let ownerDiscordId: String?
    public let accessToken: String
    public let refreshToken: String
    public let tokenExpiry: Date
    public let scopes: [String]
    public let isOperator: Bool
    
    private enum CodingKeys: String, CodingKey {
        case id
        case username
        case nickname
        case ownerDiscordId
        case accessToken
        case refreshToken
        case tokenExpiry
        case scopes
        case isOperator
    }

    public init(
        id: String,
        username: String,
        nickname: String? = nil,
        ownerDiscordId: String? = nil,
        accessToken: String,
        refreshToken: String,
        tokenExpiry: Date,
        scopes: [String],
        isOperator: Bool = false
    ) {
        self.id = id
        self.username = username
        self.nickname = Self.normalizedNickname(nickname)
        self.ownerDiscordId = ownerDiscordId
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenExpiry = tokenExpiry
        self.scopes = scopes
        self.isOperator = isOperator
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.username = try container.decode(String.self, forKey: .username)
        self.nickname = try container.decodeIfPresent(String.self, forKey: .nickname)
        self.ownerDiscordId = try container.decodeIfPresent(String.self, forKey: .ownerDiscordId)
        self.accessToken = try container.decode(String.self, forKey: .accessToken)
        self.refreshToken = try container.decode(String.self, forKey: .refreshToken)
        self.tokenExpiry = try container.decode(Date.self, forKey: .tokenExpiry)
        self.scopes = try container.decode([String].self, forKey: .scopes)
        self.isOperator = try container.decodeIfPresent(Bool.self, forKey: .isOperator) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(username, forKey: .username)
        try container.encode(nickname, forKey: .nickname)
        try container.encode(ownerDiscordId, forKey: .ownerDiscordId)
        try container.encode(accessToken, forKey: .accessToken)
        try container.encode(refreshToken, forKey: .refreshToken)
        try container.encode(tokenExpiry, forKey: .tokenExpiry)
        try container.encode(scopes, forKey: .scopes)
        try container.encode(isOperator, forKey: .isOperator)
    }

    /// Check if the access token is valid (not expired, with 5 minute buffer)
    public var isTokenValid: Bool {
        Date() < tokenExpiry.addingTimeInterval(-300)
    }

    public var displayName: String {
        nickname ?? username
    }

    public static func normalizedNickname(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
