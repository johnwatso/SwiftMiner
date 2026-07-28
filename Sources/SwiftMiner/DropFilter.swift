import Foundation
import SwiftMinerCore

/// Filter options for the Drops list view.
public enum DropFilter: String, CaseIterable, Identifiable, Hashable, Codable {
    case active
    case needsSetup
    case upcoming
    case completed
    case ended

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .active: return "Active"
        case .needsSetup: return "Needs Setup"
        case .upcoming: return "Upcoming"
        case .completed: return "Completed"
        case .ended: return "Ended"
        }
    }

    public var symbol: String {
        switch self {
        case .active: return "dot.radiowaves.left.and.right"
        case .needsSetup: return "personalhotspot.slash"
        case .upcoming: return "calendar.badge.clock"
        case .completed: return "checkmark.circle.fill"
        case .ended: return "clock"
        }
    }
}

/// Drops-filter rules that must remain independent of the miner scheduler.
/// An unlinked campaign remains actionable in Drops because linking the game
/// account is a setup task, even when an explicit priority lets mining proceed.
enum DropsCampaignFilterRules {
    static func matchesNeedsSetup(_ campaign: CampaignViewData, now: Date) -> Bool {
        guard campaign.startDate <= now,
              !campaign.isExpired(now: now),
              campaign.endDate > now,
              !campaign.isCompleted,
              campaign.hasObtainableRewards
        else {
            return false
        }

        return campaign.accountStates.contains {
            $0.miningStatus == .needsAuth || $0.miningStatus == .blocked
        }
    }

    /// Public unlinked campaigns are intentionally `.irrelevant` to the normal
    /// curated feed. Preserve them when Needs Setup is selected so the filter
    /// can surface the account-link work it exists to show.
    static func preservesCampaignOutsideCuratedFeed(
        _ campaign: CampaignViewData,
        selectedFilters: Set<DropFilter>,
        now: Date
    ) -> Bool {
        selectedFilters.contains(.needsSetup) && matchesNeedsSetup(campaign, now: now)
    }
}

/// Filter options for the Activity Log view.
public enum EventFilter: String, CaseIterable, Identifiable, Hashable, Codable {
    case mining
    case heartbeats
    case drops
    case warnings
    case errors
    case accountLink
    case scan
    case discord
    case audit
    case updates
    case system

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .mining: return "Mining"
        case .heartbeats: return "Heartbeats"
        case .drops: return "Drops"
        case .warnings: return "Warnings"
        case .errors: return "Errors"
        case .accountLink: return "Linking"
        case .scan: return "Scan"
        case .discord: return "Discord"
        case .audit: return "Audit"
        case .updates: return "Updates"
        case .system: return "System"
        }
    }

    public var symbol: String {
        switch self {
        case .mining: return "play.circle"
        case .heartbeats: return "heart.fill"
        case .drops: return "shippingbox"
        case .warnings: return "exclamationmark.triangle"
        case .errors: return "xmark.octagon"
        case .accountLink: return "personalhotspot.slash"
        case .scan: return "barcode.viewfinder"
        case .discord: return "checkmark.message.fill"
        case .audit: return "person.text.rectangle"
        case .updates: return "arrow.down.circle"
        case .system: return "gearshape"
        }
    }

    public var description: String {
        switch self {
        case .mining:
            return "Streams the miner is trying, watching, or switching between."
        case .heartbeats:
            return "Background watch signals that keep Twitch counting progress."
        case .drops:
            return "Progress updates, ready-to-claim rewards, and claims."
        case .warnings:
            return "Things to notice, but the miner kept running."
        case .errors:
            return "Problems that stopped something from working."
        case .accountLink:
            return "Games that need account linking before drops can count."
        case .scan:
            return "Campaign checks and why some campaigns were skipped."
        case .discord:
            return "DMs sent to linked Discord users for setup, drops, and recovery."
        case .audit:
            return "Web dashboard activity: sign-ins and priority changes made by users."
        case .updates:
            return "App update checks, downloads, and automatic installs."
        case .system:
            return "App startup, setup, and other general messages."
        }
    }
}
