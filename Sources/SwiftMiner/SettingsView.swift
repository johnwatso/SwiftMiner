import SwiftUI
import SwiftMinerCore
import TipKit

/// macOS Settings window using a Safari-style TabView with a top toolbar.
struct SettingsView: View {
    @StateObject private var settings = Settings.shared
    @Environment(NavigationModel.self) private var navigation
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView(settings: settings)
                .tabItem {
                    Label(SettingsTab.general.title, systemImage: SettingsTab.general.systemImage)
                }
                .tag(SettingsTab.general)

            AccountSettingsView(navigation: navigation)
                .tabItem {
                    Label(SettingsTab.accounts.title, systemImage: SettingsTab.accounts.systemImage)
                }
                .tag(SettingsTab.accounts)

            MiningSettingsView(settings: settings)
                .tabItem {
                    Label(SettingsTab.mining.title, systemImage: SettingsTab.mining.systemImage)
                }
                .tag(SettingsTab.mining)

            AdvancedSettingsView(settings: settings)
                .tabItem {
                    Label(SettingsTab.advanced.title, systemImage: SettingsTab.advanced.systemImage)
                }
                .tag(SettingsTab.advanced)
        }
        .frame(width: 520) // Authentic Safari-style pane width
    }
}

private enum SettingsTab: String, CaseIterable, Hashable, Identifiable {
    case general
    case accounts
    case mining
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .accounts: return "Accounts"
        case .mining: return "Mining"
        case .advanced: return "Advanced"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .accounts: return "person.2"
        case .mining: return "hammer"
        case .advanced: return "gearshape.2"
        }
    }
}

// MARK: - General Settings

private struct GeneralSettingsView: View {
    @ObservedObject var settings: Settings
    @EnvironmentObject private var updater: AppUpdater
    @Environment(NavigationModel.self) private var navigation
    @StateObject private var loginItemSettings = LoginItemSettings()

