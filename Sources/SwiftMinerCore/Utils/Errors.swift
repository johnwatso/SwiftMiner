import Foundation

/// Represents errors that can occur in the Twitch Miner
public enum TwitchMinerError: LocalizedError {
    case networkError(String)
    case apiError(statusCode: Int, message: String)
    case authenticationFailed(String)
    case tokenExpired
    case sessionNotStarted
    case invalidResponse
    case noActiveCampaigns
    case noDropsToClaim
    case channelNotFound
    case campaignNotFound
    case dropNotFound
    case watchSessionFailed(String)
    /// Twitch's private web API no longer recognises a persisted query or has
    /// changed the response shape SwiftMiner depends on.
    case twitchAPICompatibility(operation: String, reason: String)
    case claimFailed(String)
    case keychainError(String)
    case rateLimited(retryAfter: TimeInterval)
    case dropAlreadyClaimed
    case dropNotReady
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .networkError(let message):
            return "Network error: \(message)"
        case .apiError(let statusCode, let message):
            return "API error (\(statusCode)): \(message)"
        case .authenticationFailed(let message):
            return "Authentication failed: \(message)"
        case .tokenExpired:
            return "Token has expired, please re-authenticate"
        case .sessionNotStarted:
            return "Mining session has not been started"
        case .invalidResponse:
            return "Received invalid response from server"
        case .noActiveCampaigns:
            return "No active drop campaigns available"
        case .noDropsToClaim:
            return "No drops ready to claim"
        case .channelNotFound:
            return "Channel not found"
        case .campaignNotFound:
            return "Campaign not found"
        case .dropNotFound:
            return "Drop not found"
        case .watchSessionFailed(let message):
            return "Watch session failed: \(message)"
        case .twitchAPICompatibility(let operation, _):
            return "Twitch compatibility update required for \(operation). Update SwiftMiner, then try again."
        case .claimFailed(let message):
            return "Claim failed: \(message)"
        case .keychainError(let message):
            return "Keychain error: \(message)"
        case .rateLimited(let retryAfter):
            return "Rate limited — retry after \(Int(retryAfter))s"
        case .dropAlreadyClaimed:
            return "Drop has already been claimed"
        case .dropNotReady:
            return "Drop is not yet ready to claim"
        case .unknown(let message):
            return "Unknown error: \(message)"
        }
    }

    /// These failures are deterministic product compatibility issues, not
    /// account, network, or rate-limit problems that a miner can recover from.
    public var isTwitchAPICompatibilityIssue: Bool {
        if case .twitchAPICompatibility = self { return true }
        return false
    }
}
