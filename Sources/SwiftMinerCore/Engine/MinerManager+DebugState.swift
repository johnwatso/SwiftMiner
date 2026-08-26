// Debug-state presentation helpers for exercising miner card UI. Split
// from MinerManager.swift; same class, same @MainActor isolation.
import Foundation

#if DEBUG
extension MinerManager {
    private static let debugFakeMiningCampaignID = "swiftminer-debug-fake-mining-campaign"

    public enum DebugState: String, CaseIterable, Sendable {
        case fakeMiningCampaign = "Mining — Fake Campaign"
        case idle = "Idle"
        case recovering = "Recovering"
        case stalled = "Stalled"
        case quiet = "No Recent Activity"
        case blockedNotLinked = "Blocked — Account Not Linked"
        case accountLinkReminder = "Link Halo to Twitch"
        case subscriptionRequired = "Twitch Subscription Required"
        case authExpired = "Blocked — Auth Expired"
    }

    /// Sets a miner's state to a specific debug configuration to test UI card presentations.
    public func setDebugState(for minerId: String, state: DebugState) {
        guard let index = miners.firstIndex(where: { $0.id == minerId }) else { return }
        var miner = miners[index]
        miner.debugAttention = nil
        let wasShowingFakeCampaign = miner.currentCampaignId == Self.debugFakeMiningCampaignID
        miner.allCampaigns.removeAll { $0.id == Self.debugFakeMiningCampaignID }
        if wasShowingFakeCampaign {
            miner.currentCampaign = nil
            miner.currentCampaignId = nil
        }
        
        switch state {
        case .fakeMiningCampaign:
            let now = Date()
            let campaign = Self.makeDebugFakeMiningCampaign(now: now)
            miner.allCampaigns.insert(campaign, at: 0)
            miner.currentCampaign = campaign.name
            miner.currentCampaignId = campaign.id
            miner.streamOverrideLogin = nil
            miner.workerState = .running
            miner.isStalled = false
            miner.isRunning = true
            miner.isHealthy = true
            miner.needsAuth = false
            miner.status = .watching
            miner.lastEventAt = now
            miner.lastSuccessfulPollAt = now
            miner.lastCampaignRefreshAt = now
            miner.lastDropProgressAt = now
            miner.workerStartedAt = now.addingTimeInterval(-15 * 60)

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

        case .accountLinkReminder:
            miner.workerState = .idle
            miner.isStalled = false
            miner.isRunning = true
            miner.isHealthy = true
            miner.needsAuth = false
            miner.status = .idle
            miner.debugAttention = .accountLink(gameName: "Halo")

        case .subscriptionRequired:
            miner.workerState = .idle
            miner.isStalled = false
            miner.isRunning = true
            miner.isHealthy = true
            miner.needsAuth = false
            miner.status = .idle
            miner.debugAttention = .subscriptionRequired
            
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

        if miner.currentCampaignId == Self.debugFakeMiningCampaignID {
            setDebugState(for: minerId, state: .idle)
            return
        }

        if let attention = miner.debugAttention {
            switch attention {
            case .accountLink:
                setDebugState(for: minerId, state: .subscriptionRequired)
            case .subscriptionRequired:
                setDebugState(for: minerId, state: .authExpired)
            }
            return
        }

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
            // State 5: campaign-specific account link reminder
            setDebugState(for: minerId, state: .accountLinkReminder)
            return

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

    private static func makeDebugFakeMiningCampaign(now: Date) -> Campaign {
        let dropID = "swiftminer-debug-fake-mining-drop"
        let progress = Progress(
            id: "swiftminer-debug-fake-mining-progress",
            dropId: dropID,
            dropName: "Developer Preview Drop",
            campaignId: debugFakeMiningCampaignID,
            currentMinutes: 24,
            requiredMinutes: 60,
            lastUpdated: now
        )
        let reward = Reward(
            id: "swiftminer-debug-fake-mining-reward",
            type: .inGame,
            name: "Developer Preview Reward",
            description: "Synthetic reward data shown only by the Developer menu."
        )
        let drop = Drop(
            id: dropID,
            name: "Developer Preview Drop",
            description: "Synthetic progress for checking the active mining UI.",
            requiredMinutes: 60,
            benefitID: "swiftminer-debug-fake-benefit",
            reward: reward,
            progress: progress,
            dropStartDate: now.addingTimeInterval(-60 * 60),
            dropEndDate: now.addingTimeInterval(7 * 24 * 60 * 60)
        )

        return Campaign(
            id: debugFakeMiningCampaignID,
            name: "Developer Preview Campaign",
            game: Game(id: "swiftminer-debug-sandbox", name: "SwiftMiner Sandbox"),
            startDate: now.addingTimeInterval(-60 * 60),
            endDate: now.addingTimeInterval(7 * 24 * 60 * 60),
            drops: [drop],
            isAccountConnected: true,
            isPrioritised: true
        )
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
