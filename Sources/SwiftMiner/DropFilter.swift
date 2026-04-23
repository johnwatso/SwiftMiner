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
