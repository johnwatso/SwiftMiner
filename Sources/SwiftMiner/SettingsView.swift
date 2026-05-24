import SwiftUI
import SwiftMinerCore
import SwiftMinerService
import TipKit
import AppKit
import UniformTypeIdentifiers

/// macOS Settings window using a Safari-style TabView with a top toolbar.
struct SettingsView: View {
    @StateObject private var settings = Settings.shared
    @Environment(NavigationModel.self) private var navigation
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView(settings: settings)
                .tabItem {
                    SettingsTabItem(tab: .general)
                }
                .tag(SettingsTab.general)

            AccountSettingsView(navigation: navigation)
                .tabItem {
                    SettingsTabItem(tab: .accounts)
                }
                .tag(SettingsTab.accounts)

            MiningSettingsView(settings: settings)
                .tabItem {
                    SettingsTabItem(tab: .mining)
                }
                .tag(SettingsTab.mining)

            if settings.swiftBotEnabled {
                IntegrationsSettingsView(settings: settings)
                    .tabItem {
                        SettingsTabItem(tab: .integrations)
                    }
                    .tag(SettingsTab.integrations)
            }

            AdvancedSettingsView(settings: settings)
                .tabItem {
                    SettingsTabItem(tab: .advanced)
                }
                .tag(SettingsTab.advanced)
        }
        .padding(.top, -2)
        .frame(width: 520)
    }
}

private enum SettingsTab: String, CaseIterable, Hashable, Identifiable {
    case general
    case accounts
    case mining
    case integrations
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .accounts: return "Accounts"
        case .mining: return "Mining"
        case .integrations: return "Integrations"
        case .advanced: return "Advanced"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .accounts: return "person.2"
        case .mining: return "hammer"
        case .integrations: return "app.connected.to.app.below.fill"
        case .advanced: return "gearshape.2"
        }
    }
}

/// Custom tab-item label with precise optical centering and tight spacing.
/// On macOS the system extracts the Image and Text from .tabItem to build the
/// segmented control; explicit sizing here ensures every icon sits consistently.
private struct SettingsTabItem: View {
    let tab: SettingsTab

    var body: some View {
        VStack(spacing: 1) {
            Image(systemName: tab.systemImage)
                .font(.system(size: 12, weight: .medium))
                .imageScale(.small)
                .symbolRenderingMode(.hierarchical)
                .frame(height: 14, alignment: .center)
            Text(tab.title)
                .font(.system(size: 10, weight: .medium))
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
                if loginItemSettings.isEnabled {
                    Toggle("Start minimised", isOn: $settings.startMinimized)
                    SettingsSecondaryText("Only applies to login launches. Manual launches from the Dock or Finder always show the window.")
                }

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
                        Task { await navigation.minerManager.updateNotificationPreference(enabled: newValue && settings.allowsOperatorNotifications()) }
                    }

                Toggle("Quiet hours", isOn: $settings.quietHoursEnabled)
                    .onChange(of: settings.quietHoursEnabled) { _, _ in
                        Task { await navigation.minerManager.updateNotificationPreference(enabled: settings.showClaimNotifications && settings.allowsOperatorNotifications()) }
                    }
                if settings.quietHoursEnabled {
                    HStack {
                        Picker("From", selection: quietStartBinding) {
                            ForEach(0..<24, id: \.self) { hour in
                                Text(hourLabel(hour)).tag(hour)
                            }
                        }
                        Picker("Until", selection: quietEndBinding) {
                            ForEach(0..<24, id: \.self) { hour in
                                Text(hourLabel(hour)).tag(hour)
                            }
                        }
                    }
                    SettingsSecondaryText("Suppresses local claim notifications and Discord DM events during the selected window.")
                }
            } header: {
                Text("Notifications")
            }