    var body: some View {
        Form {
            Section {
                Picker("App Presence", selection: $settings.appPresenceMode) {
                    ForEach(AppPresenceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                SettingsSecondaryText(settings.appPresenceMode.detail)

                Toggle("Run in background when closed", isOn: $settings.runInBackground)
                Toggle("Start at login", isOn: startAtLoginBinding)
                    .onAppear {
                        loginItemSettings.refresh()
                    }
                Toggle("Start minimised", isOn: $settings.startMinimized)

                if loginItemSettings.requiresApproval {
                    Label("Approve SwiftMiner in System Settings to finish enabling login launch.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if let errorMessage = loginItemSettings.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Application")
            }

            Section {
                Toggle("Use Steam artwork for game images", isOn: $settings.preferSteamArtwork)
                    .minerTip(SteamArtworkTip())

                SettingsSecondaryText("Fetches portrait artwork from Steam CDN. Falls back to Twitch artwork when a game is not found on Steam.")
            } header: {
                Text("Artwork")
            }

            Section {
                Toggle("Show in-app tips", isOn: $settings.tipsEnabled)
                SettingsSecondaryText("Show occasional TipKit hints that explain features like prioritising games or filtering drops.")
            } header: {
                Text("Tips")
            }

            Section {
                Toggle("Show icons in Activity Log", isOn: $settings.showActivityLogIcons)
                SettingsSecondaryText("Display a category icon next to each row in the Activity Log instead of a plain dot.")

                Toggle("Animate new rows", isOn: $settings.animateActivityLogRows)
                SettingsSecondaryText("Slide and fade new entries in as they appear.")
            } header: {
                Text("Activity Log")
            }

            Section {
                Toggle("Show notifications when drops are claimed", isOn: $settings.showClaimNotifications)
                    .onChange(of: settings.showClaimNotifications) { _, newValue in
                        Task { await navigation.minerManager.updateNotificationPreference(enabled: newValue) }
                    }
            } header: {
                Text("Notifications")
            }

            Section {
                let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
                let currentBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"

                HStack(spacing: 8) {
                    updateChannelOption(.stable)
                    updateChannelOption(.beta)
                }

                if updater.selectedChannel == .beta {
                    Label("Beta channel enabled. Updates will come from the beta appcast feed.", systemImage: "flask.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Toggle("Prompt for available updates", isOn: automaticUpdateChecksBinding)
                    .disabled(!updater.canCheckForUpdates)
                SettingsSecondaryText("Check in the background and show Sparkle's update prompt when user action is needed.")

                Toggle("Allow unattended updates", isOn: automaticUpdatesBinding)
                    .disabled(!updater.canCheckForUpdates || !updater.automaticallyChecksForUpdates)
                SettingsSecondaryText("Download and install eligible updates in the background when macOS does not require authorization.")

                Button("Check for Updates...") {
                    updater.checkForUpdates()
                }
                .buttonStyle(.bordered)
                .disabled(!updater.canCheckForUpdates)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Current version: \(currentVersion)")
                    Text("Build: \(currentBuild)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 2)

                if !updater.isConfigured {
                    SettingsSecondaryText("Set SUFeedURL and SUPublicEDKey in the app target build settings to enable Sparkle updates.")
                }
            } header: {
                Text("Software Updates")
            }
        }
        .formStyle(.grouped)
        .padding(24)
    }

    private var startAtLoginBinding: Binding<Bool> {
        Binding {
            loginItemSettings.isEnabled
        } set: { isEnabled in
            loginItemSettings.setEnabled(isEnabled)
        }
    }

    private var automaticUpdateChecksBinding: Binding<Bool> {
        Binding {
            updater.automaticallyChecksForUpdates
        } set: { isEnabled in
            updater.setAutomaticallyChecksForUpdates(isEnabled)
        }
    }

    private var automaticUpdatesBinding: Binding<Bool> {
        Binding {
            updater.automaticallyDownloadsUpdates
        } set: { isEnabled in
            updater.setAutomaticallyDownloadsUpdates(isEnabled)
        }
    }

    @ViewBuilder
    private func updateChannelOption(_ channel: AppUpdater.UpdateChannel) -> some View {
        let isSelected = updater.selectedChannel == channel
        Button {
            updater.setUpdateChannel(channel)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: channel.symbolName)
                Text(channel.label)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? .white.opacity(0.42) : .white.opacity(0.18), lineWidth: isSelected ? 1.4 : 1)
        )
    }
}

// MARK: - Account Settings

private struct AccountSettingsView: View {
    let navigation: NavigationModel

    @State private var showImporter = false
    @State private var showAlert = false
    @State private var alertMessage = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                settingsSection("Accounts") {
                if navigation.minerManager.miners.isEmpty {
                    SettingsSecondaryText("No accounts connected yet. Add or import an account to start mining.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    VStack(spacing: 0) {
                        ForEach(navigation.minerManager.miners) { miner in
                            AccountSettingsAccountRow(miner: miner, navigation: navigation)

                            if miner.id != navigation.minerManager.miners.last?.id {
                                Divider()
                                    .padding(.leading, 14)
                            }
                        }
                    }
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.secondary.opacity(0.16), lineWidth: 1)
                    )
                }
                }

                settingsSection("Management") {
                    HStack(spacing: 10) {
                    Button("Import from TDM\u{2026}") {
                        showImporter = true
                    }
                    
                    Button("Add Account\u{2026}") {
                        navigation.showAddAccountSheet = true
                    }

                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .contentMargins(24, for: .scrollContent)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importCookies(from: url)
            case .failure(let error):
                print("[AccountSettings] File selection failed: \(error.localizedDescription)")
            }
        }
        .alert("Import Result", isPresented: $showAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
    }

    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func importCookies(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        Task {
            do {
                let token = try TDMCookieParser.parseToken(from: url)
                let authService = TwitchAuthService(clientId: ClientConfiguration.clientId, tokenStore: KeychainTokenStore())
                let account = try await authService.importTDMSession(token: token)

                let minerId = try navigation.minerManager.addAccount(account)
                let settings = Settings.shared
                try? await navigation.minerManager.startMiner(
                    minerId: minerId,
                    priorityGames: settings.priorityGames,
                    excludedGames: settings.excludedGames,
                    strategy: settings.miningStrategy,
                    enableBadgesEmotes: settings.enableBadgesEmotes,
                    showClaimNotifications: settings.showClaimNotifications,
                    avoidDuplicateStreams: settings.avoidDuplicateStreams,
                    antiStallRecoveryEnabled: settings.antiStallRecoveryEnabled,
                    prioritiseFollowedStreamers: settings.prioritiseFollowedStreamers
                )
                alertMessage = "Successfully imported account: \(account.username)"
                showAlert = true
            } catch {
                alertMessage = "Import failed: \(error.localizedDescription)"
                showAlert = true
            }
        }
    }
}

private struct AccountSettingsAccountRow: View {
    let miner: MinerManager.ManagedMiner
    let navigation: NavigationModel

    @State private var nickname: String
    @FocusState private var isNicknameFocused: Bool

    init(miner: MinerManager.ManagedMiner, navigation: NavigationModel) {
        self.miner = miner
        self.navigation = navigation
        self._nickname = State(initialValue: miner.nickname ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(miner.displayName)
                        .font(.body.weight(.semibold))
                    if miner.nickname != nil {
                        Text("@\(miner.username)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 12)

                Button(role: .destructive) {
                    Task { await navigation.minerManager.removeAccount(minerId: miner.id) }
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Remove account")
            }

            HStack(spacing: 8) {
                Text("Nickname")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .leading)

                TextField("Optional", text: $nickname)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNicknameFocused)
                    .onSubmit { saveNickname() }
                    .onChange(of: isNicknameFocused) { _, focused in
                        if !focused {
                            saveNickname()
                        }
                    }

                if !nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        nickname = ""
                        saveNickname()
                    } label: {
                        Label("Clear nickname", systemImage: "xmark.circle.fill")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Clear nickname")
                }
            }
        }
        .padding(14)
        .onChange(of: miner.nickname) { _, newValue in
            nickname = newValue ?? ""
        }
    }

    private func saveNickname() {
        let normalized = Account.normalizedNickname(nickname)
        guard normalized != miner.nickname else { return }

        Task {
            await navigation.minerManager.updateMinerNickname(minerId: miner.id, nickname: normalized)
        }
    }
}

// MARK: - Mining Settings

private struct MiningSettingsView: View {
    @ObservedObject var settings: Settings
    @Environment(NavigationModel.self) private var navigation
    @State private var isShowingGameManagement = false

