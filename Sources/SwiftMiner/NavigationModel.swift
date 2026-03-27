import SwiftUI
import SwiftMinerCore

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

    public enum OnboardingAccountState: Equatable {
        case noAccounts
        case hasAccounts(count: Int)
    }

    public enum OnboardingSetupStage: String, CaseIterable {
        case connecting
        case campaigns
        case inventory
        case finalising

        public var title: String {
            switch self {
            case .connecting: return "Connecting your account..."
            case .campaigns: return "Fetching active campaigns..."
            case .inventory: return "Syncing your inventory..."
            case .finalising: return "Preparing your dashboard..."
            }
        }
    }

    public struct OnboardingPresentation: Equatable {
        public let title: String
        public let subtitle: String
        public let accountState: OnboardingAccountState
        public let showsGamePreferences: Bool
        public let showsPreferences: Bool
        public let setupStage: OnboardingSetupStage?
    }
    
    public var selectedItem: SidebarItem? = .overview
    public var columnVisibility: NavigationSplitViewVisibility = .automatic

    // MARK: - Onboarding State

    /// Whether the optional onboarding surface should be visible.
    public var showOnboarding = false
    public private(set) var onboardingPresentation: OnboardingPresentation?
    public var onboardingSetupStage: OnboardingSetupStage = .connecting
    public var isRunningOnboardingSetup = false

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
    private var onboardingSetupTask: Task<Void, Never>?
    private var lastKnownAccountCount = 0
    private var hasConfiguredOnboardingBaseline = false

    // MARK: - Initialization

    public init(clientId: String, minerManager: MinerManager? = nil) {
        self.minerManager = minerManager ?? MinerManager(clientId: clientId)
    }

    // MARK: - Setup

    /// Wire MinerManager callbacks and load saved accounts.
    /// Must be awaited before `AppModel.setup()` so `miners` is populated.
    public func setup() async {
        minerManager.onLogMessage = { [weak self] minerId, message in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.processLogMessage(minerId: minerId, message: message)
            }
        }
        let settings = Settings.shared
        minerManager.updateClientId(settings.resolvedClientId)
        await minerManager.setup(
            autoStart: settings.autoStartOnLaunch,
            priorityGames: settings.priorityGames,
            excludedGames: settings.excludedGames,
            strategy: settings.miningStrategy,
            enableBadgesEmotes: settings.enableBadgesEmotes,
            ignoredAccountLinkWarningAccountIds: settings.ignoredAccountLinkWarningAccountIds
        )
    }

    public func configureOnboardingPresentation() {
        lastKnownAccountCount = minerManager.miners.count
        hasConfiguredOnboardingBaseline = true
        refreshOnboardingPresentation()
    }

    public func refreshOnboardingPresentation() {
        onboardingPresentation = deriveOnboardingPresentation()
        showOnboarding = onboardingPresentation != nil
    }

    public func dismissOnboarding() {
        onboardingSetupTask?.cancel()
        onboardingSetupTask = nil
        isRunningOnboardingSetup = false
        settings.hasDismissedOnboarding = true
        refreshOnboardingPresentation()
    }

    public func updateOnboardingSetupStage(_ stage: OnboardingSetupStage) {
        onboardingSetupStage = stage
        refreshOnboardingPresentation()
    }

    public func handleOnboardingAuthenticationCompleted(resetDismissal: Bool = true) {
        guard !minerManager.miners.isEmpty else {
            refreshOnboardingPresentation()
            return
        }

        if resetDismissal {
            settings.hasDismissedOnboarding = false
        }
        startOnboardingSetupIfNeeded()
    }

    public func handleAccountCountChange() {
        let currentCount = minerManager.miners.count

        // Ignore account-load churn before the initial onboarding baseline is configured.
        // This prevents restoring multiple saved accounts from accidentally resetting
        // a previously dismissed onboarding flow.
        guard hasConfiguredOnboardingBaseline else {
            lastKnownAccountCount = currentCount
            return
        }

        let previousCount = lastKnownAccountCount
        guard currentCount != previousCount else {
            refreshOnboardingPresentation()
            return
        }

        lastKnownAccountCount = currentCount
        // Only reset dismissal when a new account is added mid-session (previousCount > 0).
        // During initial app launch, accounts load from keychain (0 → N) and should not
        // wipe a previously saved dismissal.
        if previousCount > 0 {
            settings.hasDismissedOnboarding = false
        }

        if currentCount > previousCount, showOnboarding || previousCount == 0 {
            handleOnboardingAuthenticationCompleted(resetDismissal: previousCount > 0)
        } else {
            refreshOnboardingPresentation()
        }
    }

    public func startOnboardingSetupIfNeeded() {
        guard !minerManager.miners.isEmpty else { return }
        guard onboardingSetupTask == nil else { return }

        isRunningOnboardingSetup = true
        updateOnboardingSetupStage(.connecting)

        onboardingSetupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runOnboardingSetupSequence()
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

    private var settings: Settings { Settings.shared }

    private func deriveOnboardingPresentation() -> OnboardingPresentation? {
        let accountCount = minerManager.miners.count
        let hasAccounts = accountCount > 0
        let hasGamePreferences = !settings.gamePreferences.isEmpty

        if settings.hasDismissedOnboarding {
            return nil
        }

        if hasAccounts && hasGamePreferences && !isRunningOnboardingSetup {
            return nil
        }

        let accountState: OnboardingAccountState = hasAccounts
            ? .hasAccounts(count: accountCount)
            : .noAccounts

        if !hasAccounts {
            return OnboardingPresentation(
                title: "Connect an account when you're ready",
                subtitle: "SwiftMiner is already usable. Add a Twitch account here or later from the dashboard.",
                accountState: accountState,
                showsGamePreferences: false,
                showsPreferences: false,
                setupStage: nil
            )
        }

        if isRunningOnboardingSetup {
            return OnboardingPresentation(
                title: "Syncing your account",
                subtitle: "The dashboard stays available while SwiftMiner pulls campaign and inventory data.",
                accountState: accountState,
                showsGamePreferences: false,
                showsPreferences: false,
                setupStage: onboardingSetupStage
            )
        }

        return OnboardingPresentation(
            title: hasGamePreferences ? "SwiftMiner is ready" : "Refine what SwiftMiner should prioritize",
            subtitle: hasGamePreferences
                ? "Everything here stays editable from the dashboard and settings."
                : "Game selection is optional and saves immediately. Leave it empty to mine any eligible campaign.",
            accountState: accountState,
            showsGamePreferences: !hasGamePreferences,
            showsPreferences: true,
            setupStage: nil
        )
    }

    private func runOnboardingSetupSequence() async {
        defer {
            isRunningOnboardingSetup = false
            onboardingSetupTask = nil
            refreshOnboardingPresentation()
        }

        updateOnboardingSetupStage(.connecting)
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }

        updateOnboardingSetupStage(.campaigns)
        await minerManager.forceRefreshAllMiners()
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }

        updateOnboardingSetupStage(.inventory)
        await minerManager.dataCoordinator.refreshAll()
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }

        updateOnboardingSetupStage(.finalising)
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
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
