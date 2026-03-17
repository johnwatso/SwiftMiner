import Foundation

/// Represents a Twitch account with authentication tokens
public struct Account: Codable, Sendable, Equatable {
    public let id: String
    public let username: String
    public let accessToken: String
    public let refreshToken: String
    public let tokenExpiry: Date
    public let scopes: [String]

    public init(
        id: String,
        username: String,
        accessToken: String,
        refreshToken: String,
        tokenExpiry: Date,
        scopes: [String]
    ) {
        self.id = id
        self.username = username
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenExpiry = tokenExpiry
        self.scopes = scopes
    }

    /// Check if the access token is valid (not expired, with 5 minute buffer)
    public var isTokenValid: Bool {
        Date() < tokenExpiry.addingTimeInterval(-300)
    }
}