    var body: some View {
        Form {
            Section {
                Toggle("Auto-claim drops", isOn: $settings.autoClaimEnabled)
                Toggle("Auto-claim community points", isOn: $settings.autoClaimPointsEnabled)
            } header: {
                Text("Automation")
            }

            Section {
                Picker("Mining Strategy", selection: $settings.miningStrategy) {
                    ForEach(MiningStrategy.allCases) { strategy in
                        Text(strategy.displayName).tag(strategy)
                    }
                }
                
                SettingsSecondaryText(strategyDetailText)

                Toggle("Spread miners across streams", isOn: $settings.avoidDuplicateStreams)
                SettingsSecondaryText("Avoids putting multiple miners on the same stream when a campaign has more than four verified live channels. Small restricted campaigns can still share streams.")

                Toggle("Anti-stall recovery", isOn: $settings.antiStallRecoveryEnabled)
                    .onChange(of: settings.antiStallRecoveryEnabled) { _, newValue in
                        Task { await navigation.minerManager.updateAntiStallRecovery(enabled: newValue) }
                    }
                SettingsSecondaryText("Restarts an individual miner when it appears stuck after a long progress stall or recoverable network error.")

                Toggle("Prioritise followed and subscribed streamers", isOn: $settings.prioritiseFollowedStreamers)
                    .onChange(of: settings.prioritiseFollowedStreamers) { _, newValue in
                        Task { await navigation.minerManager.updateFollowedStreamerPriority(enabled: newValue) }
                    }
                SettingsSecondaryText("When a followed or subscribed streamer is live and verified for a matching campaign, SwiftMiner chooses subscribed channels first, then followed channels, before falling back to normal stream ranking.")
            } header: {
                Text("Strategy")
            }

            Section {
                Button("Manage Game Rules\u{2026}") {
                    isShowingGameManagement = true
                }
                
                if let count = gameCountText {
                    Text("\(count) rules active.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Game Rules")
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .sheet(isPresented: $isShowingGameManagement) {
            GamePreferenceManagementView(
                settings: settings,
                minerManager: navigation.minerManager
            )
        }
    }

    private var strategyDetailText: String {
        switch settings.miningStrategy {
        case .mineAll:
            return "Mine campaigns ending soonest, then prioritised games, then any other eligible drops."
        case .prioritiseSelected:
            return "Mine prioritised games first, then choose the campaign ending soonest."
        case .onlyPriority:
            return "Ignore non-prioritised campaigns entirely."
        }
    }

    private var gameCountText: String? {
        let count = settings.gamePreferences.count
        guard count > 0 else { return nil }
        return "\(count)"
    }

}

// MARK: - Advanced Settings

private struct AdvancedSettingsView: View {
    @ObservedObject var settings: Settings
    @Environment(NavigationModel.self) private var navigation
    @State private var showResetConfirmation = false
    @State private var showDropCacheConfirmation = false
    @State private var showClientIdAlert = false
    @State private var tempClientId = ""
    @State private var showEndpointAlert = false
    @State private var tempEndpoint = ""

    var body: some View {
        Form {
            apiConfigurationSection
            betaIntegrationSection
            maintenanceSection

#if DEBUG
            debugTestingSection
#endif
        }
        .formStyle(.grouped)
        .padding(24)
        .confirmationDialog("Reset all settings?", isPresented: $showResetConfirmation) {
            Button("Reset", role: .destructive) {
                settings.resetToDefaults()
            }
        }
        .confirmationDialog("Clear cached drop history?", isPresented: $showDropCacheConfirmation) {
            Button("Clear History Cache", role: .destructive) {
                Task {
                    await navigation.minerManager.dataCoordinator.clearCachedDropHistory()
                    await navigation.minerManager.dataCoordinator.refreshAll()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This clears local drop campaign and inventory snapshots. Account logins and app settings are kept.")
        }
        .alert("Custom Twitch Client ID", isPresented: $showClientIdAlert) {
            TextField("Client ID", text: $tempClientId)
            Button("Save") {
                settings.twitchClientId = tempClientId.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enter a custom Twitch Client ID to use for API requests. Leave blank to reset to default.")
        }
        .alert("SwiftBot Integration", isPresented: $showEndpointAlert) {
            TextField("Endpoint URL", text: $tempEndpoint)
            Button("Save") {
                let cleanUrl = tempEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                // Only save if URL passes localhost-only validation (mirrors service constraint)
                guard let url = URL(string: cleanUrl),
                      let scheme = url.scheme, scheme == "http" || scheme == "https",
                      let host = url.host, host == "localhost" || host == "127.0.0.1" else {
                    return
                }
                settings.swiftBotEndpoint = cleanUrl
                Task { await navigation.updateSwiftBotEndpoint(cleanUrl) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enter the SwiftBot REST API address (e.g. http://127.0.0.1:8080).")
        }
    }

    // MARK: Sections

    private var apiConfigurationSection: some View {
        Section {
            LabeledContent("Twitch Client ID") {
                if settings.twitchClientId.isEmpty {
                    Button("Set Custom\u{2026}") {
                        tempClientId = ""
                        showClientIdAlert = true
                    }
                    .buttonStyle(.link)
                } else {
                    HStack(spacing: 8) {
                        Text(settings.twitchClientId)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)

                        Button("Edit\u{2026}") {
                            tempClientId = settings.twitchClientId
                            showClientIdAlert = true
                        }
                        .buttonStyle(.link)

                        Button("Reset", role: .destructive) {
                            settings.twitchClientId = ""
                        }
                        .buttonStyle(.link)
                    }
                }
            }

            SettingsSecondaryText("By default, SwiftMiner uses a built-in Twitch client. Only change this if you know what you are doing.")
        } header: {
            Text("API Configuration")
        }
    }

    @ViewBuilder
    private var betaIntegrationSection: some View {
        Section {
            Toggle("Enable Discord Integration", isOn: $settings.swiftBotEnabled)
                .onChange(of: settings.swiftBotEnabled) { _, enabled in
                    if enabled {
                        settings.ensureSwiftBotSecrets()
                        Task { await navigation.checkSwiftBotConnection() }
                    } else {
                        navigation.swiftBotState = .notConfigured
                    }
                }

            SettingsSecondaryText("Experimental local-only Discord/SwiftBot tools. Keep this off unless you are actively testing the bot integration.")

            if settings.swiftBotEnabled {
                LabeledContent("SwiftBot Endpoint") {
                    if settings.swiftBotEndpoint.isEmpty {
                        Button("Configure\u{2026}") {
                            tempEndpoint = "http://127.0.0.1:8080"
                            showEndpointAlert = true
                        }
                        .buttonStyle(.link)
                    } else {
                        HStack(spacing: 8) {
                            Text(settings.swiftBotEndpoint)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)

                            Button("Edit\u{2026}") {
                                tempEndpoint = settings.swiftBotEndpoint
                                showEndpointAlert = true
                            }
                            .buttonStyle(.link)

                            Button("Reset", role: .destructive) {
                                settings.swiftBotEndpoint = ""
                                Task { await navigation.updateSwiftBotEndpoint("") }
                            }
                            .buttonStyle(.link)
                        }
                    }
                }

                SettingsSecondaryText("Address of the SwiftBot REST API (e.g. http://127.0.0.1:8080). Localhost only.")
            }
        } header: {
            Text("Beta Integrations")
        }
    }

    private var maintenanceSection: some View {
        Section {
            Button("Clear Cached Drop History\u{2026}", role: .destructive) {
                showDropCacheConfirmation = true
            }

            SettingsSecondaryText("Removes preserved campaign and inventory snapshots. Use this if old expired drops look wrong; the next refresh rebuilds history from Twitch.")

            Button("Reset All Settings\u{2026}", role: .destructive) {
                showResetConfirmation = true
            }

            SettingsSecondaryText("Restores every SwiftMiner preference to its default. Account logins are kept.")
        } header: {
            Text("Maintenance")
        }
    }

#if DEBUG
    private var debugTestingSection: some View {
        Section {
            Toggle("Bypass Link Requirement", isOn: $settings.debugBypassLinkRequirement)
                .onChange(of: settings.debugBypassLinkRequirement) { _, newValue in
                    Task { await navigation.minerManager.setDebugBypassLinkRequirement(newValue) }
                }

            SettingsSecondaryText("Mines a random live channel for any time-active campaign, ignoring account linkage. Drops won't actually credit — for exercising the watch pipeline only.")

            LabeledContent("TipKit Popovers") {
                HStack(spacing: 12) {
                    Button("Force Show") {
                        Tips.showAllTipsForTesting()
                    }
                    .buttonStyle(.link)

                    Button("Hide All") {
                        Tips.hideAllTipsForTesting()
                    }
                    .buttonStyle(.link)
                }
            }

            SettingsSecondaryText("Force Show ignores rules so every tip renders immediately. State resets on relaunch.")
        } header: {
            Text("Debug Testing")
        }
    }
#endif
}

// MARK: - Shared Components

private struct SettingsSecondaryText: View {
    let text: String
    var tint: Color = .secondary

    init(_ text: String, tint: Color = .secondary) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(tint)
            .padding(.vertical, 1)
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
        .environment(NavigationModel(clientId: "preview"))
}
