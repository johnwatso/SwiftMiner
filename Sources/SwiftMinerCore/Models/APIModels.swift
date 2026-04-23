import Foundation

/// Response from claiming a drop
public struct ClaimDropResponse: Codable, Sendable {
    public let id: String
    public let status: String
    
    public init(id: String, status: String) {
        self.id = id
        self.status = status
    }
}

/// Information about a Twitch user
public struct TwitchUser: Codable, Sendable {
    public let id: String
    public let login: String
    public let displayName: String
    public let type: String
    public let broadcasterType: String
    public let description: String
    public let profileImageUrl: URL?
    public let offlineImageUrl: URL?
    public let viewCount: Int
    public let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, login, type, description
        case displayName = "display_name"
        case broadcasterType = "broadcaster_type"
        case profileImageUrl = "profile_image_url"
        case offlineImageUrl = "offline_image_url"
        case viewCount = "view_count"
        case createdAt = "created_at"
    }
    
    public init(
        id: String,
        login: String,
        displayName: String,
        type: String = "",
        broadcasterType: String = "",
        description: String = "",
        profileImageUrl: URL? = nil,
        offlineImageUrl: URL? = nil,
        viewCount: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.login = login
        self.displayName = displayName
        self.type = type
        self.broadcasterType = broadcasterType
        self.description = description
        self.profileImageUrl = profileImageUrl
        self.offlineImageUrl = offlineImageUrl
        self.viewCount = viewCount
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        login = try container.decode(String.self, forKey: .login)
        displayName = try container.decode(String.self, forKey: .displayName)
        type = try container.decode(String.self, forKey: .type)
        broadcasterType = try container.decode(String.self, forKey: .broadcasterType)
        description = try container.decode(String.self, forKey: .description)
        viewCount = try container.decode(Int.self, forKey: .viewCount)
        createdAt = try container.decode(Date.self, forKey: .createdAt)

        // Handle empty strings in URL fields by treating them as nil
        if let profileStr = try container.decodeIfPresent(String.self, forKey: .profileImageUrl), !profileStr.isEmpty {
            profileImageUrl = URL(string: profileStr)
        } else {
            profileImageUrl = nil
        }

        if let offlineStr = try container.decodeIfPresent(String.self, forKey: .offlineImageUrl), !offlineStr.isEmpty {
            offlineImageUrl = URL(string: offlineStr)
        } else {
            offlineImageUrl = nil
        }
    }
}

/// Response containing user information
public struct TwitchUsersResponse: Codable {
    public let data: [TwitchUser]
}

/// Device code response for authentication flow
public struct DeviceCodeResponse: Codable, Sendable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURI: URL
    public let expiresIn: Int
    public let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
    
    public init(
        deviceCode: String,
        userCode: String,
        verificationURI: URL,
        expiresIn: Int,
        interval: Int
    ) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.expiresIn = expiresIn
        self.interval = interval
    }
}

/// Token response after authentication
public struct TokenResponse: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresIn: Int
    public let scope: [String]
    public let tokenType: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
        case tokenType = "token_type"
    }
    
    public init(
        accessToken: String,
        refreshToken: String,
        expiresIn: Int,
        scope: [String],
        tokenType: String = "bearer"
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.scope = scope
        self.tokenType = tokenType
    }
    
    /// Custom decoder to handle missing fields and different scope formats
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        refreshToken = try container.decode(String.self, forKey: .refreshToken)
        tokenType = (try? container.decode(String.self, forKey: .tokenType)) ?? "bearer"
        
        // expires_in might be missing - default to 0 (no expiry)
        expiresIn = (try? container.decode(Int.self, forKey: .expiresIn)) ?? 0
        
        // Scope can be missing, array, or space-separated string
        if let scopeArray = try? container.decode([String].self, forKey: .scope) {
            scope = scopeArray
        } else if let scopeString = try? container.decode(String.self, forKey: .scope) {
            scope = scopeString.isEmpty ? [] : scopeString.components(separatedBy: " ")
        } else {
            scope = []
        }
    }
}

/// Parsed community points context for a channel.
/// Returned by `TwitchAPIClient.getChannelPointsContext(channelLogin:)`.
public struct ChannelPointsContext: Sendable {
    /// Current point balance for the viewer
    public let balance: Int
    /// Claim ID if a channel-points bonus is available to claim, nil otherwise
    public let availableClaimId: String?

    public var hasBonusAvailable: Bool { availableClaimId != nil }

    public init(balance: Int, availableClaimId: String?) {
        self.balance = balance
        self.availableClaimId = availableClaimId
    }
}
