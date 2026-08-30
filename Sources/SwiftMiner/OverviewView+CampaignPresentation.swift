import SwiftUI
import SwiftMinerCore
import AppKit

/// How a campaign presents itself in the Overview feed: visual state, watchers,
/// progress text, and tint.
extension OverviewView {
    func visualState(
        for campaign: CampaignViewData,
        watched: WatchedCampaignIndex
    ) -> CampaignVisualState {
        if campaign.isCompleted {
            return .claimed
        }

        if campaign.overviewState == .claimable {
            return .claimable
        }

        if campaign.hasValidProgress {
            return watched.isWatched(campaign) ? .watching : .inProgress
        }

        return .idle
    }

    func watchers(for campaign: CampaignViewData) -> [CampaignWatcher] {
        return watchingMiners(for: campaign).map { miner in
            CampaignWatcher(
                id: miner.accountId,
                username: miner.username,
                initials: initials(for: miner.username)
            )
        }
    }

    private func watchingMiners(for campaign: CampaignViewData) -> [MinerManager.ManagedMiner] {
        navigation.minerManager.miners.filter { miner in
            // Must be actively running with watching/claiming status
            guard miner.status == .watching || miner.status == .claiming else {
                return false
            }

            // Verify currentCampaignId matches (defense against stale session state)
            if let id = miner.currentCampaignId {
                return id == campaign.id
            }

            return miner.currentCampaign == campaign.campaignName
        }
    }

    private func isBeingWatched(_ campaign: CampaignViewData) -> Bool {
        !watchingMiners(for: campaign).isEmpty
    }

    func campaignDetailText(
        for campaign: CampaignViewData,
        state: CampaignVisualState
    ) -> String {
        let activeWatchers = watchers(for: campaign)
        let progressPercent = Int(campaignProgressPercent(for: campaign).rounded())

        switch state {
        case .watching:
            let watcherCount = activeWatchers.count
            let watcherCopy = "\(watcherCount) miner\(watcherCount == 1 ? "" : "s") watching"
            if progressPercent > 0 {
                return "\(watcherCopy) • \(progressPercent)% reward progress"
            }
            return watcherCopy
        case .claimable:
            return "Ready to claim"
        case .inProgress:
            return progressPercent > 0 ? "\(progressPercent)% reward progress" : "Progress synced from Drops"
        case .claimed:
            return "All campaign rewards claimed"
        case .idle:
            return "Available"
        }
    }

    func displayPriority(
        for campaign: CampaignViewData,
        watched: WatchedCampaignIndex
    ) -> Int {
        switch visualState(for: campaign, watched: watched) {
        case .watching: return 0
        case .claimable: return 1
        case .inProgress: return 2
        case .idle: return 3
        case .claimed: return 4
        }
    }


    private func initials(for username: String) -> String {
        let tokens = username
            .split(whereSeparator: { $0 == " " || $0 == "_" || $0 == "-" })
            .prefix(2)

        let joined = tokens.map { String($0.prefix(1)).uppercased() }.joined()
        if !joined.isEmpty {
            return joined
        }

        return String(username.prefix(2)).uppercased()
    }




    func campaignProgressPercent(for campaign: CampaignViewData) -> Double {
        let progressPercent = (campaign.overviewProgressFraction ?? 0) * 100
#if DEBUG
        if progressPercent > 0, !campaign.hasValidProgress {
            Logger.campaigns.error("Attempted to render progress for \(campaign.id) without Drops progress")
        }
#endif
        return progressPercent
    }

    private func fallbackSubtitle(for miner: MinerManager.ManagedMiner) -> String {
        if !miner.isRunning {
            switch miner.status {
            case .authenticating:
                return "Starting..."
            case .paused:
                return "Paused"
            case .error:
                return "Blocked — Needs attention"
            case .idle,
                 .fetchingCampaigns,
                 .watching,
                 .claiming,
                 .waitingForStream,
                 .idleNoEligibleCampaigns,
                 .blockedAccountNotLinked:
                return "Stopped"
            }
        }
        switch miner.status {
        case .idle:
            return "Up to Date"
        case .authenticating:
            return "Reconnecting"
        case .fetchingCampaigns:
            return "Updating…"
        case .watching:
            return "Watching — \(miner.currentCampaign ?? "active campaign")"
        case .waitingForStream:
            return "Looking for Streams"
        case .claiming:
            return "Claiming Rewards"
        case .paused:
            return "Paused — Mining is paused"
        case .idleNoEligibleCampaigns:
            return "Up to Date"
        case .blockedAccountNotLinked:
            return "Blocked — Account not linked"
        case .error:
            return "Blocked — Needs attention"
        }
    }

    func tintColor(for campaign: CampaignViewData) -> Color {
        return gameTintColor(forGameName: campaign.gameName)
    }
}