            Section {
                Toggle("Enable Discord Integration", isOn: $settings.swiftBotEnabled)
                SettingsSecondaryText("Enables the local Discord/SwiftBot bridge. When on, an Integrations tab appears here for endpoint and webhook configuration.")
            } header: {
                Text("Integrations")
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
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .padding(.top, 10)
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

    private var quietStartBinding: Binding<Int> {
        Binding {
            settings.quietHoursStartMinute / 60
        } set: { hour in
            settings.quietHoursStartMinute = hour * 60
        }
    }

    private var quietEndBinding: Binding<Int> {
        Binding {
            settings.quietHoursEndMinute / 60
        } set: { hour in
            settings.quietHoursEndMinute = hour * 60
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        let date = Calendar.current.date(from: DateComponents(hour: hour, minute: 0)) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
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
                    showClaimNotifications: settings.showClaimNotifications && settings.allowsOperatorNotifications(),
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

                Toggle("Stall recovery", isOn: $settings.antiStallRecoveryEnabled)
                    .onChange(of: settings.antiStallRecoveryEnabled) { _, newValue in
                        Task { await navigation.minerManager.updateAntiStallRecovery(enabled: newValue) }
                    }
                SettingsSecondaryText("Auto-recovers a miner after a recoverable disconnect or if it goes quiet while other miners stay active.")

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
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .padding(.top, 10)
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

// MARK: - Integrations Settings

private struct IntegrationsSettingsView: View {
    @ObservedObject var settings: Settings
    @Environment(NavigationModel.self) private var navigation
    @State private var isTestingConnection = false
    @State private var connectionTestMessage: String?
    @State private var copiedPairingBundle = false
    @State private var debugTargetSelection: String?
    @State private var debugDiscordUsers: [SwiftBotDiscordUser] = []
    @State private var isLoadingDebugUsers = false

    private let defaultSwiftBotEndpoint = "http://localhost:38888"

    var body: some View {
        Form {
            statusCard

            importantSection

            activitySection

            onboardingInfoSection

#if DEBUG
            dmDebugSection
#endif
        }
        .formStyle(.grouped)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .padding(.top, 10)
    }

    // MARK: - Status Card

    private var statusCard: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(statusColor.opacity(0.12))
                            .frame(width: 34, height: 34)
                        Image(systemName: statusIcon)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(statusColor)
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        Text(statusTitle)
                            .font(.system(size: 13, weight: .semibold))
                        Text(statusSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        Task {
                            connectionTestMessage = nil
                            isTestingConnection = true
                            await navigation.checkSwiftBotConnection()
                            connectionTestMessage = connectionTestDescription(for: navigation.swiftBotState)
                            isTestingConnection = false
                        }
                    } label: {
                        if isTestingConnection {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                        }
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                    .disabled(isTestingConnection)
                    .help("Re-check SwiftBot connection")
                }

                Text("Sends Discord DMs for account recovery, drop claims, and campaign updates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineSpacing(1)

                if isTestingConnection {
                    Text("Checking SwiftBot…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let connectionTestMessage {
                    Text(connectionTestMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if navigation.swiftBotState != .connected {
                    Divider()
                        .padding(.vertical, 2)

                    HStack(spacing: 10) {
                        Button {
                            copyPairingBundle()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: copiedPairingBundle ? "checkmark.circle.fill" : "doc.on.doc")
                                Text(copiedPairingBundle ? "Copied" : "Pair with SwiftBot")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)

                        Text("Copies a pairing bundle. Paste it into SwiftBot to connect.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .listRowBackground(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(statusColor.opacity(0.14), lineWidth: 0.5)
                )
        )
    }

    private var statusTitle: String {
        switch navigation.swiftBotState {
        case .connected: return "Connected to SwiftBot"
        case .notConfigured: return "Discord Integration"
        case .disconnected: return "Not Connected"
        case .unpaired: return "Pairing Required"
        }
    }

    private var statusSubtitle: String {
        switch navigation.swiftBotState {
        case .connected: return "Messages will be delivered to Discord"
        case .notConfigured: return "Enable Discord integration to get started"
        case .disconnected: return "SwiftBot is not responding"
        case .unpaired: return "SwiftBot is running but has not been paired yet"
        }
    }

    private var statusIcon: String {
        switch navigation.swiftBotState {
        case .connected: return "checkmark.circle.fill"
        case .notConfigured: return "app.badge.checkmark"
        case .disconnected: return "exclamationmark.triangle.fill"
        case .unpaired: return "link.badge.plus"
        }
    }

    private var statusColor: Color {
        switch navigation.swiftBotState {
        case .connected: return .green
        case .notConfigured: return .secondary
        case .disconnected: return .orange
        case .unpaired: return .accentColor
        }
    }

    // MARK: - Pairing

    private func copyPairingBundle() {
        settings.ensureSwiftBotSecrets()
        let swiftBotEndpoint = normalizedValue(settings.swiftBotEndpoint) ?? defaultSwiftBotEndpoint
        let swiftBotWebhookURL = normalizedValue(settings.swiftBotWebhookURL)
            ?? swiftBotEndpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/webhooks/swiftminer/events"
        let swiftMinerEndpoint = normalizedValue(settings.swiftMinerAPIEndpoint) ?? "http://127.0.0.1:8080"

        if settings.swiftBotEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.swiftBotEndpoint = swiftBotEndpoint
            Task { await navigation.updateSwiftBotEndpoint(swiftBotEndpoint) }
        }
        if settings.swiftBotWebhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.swiftBotWebhookURL = swiftBotWebhookURL
            Task { await navigation.updateSwiftBotWebhookConfig() }
        }
        if settings.swiftMinerAPIEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.swiftMinerAPIEndpoint = swiftMinerEndpoint
        }

        let bundle: [String: Any] = [
            "version": 1,
            "endpoint": swiftMinerEndpoint,
            "swiftMinerEndpoint": swiftMinerEndpoint,
            "swiftBotEndpoint": swiftBotEndpoint,
            "apiKey": settings.swiftMinerAPIKey,
            "hmacSecret": settings.swiftBotHmacSecret,
            "webhookHint": swiftBotWebhookURL
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: bundle, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        let token = "swiftminer://pair?b=" + Data(json.utf8).base64EncodedString()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(token, forType: .string)
        copiedPairingBundle = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run {
                copiedPairingBundle = false
            }
        }
    }

    private func normalizedValue(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Connection Status

    private func connectionTestDescription(for state: SwiftBotConnectionState) -> String {
        switch state {
        case .connected:
            return "SwiftBot replied."
        case .disconnected:
            let endpoint = normalizedValue(settings.swiftBotEndpoint) ?? defaultSwiftBotEndpoint
            return "SwiftBot is not listening at \(endpoint)."
        case .notConfigured:
            return "No valid localhost endpoint is configured."
        case .unpaired:
            return "SwiftBot is reachable but not paired — paste the pairing bundle into SwiftBot."
        }
    }

    // MARK: - Important Notifications

    private var importantSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                notificationToggleRow(
                    title: "Twitch reconnect needed",
                    description: "Sent when a Twitch login session expires and needs reconnecting.",
                    isOn: $settings.dmConnectionExpiredEnabled
                )

                Divider().padding(.vertical, 2)

                notificationToggleRow(
                    title: "Game account link needed",
                    description: "Sent when you prioritised a game but haven't linked the required account.",
                    isOn: $settings.dmLinkRequiredEnabled
                )

                Divider().padding(.vertical, 2)

                notificationToggleRow(
                    title: "Something needs attention",
                    description: "Sent when a miner encounters an issue that needs a manual look.",
                    isOn: $settings.dmAccountActionRequiredEnabled
                )
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("Important")
                    .font(.subheadline.weight(.semibold))
            }
        } footer: {
            Text("These notifications relate to account recovery and linking. They are recommended to stay on.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Activity Notifications

    private var activitySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                notificationToggleRow(
                    title: "Drop claimed",
                    description: "Sent when SwiftMiner successfully claims a Drop.",
                    isOn: $settings.dmDropClaimedEnabled,
                    previewType: .dropClaimed
                )

                Divider().padding(.vertical, 2)

                notificationToggleRow(
                    title: "Campaign complete",
                    description: "Sent when all Drops in a campaign have been claimed.",
                    isOn: $settings.dmCampaignCompletedEnabled,
                    previewType: .campaignCompleted
                )

                Divider().padding(.vertical, 2)

                notificationToggleRow(
                    title: "New Drops campaign",
                    description: "Sent when a new campaign starts for a game you follow.",
                    isOn: $settings.dmCampaignDetectedEnabled,
                    previewType: .campaignDetected
                )

                Divider().padding(.vertical, 2)

                notificationToggleRow(
                    title: "Connection restored",
                    description: "Sent when SwiftMiner detects a miner has come back online.",
                    isOn: $settings.dmWelcomeBackEnabled,
                    previewType: .welcomeBack
                )
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "bell")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Activity")
                    .font(.subheadline.weight(.semibold))
            }
        } footer: {
            Text("These are informational updates about mining progress. Turn on the ones you find useful.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Onboarding Info

    private var onboardingInfoSection: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.blue)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Setup messages are always enabled")
                        .font(.caption.weight(.medium))
                    Text("Welcome, linking, and reconnection instructions are always sent so users can complete setup and recover accounts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                }
            }
            .padding(.vertical, 2)
        }
        .listRowBackground(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.blue.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.blue.opacity(0.10), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Notification Toggle Row

    private func notificationToggleRow(
        title: String,
        description: String,
        isOn: Binding<Bool>,
        previewType: SwiftBotDMMessageType? = nil
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

#if DEBUG
            if let previewType {
                Button {
                    Task { await sendPreview(type: previewType) }
                } label: {
                    Image(systemName: "play.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Preview this message")
                .disabled(debugTargetId == nil)
            }
#endif

            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Preview

    private func sendPreview(type: SwiftBotDMMessageType) async {
        guard let discordId = debugTargetId else { return }
        let request = SwiftBotDMRequest(
            messageType: type,
            debug: true,
            twitchUsername: "preview_user",
            priorityGames: Settings.shared.priorityGames,
            activationCode: type == .setup ? "ABCD-EFGH" : nil,
            activationExpiresInMinutes: type == .setup ? 29 : nil,
            activationURL: type == .setup ? "https://www.twitch.tv/activate?code=ABCD-EFGH" : nil,
            campaignName: "Preview Campaign",
            milestoneTitle: "Preview Drop"
        )
        _ = await navigation.swiftBotConnectionService.sendDebugDM(to: discordId, request: request)
    }

    private var firstLinkedDiscordId: String? {
        navigation.minerManager.miners.compactMap(\.ownerDiscordId).first
    }

    /// Discord ID used for debug previews — picker selection takes precedence
    /// when set, otherwise we fall back to the first linked miner's Discord ID.
    private var debugTargetId: String? {
        debugTargetSelection ?? firstLinkedDiscordId
    }

    private func displayName(for discordId: String) -> String {
        debugDiscordUsers.first(where: { $0.id == discordId })?.displayName.nilIfBlank
            ?? debugDiscordUsers.first(where: { $0.id == discordId })?.username?.nilIfBlank
            ?? navigation.minerManager.miners.first(where: { $0.ownerDiscordId == discordId })?.username
            ?? "Linked Discord user"
    }

#if DEBUG
    // MARK: - DM Debug

    private var dmDebugSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Target")
                        .font(.callout)

                    Picker("", selection: debugTargetBinding) {
                        if debugTargetCandidates.isEmpty {
                            Text("No linked Discord users").tag(String?.none)
                        } else {
                            ForEach(debugTargetCandidates, id: \.id) { user in
                                Text(user.displayName).tag(Optional(user.id))
                            }
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .disabled(debugTargetCandidates.isEmpty)

                    Button {
                        Task { await loadDebugDiscordUsers() }
                    } label: {
                        if isLoadingDebugUsers {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                        }
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                    .disabled(isLoadingDebugUsers)
                    .help("Refresh Discord user list from SwiftBot")

                    Spacer()
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await sendAllDebugDMs() }
                    } label: {
                        Label("Send All Test DMs", systemImage: "text.bubble")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(debugTargetId == nil)

                    if let id = debugTargetId {
                        SettingsSecondaryText("Sending to \(displayName(for: id))")
                    } else {
                        SettingsSecondaryText("No linked Discord account found.", tint: .orange)
                    }

                    Spacer()
                }
            }
        } header: {
            Text("Debug Testing")
        }
        .task {
            await loadDebugDiscordUsers()
        }
    }

    /// Union of locally-known miner Discord IDs and SwiftBot's known users, with
    /// display names where available. Locally-known IDs fall back to the linked
    /// Twitch username so raw snowflakes stay out of the UI.
    private var debugTargetCandidates: [SwiftBotDiscordUser] {
        var seen: Set<String> = []
        var result: [SwiftBotDiscordUser] = []

        for user in debugDiscordUsers where seen.insert(user.id).inserted {
            result.append(user)
        }
        for miner in navigation.minerManager.miners {
            guard let id = miner.ownerDiscordId, seen.insert(id).inserted else { continue }
            result.append(SwiftBotDiscordUser(id: id, displayName: miner.displayName, username: miner.username))
        }
        return result
    }

    private var debugTargetBinding: Binding<String?> {
        Binding(
            get: { debugTargetId },
            set: { debugTargetSelection = $0 }
        )
    }

    private func loadDebugDiscordUsers() async {
        isLoadingDebugUsers = true
        defer { isLoadingDebugUsers = false }
        let users = await navigation.swiftBotConnectionService.fetchDiscordUsers()
        debugDiscordUsers = users
    }

    private func sendAllDebugDMs() async {
        guard let discordId = debugTargetId else { return }
        let order: [SwiftBotDMMessageType] = [
            .welcome, .discordLinked, .setup, .linked,
            .campaignDetected, .prioritisedGameNeedsLinking,
            .accountActionRequired, .reauth, .welcomeBack,
            .dropClaimed, .campaignCompleted
        ]
        for type in order {
            let request = SwiftBotDMRequest(
                messageType: type,
                debug: true,
                twitchUsername: "test_user",
                priorityGames: Settings.shared.priorityGames,
                activationCode: type == .setup ? "ABCD-EFGH" : nil,
                activationExpiresInMinutes: type == .setup ? 29 : nil,
                activationURL: type == .setup ? "https://www.twitch.tv/activate?code=ABCD-EFGH" : nil,
                affectedGame: "Test Game",
                campaignName: "Test Campaign",
                milestoneTitle: "50% Complete",
                recoveryReason: "Twitch token expired during mining."
            )
            _ = await navigation.swiftBotConnectionService.sendDebugDM(to: discordId, request: request)
            try? await Task.sleep(for: .milliseconds(650))
        }
    }
#endif
}

// MARK: - Advanced Settings

private struct AdvancedSettingsView: View {
    @ObservedObject var settings: Settings
    @Environment(NavigationModel.self) private var navigation
    @State private var showResetConfirmation = false
    @State private var showDropCacheConfirmation = false
    @State private var showClientIdAlert = false
    @State private var tempClientId = ""
    @State private var backupMessage: String?

    var body: some View {
        Form {
            apiConfigurationSection
            backupSection
            maintenanceSection

#if DEBUG
            debugTestingSection
#endif
        }
        .formStyle(.grouped)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .padding(.top, 10)
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

    private var maintenanceSection: some View {
        Section {
            Button("Clear Drop History Cache\u{2026}") {
                showDropCacheConfirmation = true
            }
            SettingsSecondaryText("Removes preserved campaign and inventory snapshots. Use this if old expired drops look wrong; the next refresh rebuilds history from Twitch.")

            Button("Reset All Settings\u{2026}") {
                showResetConfirmation = true
            }
            .foregroundStyle(.red)
            SettingsSecondaryText("Restores every SwiftMiner preference to its default. Account logins are kept.")
        } header: {
            Text("Maintenance")
        }
    }

    private var backupSection: some View {
        Section {
            HStack(spacing: 8) {
                Button("Export Settings\u{2026}") {
                    exportSettingsBackup()
                }
                Button("Import Settings\u{2026}") {
                    importSettingsBackup()
                }
            }

            if let backupMessage {
                SettingsSecondaryText(backupMessage)
            } else {
                SettingsSecondaryText("Exports preferences, game rules, filters, quiet hours and integration endpoints. Account login tokens are never included.")
            }
        } header: {
            Text("Backup")
        }
    }

    private func exportSettingsBackup() {
        do {
            let data = try settings.exportBackupData()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "SwiftMiner Settings Backup.json"
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            backupMessage = "Settings backup exported."
        } catch {
            backupMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importSettingsBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            try settings.importBackupData(data)
            Task {
                await navigation.minerManager.updateAntiStallRecovery(enabled: settings.antiStallRecoveryEnabled)
                await navigation.minerManager.updateFollowedStreamerPriority(enabled: settings.prioritiseFollowedStreamers)
            }
            backupMessage = "Settings backup imported."
        } catch {
            backupMessage = "Import failed: \(error.localizedDescription)"
        }
    }

#if DEBUG
    private var debugTestingSection: some View {
        Section {
            Toggle("Bypass link requirement", isOn: $settings.debugBypassLinkRequirement)
            SettingsSecondaryText("Mines a random live channel for any time-active campaign, ignoring account linkage. Drops won't actually credit — for exercising the watch pipeline only.")

            Toggle("Force Show Tips", isOn: .constant(false))
                .disabled(true)
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

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
        .environment(NavigationModel(clientId: "preview"))
}
