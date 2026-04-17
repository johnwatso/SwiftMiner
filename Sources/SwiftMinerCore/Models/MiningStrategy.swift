import Foundation

/// Mining strategy for campaign selection
public enum MiningStrategy: String, CaseIterable, Identifiable, Sendable {
    case mineAll = "mineAll"
    case prioritiseSelected = "prioritiseSelected"
    case onlyPriority = "onlyPriority"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .mineAll: return "Smart"
        case .prioritiseSelected: return "Prefer prioritised games"
        case .onlyPriority: return "Only prioritised games"
        }
    }
}
