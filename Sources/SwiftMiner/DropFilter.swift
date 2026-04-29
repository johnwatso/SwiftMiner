import Foundation

/// Filter options for the Drops list view.
public enum DropFilter: String, CaseIterable, Identifiable, Hashable, Codable {
    case active
    case needsSetup
    case upcoming
    case completed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .active: return "Active"
        case .needsSetup: return "Needs Setup"
        case .upcoming: return "Upcoming"
        case .completed: return "Completed"
        }
    }

    public var symbol: String {
        switch self {
        case .active: return "dot.radiowaves.left.and.right"
        case .needsSetup: return "link.badge.plus"
        case .upcoming: return "calendar.badge.clock"
        case .completed: return "checkmark.circle.fill"
        }
    }
}

/// Filter options for the Events view.
public enum EventFilter: String, CaseIterable, Identifiable, Hashable, Codable {
    case mining
    case heartbeats
    case drops
    case warnings
    case errors
    case accountLink
    case scan
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
        case .scan: return "line.3.horizontal.decrease.circle"
        case .system: return "gearshape"
        }
    }
}
