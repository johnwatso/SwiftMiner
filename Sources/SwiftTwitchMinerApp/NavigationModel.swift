import SwiftUI
import SwiftTwitchMiner

/// Navigation model for the multi-miner dashboard
/// Manages sidebar selection and view routing
@MainActor
@Observable
public final class NavigationModel {
    
    // MARK: - Navigation State
    
    public enum SidebarItem: Hashable, Identifiable {
        case activity
        case accounts
        case account(id: String)
        case campaigns
        case campaign(id: String)
        case logs
        case settings
        
        public var id: String {
            switch self {
            case .activity: return "activity"
            case .accounts: return "accounts"
            case .account(let id): return "account.\(id)"
            case .campaigns: return "campaigns"
            case .campaign(let id): return "campaign.\(id)"
            case .logs: return "logs"
            case .settings: return "settings"
            }
        }
        
        public var displayName: String {
            switch self {
            case .activity: return "Activity"
            case .accounts: return "Accounts"
            case .account: return "Account"
            case .campaigns: return "Campaigns"
            case .campaign: return "Campaign"
            case .logs: return "Logs"
            case .settings: return "Settings"
            }
        }
    }
    
    public var selectedItem: SidebarItem? = .activity
    public var columnVisibility: NavigationSplitViewVisibility = .automatic

    // MARK: - Sheet State

    /// Present the Add Account sheet from any view by setting this to true.
    public var showAddAccountSheet = false

    // MARK: - Content State

    public var selectedMinerId: String?
    public var selectedCampaignId: String?

    // MARK: - Per-Miner Logs

    /// Live log entries keyed by miner ID.
    public var minerLogs: [String: [LogEntry]] = [:]
    private let maxLogsPerMiner = 300

    // MARK: - Miner Manager

    public let minerManager: MinerManager

    // MARK: - Initialization

    public init(clientId: String) {
        self.minerManager = MinerManager(clientId: clientId)
    }

    // MARK: - Setup

    /// Wire MinerManager callbacks and run initial setup.
    /// Call this once (from ContentView's `.task`).
    public func setup() {
        minerManager.onLogMessage = { [weak self] minerId, message in
            Task { @MainActor [weak self] in
                guard let self else { return }
                var logs = self.minerLogs[minerId, default: []]
                logs.append(LogEntry(message: message, level: .debug))
                if logs.count > self.maxLogsPerMiner {
                    logs.removeFirst(logs.count - self.maxLogsPerMiner)
                }
                self.minerLogs[minerId] = logs
            }
        }
        Task {
            await minerManager.setup()
        }
    }

    /// Clear the log buffer for a specific miner.
    public func clearLogs(forMiner minerId: String) {
        minerLogs.removeValue(forKey: minerId)
    }
    
    // MARK: - Navigation Helpers
    
    public func selectAccount(_ accountId: String) {
        selectedItem = .account(id: accountId)
        selectedMinerId = accountId
    }
    
    public func selectCampaign(_ campaignId: String) {
        selectedItem = .campaign(id: campaignId)
        selectedCampaignId = campaignId
    }
    
    public func showActivity() {
        selectedItem = .activity
    }
}
