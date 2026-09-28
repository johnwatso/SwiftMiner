import Foundation

/// The Twitch client surface that issued an account's OAuth token and any additional
/// first-party browser material required to keep that surface usable.
///
/// Device-flow accounts need only their issuing client ID. Browser accounts also retain the
/// short-lived integrity material and the scoped SDK cookie used to renew it. The OAuth token
/// itself remains on ``Account`` and is deliberately not duplicated here.
public enum TwitchAuthenticationContext: Codable, Sendable, Equatable {
    /// A token issued through Twitch's device-code flow.
    case device(clientID: String)

    /// A token issued from a real Twitch browser session.
    case browser(Browser)

    public struct Browser: Codable, Sendable, Equatable {
        public static let currentSchemaVersion = 1

        public let schemaVersion: Int
        public let clientID: String
        public let origin: String
        public let userAgent: String
        /// Value captured from the `X-Device-Id` header, if present.
        public let xDeviceID: String?
        /// Value captured from the distinct `Device-ID` header, if present.
        public let deviceID: String?
        public let clientSessionID: String?
        public let clientVersion: String?
        public let acceptLanguage: String?
        public let integrityToken: String
        public let capturedAt: Date
        public let expiresAt: Date
        public let sdkCookieValue: String
        public let cookieExpiresAt: Date
        public let generation: Int

        public init(
            schemaVersion: Int = Browser.currentSchemaVersion,
            clientID: String,
            origin: String,
            userAgent: String,
            xDeviceID: String? = nil,
            deviceID: String? = nil,
            clientSessionID: String? = nil,
            clientVersion: String? = nil,
            acceptLanguage: String? = nil,
            integrityToken: String,
            capturedAt: Date,
            expiresAt: Date,
            sdkCookieValue: String,
            cookieExpiresAt: Date,
            generation: Int
        ) {
            self.schemaVersion = schemaVersion
            self.clientID = clientID
            self.origin = origin
            self.userAgent = userAgent
            self.xDeviceID = xDeviceID
            self.deviceID = deviceID
            self.clientSessionID = clientSessionID
            self.clientVersion = clientVersion
            self.acceptLanguage = acceptLanguage
            self.integrityToken = integrityToken
            self.capturedAt = capturedAt
            self.expiresAt = expiresAt
            self.sdkCookieValue = sdkCookieValue
            self.cookieExpiresAt = cookieExpiresAt
            self.generation = generation
        }
    }

    public var clientID: String {
        switch self {
        case .device(let clientID):
            return clientID
        case .browser(let browser):
            return browser.clientID
        }
    }

    private enum Kind: String, Codable {
        case device
        case browser
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case clientID
        case browser
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .device:
            self = .device(clientID: try container.decode(String.self, forKey: .clientID))
        case .browser:
            self = .browser(try container.decode(Browser.self, forKey: .browser))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .device(let clientID):
            try container.encode(Kind.device, forKey: .kind)
            try container.encode(clientID, forKey: .clientID)
        case .browser(let browser):
            try container.encode(Kind.browser, forKey: .kind)
            try container.encode(browser, forKey: .browser)
        }
    }
}

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
    public let authenticationContext: TwitchAuthenticationContext?
    
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
        case authenticationContext
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
        isOperator: Bool = false,
        authenticationContext: TwitchAuthenticationContext? = nil
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
        self.authenticationContext = authenticationContext
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
        self.authenticationContext = try container.decodeIfPresent(
            TwitchAuthenticationContext.self,
            forKey: .authenticationContext
        )
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
        try container.encodeIfPresent(authenticationContext, forKey: .authenticationContext)
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
