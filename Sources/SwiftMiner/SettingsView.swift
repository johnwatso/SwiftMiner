import SwiftUI
import SwiftMinerCore

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

    var body: some View {
        Form {
            Section {
                Toggle("Minimize to menu bar", isOn: $settings.minimizeToMenuBar)
                Toggle("Run in background when closed", isOn: $settings.runInBackground)
            } header: {
                Text("Application")
            }

            Section {
                Toggle("Use Steam artwork for game images", isOn: $settings.preferSteamArtwork)

                SettingsSecondaryText("Fetches portrait artwork from Steam CDN. Falls back to Twitch artwork when a game is not found on Steam.")
            } header: {
                Text("Artwork")
            }

            Section {
                HStack(spacing: 12) {
                    Text("Queue Display Style")
                    Spacer(minLength: 8)
                    Picker("", selection: $settings.queueDisplayStyle) {
                        ForEach(Settings.QueueDisplayStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                }

                SettingsSecondaryText("Controls the Mining/Queued rail style in Overview. Stacked is the default, with Classic and Cover Flow available.")
            } header: {
                Text("Queue Display")
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
        Form {
            Section {
                if navigation.minerManager.miners.isEmpty {
                    SettingsSecondaryText("No accounts connected yet.")
                } else {
                    List {
                        ForEach(navigation.minerManager.miners) { miner in
                            HStack {
                                Text(miner.username)
                                Spacer()
                                Button("Remove") {
                                    Task { await navigation.minerManager.removeAccount(minerId: miner.id) }
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.red)
                            }
                        }
                    }
                    .frame(minHeight: 120)
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                }
            } header: {
                Text("Accounts")
            }

            Section {
                HStack {
                    Button("Import from TDM\u{2026}") {
                        showImporter = true
                    }
                    
                    Button("Add Account\u{2026}") {
                        navigation.showAddAccountSheet = true
                    }
                }
            } header: {
                Text("Management")
            }
        }
        .formStyle(.grouped)
        .padding(24)
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

    private func importCookies(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        Task {
            do {
                let token = try TDMCookieParser.parseToken(from: url)
                let authService = TwitchAuthService(clientId: ClientConfiguration.clientId)
                let account = try await authService.importTDMSession(token: token)

                let minerId = navigation.minerManager.addAccount(account)
                let settings = Settings.shared
                try? await navigation.minerManager.startMiner(
                    minerId: minerId,
                    priorityGames: settings.priorityGames,
                    excludedGames: settings.excludedGames,
                    strategy: settings.miningStrategy,
                    enableBadgesEmotes: settings.enableBadgesEmotes,
                    showClaimNotifications: settings.showClaimNotifications
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
            return "Mine any eligible campaign."
        case .prioritiseSelected:
            return "Prioritise selected games first, then fall back to other eligible campaigns."
        case .onlyPriority:
            return "Only mine selected games. Miners stay idle when none are available."
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
    @State private var showResetConfirmation = false
    @State private var showClientIdAlert = false
    @State private var tempClientId = ""
#if DEBUG
    @State private var debugGameDraft = ""
#endif

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Twitch Client ID")
                    Spacer()
                    
                    if settings.twitchClientId.isEmpty {
                        Button("Set Custom Client ID\u{2026}") {
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
                            
                            Button("Reset") {
                                settings.twitchClientId = ""
                            }
                            .buttonStyle(.link)
                            .foregroundStyle(.red)
                        }
                    }
                }

                SettingsSecondaryText("By default, the app uses a built-in client. Only change this if you know what you are doing.")
            } header: {
                Text("API Configuration")
            }

            Section {
                Button("Reset All Settings\u{2026}", role: .destructive) {
                    showResetConfirmation = true
                }
                .foregroundStyle(.red)
            } header: {
                Text("Maintenance")
            }

#if DEBUG
            Section {
                Toggle("Enable Fake Queue", isOn: $settings.debugFakeQueueEnabled)

                if settings.debugFakeQueueEnabled {
                    Toggle("Show Debug Preview Badge", isOn: $settings.debugShowPreviewBadge)

                    HStack(spacing: 12) {
                        Text("Queue Source")
                        Spacer(minLength: 8)
                        Picker("", selection: $settings.debugFakeQueueSource) {
                            ForEach(Settings.DebugFakeQueueSource.allCases) { source in
                                Text(source.displayName).tag(source)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 240)
                    }

                    Stepper(
                        "Queue Length: \(settings.clampedDebugFakeQueueLength)",
                        value: $settings.debugFakeQueueLength,
                        in: 1...8
                    )

                    if settings.debugFakeQueueSource == .customGames {
                        HStack(spacing: 10) {
                            TextField("Add custom game", text: $debugGameDraft)
                                .textFieldStyle(.roundedBorder)

                            Button("Add") {
                                settings.addDebugFakeQueueGame(debugGameDraft)
                                debugGameDraft = ""
                            }
                            .disabled(debugGameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        if settings.debugFakeQueueCustomGames.isEmpty {
                            SettingsSecondaryText("No custom games yet. Add game names for screenshot queue previews.")
                        } else {
                            List {
                                ForEach(Array(settings.debugFakeQueueCustomGames.enumerated()), id: \.offset) { _, gameName in
                                    Text(gameName)
                                }
                                .onDelete(perform: settings.removeDebugFakeQueueGames)
                                .onMove(perform: settings.moveDebugFakeQueueGames)
                            }
                            .frame(minHeight: 120, maxHeight: 180)
                        }
                    }
                }

                SettingsSecondaryText("Testing only. Overview renders a synthetic queue for screenshots. The debug badge is optional.")
            } header: {
                Text("Debug Testing")
            }
#endif
        }
        .formStyle(.grouped)
        .padding(24)
        .confirmationDialog("Reset all settings?", isPresented: $showResetConfirmation) {
            Button("Reset", role: .destructive) {
                settings.resetToDefaults()
            }
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
