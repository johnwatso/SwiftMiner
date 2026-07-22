// Debug-state presentation helpers for exercising miner card UI. Split
// from MinerManager.swift; same class, same @MainActor isolation.
import Foundation

#if DEBUG
extension MinerManager {
    public enum DebugState: String, CaseIterable, Sendable {
        case idle = "Idle"
        case recovering = "Recovering"
        case stalled = "Stalled"
        case quiet = "No Recent Activity"
        case blockedNotLinked = "Blocked — Account Not Linked"
        case authExpired = "Blocked — Auth Expired"
    }

    /// Sets a miner's state to a specific debug configuration to test UI card presentations.
    public func setDebugState(for minerId: String, state: DebugState) {
        guard let index = miners.firstIndex(where: { $0.id == minerId }) else { return }
        var miner = miners[index]
        
        switch state {
        case .recovering:
            miner.workerState = .recovering
            miner.isStalled = false
            miner.isRunning = true
            miner.isHealthy = true
            miner.needsAuth = false
            miner.status = .authenticating
            
        case .stalled:
            miner.workerState = .idle
            miner.isStalled = true
            miner.isRunning = true
            miner.isHealthy = true
            miner.needsAuth = false
            miner.status = .error
            
        case .quiet:
            miner.workerState = .idle
            miner.isStalled = false
            miner.isRunning = true
            miner.isHealthy = false
            miner.needsAuth = false
            miner.status = .watching
            
        case .blockedNotLinked:
            miner.workerState = .idle
            miner.isStalled = false
            miner.isRunning = true
            miner.isHealthy = true
            miner.needsAuth = false
            miner.status = .blockedAccountNotLinked
            
        case .authExpired:
            miner.workerState = .idle
            miner.isStalled = false
            miner.isRunning = true
            miner.isHealthy = true
            miner.needsAuth = true
            miner.status = .error
            
        case .idle:
            miner.workerState = .idle
            miner.isStalled = false
            miner.isHealthy = true
            miner.needsAuth = false
            miner.isRunning = false
            miner.status = .idle
        }
        
        miners[index] = miner
        onMinersChanged?()
        onMinerStatusChange?(miner)
    }

    /// Cycles a miner's state through different configurations to test UI card presentations.
    public func cycleDebugState(for minerId: String) {
        guard let index = miners.firstIndex(where: { $0.id == minerId }) else { return }
        var miner = miners[index]
        let currentStatus = miner.status
        
        switch currentStatus {
        case .idle:
            // State 1: Recovering
            miner.workerState = .recovering
            miner.isStalled = false
            miner.isRunning = true
            miner.isHealthy = true
            miner.needsAuth = false
            miner.status = .authenticating

        case .authenticating:
            // State 2: Unresponsive/Stalled
            miner.workerState = .idle
            miner.isStalled = true
            miner.isRunning = true
            miner.isHealthy = true
            miner.needsAuth = false
            miner.status = .error

        case .error where miner.isStalled:
            // State 3: No Recent Activity (Liveness Quiet)
            miner.workerState = .idle
            miner.isStalled = false
            miner.isRunning = true
            miner.isHealthy = false
            miner.needsAuth = false
            miner.status = .watching

        case .watching where !miner.isHealthy:
            // State 4: Blocked — Account Not Linked
            miner.workerState = .idle
            miner.isStalled = false
            miner.isRunning = true
            miner.isHealthy = true
            miner.needsAuth = false
            miner.status = .blockedAccountNotLinked

        case .blockedAccountNotLinked:
            // State 5: Blocked — Authentication Expired
            miner.workerState = .idle
            miner.isStalled = false
            miner.isRunning = true
            miner.isHealthy = true
            miner.needsAuth = true
            miner.status = .error

        default:
            // Reset back to normal Idle
            miner.workerState = .idle
            miner.isStalled = false
            miner.isHealthy = true
            miner.needsAuth = false
            miner.isRunning = false
            miner.status = .idle
        }
        
        miners[index] = miner
        onMinersChanged?()
        onMinerStatusChange?(miner)
    }

    /// Reverts a miner's mocked state back to real live data from the engine and supervisor.
    public func revertToLiveData(for minerId: String) async {
        guard let engine = engines[minerId],
              let miner = getMiner(id: minerId) else { return }
        
        let session = await engine.currentSession
        let isRunning = await engine.isActive
        let sessionStatus = session?.status ?? .idle
        let minerStatus = self.mapSessionStatus(sessionStatus)
        let allCampaigns = await engine.allCampaigns
        let currentId = await engine.currentCampaignId
        
        // Restore operational metadata (isHealthy, isStalled, workerState, etc.)
        await applySupervisorSnapshot(for: minerId)
        
        let clearsNeedsAuth = minerStatus != .authenticating && minerStatus != .error
        let needsAuth = clearsNeedsAuth ? false : miner.needsAuth
        
        updateMinerStatus(
            minerId: minerId,
            status: minerStatus,
            currentCampaignId: .some(currentId),
            allCampaigns: allCampaigns,
            isRunning: isRunning,
            needsAuth: needsAuth
        )
        
        await dataCoordinator.updateAccountNeedsAuth(accountId: miner.accountId, needsAuth: needsAuth)
    }

    /// Reverts all miners back to live data.
    public func revertAllToLiveData() async {
        for miner in miners {
            await revertToLiveData(for: miner.id)
        }
    }
}
#endif
