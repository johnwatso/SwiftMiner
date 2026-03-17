import Foundation
import SwiftUI
import SwiftTwitchMiner

/// Central view-model that bridges mining state to SwiftUI's `@MainActor`.
///
/// When a `MinerManager` is provided (multi-miner mode), all mining operations
/// are delegated to it. `AppModel` only owns the engine used for the initial
/// device-code auth flow in that case.
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

    public var activeMiners: Int {
        if let manager = minerManager {
            return manager.miners.filter { $0.isRunning }.count
        }
        return isAuthenticated && sessionStatus != .stopped && sessionStatus != .idle ? 1 : 0
    }

    public var totalMiners: Int {
        if let manager = minerManager {
            return manager.miners.count
        }
        return isAuthenticated ? 1 : 0
    }

    public var dropsClaimedToday: Int {
        if let manager = minerManager {
            return manager.miners.reduce(0) { $0 + $1.dropsClaimed }
        }
        return overallProgress?.claimedDrops ?? 0
    }

    public var overallStatus: SessionStatus {
        sessionStatus
    }

    private let maxLogEntries = 500

    // MARK: - Engine (used only for device-code auth flow)

    private let engine: MinerEngine
    private let clientId: String
    private weak var minerManager: MinerManager?

    // MARK: - Init

    public init(clientId: String, minerManager: MinerManager? = nil) {
        self.clientId = clientId
        self.engine = MinerEngine(clientId: clientId)
        self.minerManager = minerManager
    }

    // MARK: - Lifecycle

    public func setup() async {
        if let manager = minerManager {
            // Multi-miner mode: don't start our own engine.
            // Drive isAuthenticated from MinerManager's miner list.
            isAuthenticated = !manager.miners.isEmpty

            // Update isAuthenticated whenever a miner is added/removed.
            manager.onMinerStatusChange = { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isAuthenticated = !(self.minerManager?.miners.isEmpty ?? true)
                }
            }
            return
        }

        // Legacy single-engine mode (no MinerManager).
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

        do {
            try await engine.start()
            isAuthenticated = true
        } catch {
            isAuthenticated = false
        }
    }

    public func stop() async {
        if let manager = minerManager {
            await manager.stopAll()
            return
        }
        await engine.stop()
    }

    public func startAll() async {
        if let manager = minerManager {
            await manager.startAll()
            return
        }
        try? await engine.start()
        isAuthenticated = await engine.isActive
    }

    public func stopAll() async {
        if let manager = minerManager {
            await manager.stopAll()
            return
        }
        await engine.stop()
        isAuthenticated = false
    }

    public func logout() async {
        if let manager = minerManager {
            for miner in manager.miners {
                await manager.removeAccount(minerId: miner.id)
            }
            isAuthenticated = false
            authInfo = nil
            return
        }
        await engine.stop()
        let authService = TwitchAuthService(clientId: clientId)
        try? await authService.logout()
        isAuthenticated = false
        authInfo = nil
    }

    // MARK: - Authentication (always uses own engine for device-code flow)

    public func startAuthentication() async throws {
        authInfo = try await engine.authenticate()
    }

    public func waitForAuthentication() async {
        // In multi-miner mode, AuthRequiredSheet handles adding the account to MinerManager.
        // We just wait until at least one miner appears.
        if let manager = minerManager {
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if !manager.miners.isEmpty {
                    isAuthenticated = true
                    authInfo = nil
                    return
                }
            }
            return
        }

        // Legacy single-engine mode.
        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if await engine.isActive {
                isAuthenticated = true
                authInfo = nil
                return
            }
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
        if let manager = minerManager {
            await manager.claimAllDropsAllMiners()
            return
        }
        do {
            try await engine.claimAllDrops()
        } catch {
            lastError = error as? TwitchMinerError ?? .unknown(error.localizedDescription)
        }
    }

    public func refreshProgress() async {
        if let manager = minerManager {
            let agg = await manager.getAggregateProgress()
            overallProgress = OverallProgress(
                totalCampaigns: agg.totalCampaigns,
                activeCampaigns: agg.activeMiners,
                totalDrops: agg.totalDrops,
                claimedDrops: agg.claimedDrops,
                pendingDrops: agg.pendingDrops,
                totalWatchTimeMinutes: 0,
                campaigns: []
            )
            return
        }
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
