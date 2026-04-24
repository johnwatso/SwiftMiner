import Foundation

// MARK: - Connection State

public enum SwiftBotConnectionState: String, Codable, Equatable, Sendable {
    case connected
    case notConfigured = "not_configured"
    case disconnected
}

// MARK: - Protocol

public protocol SwiftBotConnectionService: Sendable {
    /// Update the configured endpoint and re-check connectivity.
    func updateEndpoint(_ urlString: String) async

    /// Trigger a manual health check and return the result.
    func checkHealth() async -> SwiftBotConnectionState
}
