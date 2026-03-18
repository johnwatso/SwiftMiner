import Foundation

/// Mining strategy for campaign selection
public enum MiningStrategy: String, CaseIterable, Identifiable, Sendable {
    case mineAll = "mineAll"
    case prioritiseSelected = "prioritiseSelected"
    case onlyPriority = "onlyPriority"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .mineAll: return "Mine all eligible drops"
        case .prioritiseSelected: return "Prioritise selected games"
        case .onlyPriority: return "Only mine priority games"
        }
    }
}
