import Foundation

// Read-only projections the UI asks the engine for. Nothing here changes mining state.
//
// Split out of MinerEngine.swift, which had grown past the point where one file could be read.
// The stall-tracking storage these read stays in the actor body — an extension cannot declare
// stored properties.

extension MinerEngine {
    // MARK: - UI Helper APIs
    
    /// Get current stall state for UI display.
    public func getStallState() async -> StallState {
        let elapsed = progressStallElapsedSeconds()
        let minutes = Int(elapsed / 60)
        // An active override intentionally stays put, so a lack of drop progress is not a stall.
        let isStalled = streamOverrideLogin == nil && minutes >= Self.maxExtraMinutes
        
        // Determine recovery action based on current state
        let recoveryAction: MinerManager.StallRecoveryAction?
        if isStalled && shouldSwitchChannel {
            recoveryAction = .switchingChannel
        } else if isStalled {
            recoveryAction = .refreshingInventory
        } else {
            recoveryAction = nil
        }
        
        return StallState(
            minutesSinceLastProgress: minutes,
            isStalled: isStalled,
            recoveryAction: recoveryAction,
            lastSwitchReason: lastSwitchReason,
            lastSwitchAt: lastSwitchAt,
            currentChannelName: currentChannelName,
            currentChannelId: currentChannelId
        )
    }
    
    /// Get recent activity events for UI display (last N events), newest first.
    public func getRecentActivityEvents(limit: Int) async -> [MinerManager.MinerEvent] {
        guard limit > 0 else { return [] }
        return Array(recentActivityEvents.suffix(limit).reversed())
    }

    /// Append a structured event to the diagnostics timeline.
    func recordActivityEvent(
        _ type: MinerManager.MinerEvent.EventType,
        _ summary: String,
        at date: Date = Date()
    ) {
        recentActivityEvents.append(
            MinerManager.MinerEvent(timestamp: date, type: type, summary: summary)
        )
        if recentActivityEvents.count > Self.maxRecentActivityEvents {
            recentActivityEvents.removeFirst(recentActivityEvents.count - Self.maxRecentActivityEvents)
        }
    }
}
