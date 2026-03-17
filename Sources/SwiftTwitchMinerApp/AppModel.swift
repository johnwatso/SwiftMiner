import Foundation
import SwiftUI
import SwiftTwitchMiner

/// Central view-model that bridges the `MinerEngine` actor to SwiftUI's `@MainActor`.
///
/// All mutations happen on the main actor so SwiftUI's observation infrastructure
/// picks them up without additional `DispatchQueue.main.async` calls.
@MainActor
@Observable
public final class AppModel {

    // MARK: - Published state

    public var campaigns: [Campaign] = []
    public var overallProgress: OverallProgress?
    public var sessionStatus: SessionStatus = .idle
    public var lastError: TwitchMinerError?
    public var logMessages: [LogEntry] = []
    public var authInfo: DeviceAuthInfo?
    public var isAuthenticated = false
    
    // MARK: - Multi-miner compatibility properties

    /// Number of active miners (0 or 1 for single-engine mode)
    public var activeMiners: Int {
        isAuthenticated && sessionStatus != .stopped && sessionStatus != .idle ? 1 : 0
    }

    /// Total number of miners (always 1 for single-engine mode)
    public var totalMiners: Int {
        isAuthenticated ? 1 : 0
    }

    /// Drops claimed today (from overall progress)
    public var dropsClaimedToday: Int {
        overallProgress?.claimedDrops ?? 0
    }

    /// Overall status for menu bar
    public var overallStatus: SessionStatus {
        sessionStatus
    }

    /// Maximum log entries kept in memory
    private let maxLogEntries = 500

    // MARK: - Engine

    private let engine: MinerEngine
    private let clientId: String

    // MARK: - Init

    public init(clientId: String) {
        self.clientId = clientId
        self.engine = MinerEngine(clientId: clientId)
    }

    // MARK: - Lifecycle

    /// Wire up callbacks and (if already authenticated) start mining.
    public func setup() async {
        // Update mining preferences from Settings
        await engine.updateMiningPreferences(
            priorityGames: Settings.shared.priorityGames,
            excludedGames: Settings.shared.excludedGames
        )
        
        await engine.setStatusChangeHandler { [weak self] status in
            Task { @MainActor [weak self] in
                self?.sessionStatus = status
            }
        }

        await engine.setCampaignUpdateHandler { [weak self] campaigns in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.campaigns = await self.engine.allCampaigns
            }
        }

        await engine.setProgressUpdateHandler { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.overallProgress = progress
            }
        }

        await engine.setDropClaimedHandler { [weak self] drop in
            Task { @MainActor [weak self] in
                self?.appendLog("✅ Claimed drop: \(drop.name)", level: .info)
            }
        }

        await engine.setErrorHandler { [weak self] error in
            Task { @MainActor [weak self] in
                self?.lastError = error
                self?.appendLog("❌ \(error.localizedDescription)", level: .error)
            }
        }

        await engine.setLogMessageHandler { [weak self] message in
            Task { @MainActor [weak self] in
                self?.appendLog(message, level: .debug)
            }
        }

        // Try to start if credentials are already saved
        do {
            try await engine.start()
            isAuthenticated = true
        } catch {
            // Not authenticated yet — show auth flow
            isAuthenticated = false
        }
    }

    public func stop() async {
        await engine.stop()
    }
    
    /// Start all miners (backward compatible - starts single engine)
    public func startAll() async {
        try? await engine.start()
        isAuthenticated = await engine.isActive
    }
    
    /// Stop all miners (backward compatible - stops single engine)
    public func stopAll() async {
        await engine.stop()
        isAuthenticated = false
    }
    
    /// Logout and clear credentials
    public func logout() async {
        await engine.stop()
        let authService = TwitchAuthService(clientId: clientId)
        try? await authService.logout()
        isAuthenticated = false
        authInfo = nil
    }

    // MARK: - Authentication

    /// Begin device-code OAuth flow. Returns info needed to display to the user.
    public func startAuthentication() async throws {
        authInfo = try await engine.authenticate()
    }

    /// Poll until authentication completes (called after user enters the code).
    public func waitForAuthentication() async {
        // Give the background polling task time to finish, then re-try start.
        // MinerEngine's authenticate() already fires a background Task that polls.
        // We just need to detect when isAuthenticated flips.
        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
            if await engine.isActive {
                isAuthenticated = true
                authInfo = nil
                return
            }
            // Try starting to trigger the token check
            do {
                try await engine.start()
                isAuthenticated = true
                authInfo = nil
                return
            } catch {
                // Still waiting
            }
        }
    }

    // MARK: - Actions

    public func claimAllDrops() async {
        do {
            try await engine.claimAllDrops()
        } catch {
            lastError = error as? TwitchMinerError ?? .unknown(error.localizedDescription)
        }
    }

    public func refreshProgress() async {
        do {
            overallProgress = try await engine.getCurrentProgress()
        } catch {
            lastError = error as? TwitchMinerError ?? .unknown(error.localizedDescription)
        }
    }

    // MARK: - Logging

    private func appendLog(_ message: String, level: LogEntry.Level) {
        let entry = LogEntry(message: message, level: level)
        logMessages.append(entry)
        if logMessages.count > maxLogEntries {
            logMessages.removeFirst(logMessages.count - maxLogEntries)
        }
    }
}

// MARK: - Supporting types

public struct LogEntry: Identifiable, Sendable {
    public enum Level: Sendable { case debug, info, warning, error }
    public let id = UUID()
    public let message: String
    public let level: Level
    public let timestamp = Date()
}
