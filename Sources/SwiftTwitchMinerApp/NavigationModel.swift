import SwiftUI
import SwiftTwitchMiner

/// Navigation model for the multi-miner dashboard
/// Manages sidebar selection and view routing
@MainActor
@Observable
public final class NavigationModel {
    
    // MARK: - Navigation State
    
    public enum SidebarItem: Hashable, Identifiable {
        case overview
        case activity
        case drops
        case events
        
        public var id: String {
            switch self {
            case .overview: return "overview"
            case .activity: return "activity"
            case .drops: return "drops"
            case .events: return "events"
            }
        }
        
        public var displayName: String {
            switch self {
            case .overview: return "Overview"
            case .activity: return "Activity"
            case .drops: return "Drops"
            case .events: return "Events"
            }
        }
    }
    
    public var selectedItem: SidebarItem? = .overview
    public var columnVisibility: NavigationSplitViewVisibility = .automatic

    // MARK: - Sheet State

    /// Present the Add Account sheet from any view by setting this to true.
    public var showAddAccountSheet = false

    // MARK: - Content State

    public var selectedMinerId: String?
    public var selectedCampaignId: String?

    // MARK: - Events

    /// Human-readable event entries.
    public var events: [EventEntry] = []
    private let maxEvents = 1000

    // MARK: - Drop Completion Tracking

    /// Timestamps of when a drop was first seen as claimed/completed.
    /// Key: dropId, Value: completion Date.
    public var completedDropTimestamps: [String: Date] = [:]

    // MARK: - Miner Manager

    public let minerManager: MinerManager

    // MARK: - Initialization

    public init(clientId: String, minerManager: MinerManager? = nil) {
        self.minerManager = minerManager ?? MinerManager(clientId: clientId)
    }

    // MARK: - Setup

    /// Wire MinerManager callbacks and run initial setup.
    /// Call this once (from ContentView's `.task`).
    public func setup() {
        minerManager.onLogMessage = { [weak self] minerId, message in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.processLogMessage(minerId: minerId, message: message)
            }
        }
        Task {
            await minerManager.setup()
        }
    }

    private func processLogMessage(minerId: String, message: String) {
        let level: EventLevel = message.contains("⚠️") ? .warning : (message.contains("❌") || message.contains("Error")) ? .error : .info
        
        // Transform common logs into readable events
        var displayMessage = message
        if message.contains("[Engine] Started watching") {
            displayMessage = "Started watching campaign"
        } else if message.contains("CLAIMED") {
            displayMessage = "Drop claimed successfully"
        }
        
        logEvent(message: displayMessage, level: level, minerId: minerId, rawMessage: message)
    }

    public func logEvent(message: String, level: EventLevel = .info, minerId: String? = nil, rawMessage: String? = nil) {
        let entry = EventEntry(message: message, level: level, minerId: minerId, rawMessage: rawMessage)
        events.insert(entry, at: 0)
        if events.count > maxEvents {
            events.removeLast()
        }
    }

    /// Clear all events.
    public func clearEvents() {
        events.removeAll()
    }
}

// MARK: - Supporting Models

public enum EventLevel: String, Codable, Sendable {
    case info
    case warning
    case error
}

public struct EventEntry: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let timestamp = Date()
    public let message: String
    public let level: EventLevel
    public let minerId: String?
    public let rawMessage: String?
}
