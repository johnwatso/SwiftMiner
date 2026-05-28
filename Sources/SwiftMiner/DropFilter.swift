import Foundation

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
        case .needsSetup: return "link.badge.plus"
        case .upcoming: return "calendar.badge.clock"
        case .completed: return "checkmark.circle.fill"
        case .ended: return "clock"
        }
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
        case .accountLink: return "link.badge.plus"
        case .scan: return "barcode.viewfinder"
        case .discord: return "checkmark.message.fill"
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
        case .system:
            return "App startup, setup, and other general messages."
        }
    }
}
