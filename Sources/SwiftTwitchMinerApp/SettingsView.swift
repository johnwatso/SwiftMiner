import SwiftUI
import SwiftTwitchMiner

/// Production-quality macOS Preferences window (Phase 6).
struct SettingsView: View {
    @StateObject private var settings = Settings.shared
    @Environment(NavigationModel.self) private var navigation
    
    var body: some View {
        ZStack {
            LiquidGlassBackdrop()

            TabView {
                GeneralSettingsView(settings: settings)
                    .tabItem {
                        Label("General", systemImage: "gearshape")
                    }
                    .tag("general")

                AccountSettingsView(navigation: navigation)
                    .tabItem {
                        Label("Accounts", systemImage: "person.2")
                    }
                    .tag("accounts")

                MiningSettingsView(settings: settings)
                    .tabItem {
                        Label("Mining", systemImage: "hammer")
                    }
                    .tag("mining")

                AdvancedSettingsView(settings: settings)
                    .tabItem {
                        Label("Advanced", systemImage: "gearshape.2")
                    }
                    .tag("advanced")
            }
            .padding(20)
        }
        .frame(width: 500, height: 500)
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
                Toggle("Auto-start all miners on launch", isOn: $settings.autoStartOnLaunch)
                Toggle("Minimize to menu bar", isOn: $settings.minimizeToMenuBar)
                Toggle("Run in background when closed", isOn: $settings.runInBackground)
            } header: {
                Text("Application")
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
                HStack(spacing: 10) {
                    updateChannelButton(.stable)
                    updateChannelButton(.beta)
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

                if !updater.isConfigured {
                    Text("Set `SPARKLE_PUBLIC_ED_KEY` in the app target build settings and publish an appcast to enable Sparkle updates.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Software Updates")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func updateChannelButton(_ channel: AppUpdater.UpdateChannel) -> some View {
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
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.2), lineWidth: isSelected ? 1.4 : 1)
        )
    }
}

// MARK: - Account Settings

private struct AccountSettingsView: View {
    let navigation: NavigationModel

    var body: some View {
        VStack(spacing: 0) {
            List {
                if navigation.minerManager.miners.isEmpty {
                    MaterialEmptyStatePanel(
                        "No Accounts",
                        systemImage: "person.slash",
                        description: "Add a Twitch account to start mining."
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(navigation.minerManager.miners) { miner in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(miner.username).font(.headline)
                                Text(miner.accountId).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove") {
                                Task { await navigation.minerManager.removeAccount(minerId: miner.id) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .scrollContentBackground(.hidden)

            Divider()

            HStack {
                Button {
                    showImporter = true
                } label: {
                    Label("Import from TDM", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .help("Import session cookies from TwitchDropsMiner (cookies.jar)")

                Spacer()
                
                Button {
                    navigation.showAddAccountSheet = true
                } label: {
                    Label("Add Account", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(.regularMaterial)
        }
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

    @State private var showImporter = false
    @State private var showAlert = false
    @State private var alertMessage = ""

    private func importCookies(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        Task {
            do {
                let token = try TDMCookieParser.parseToken(from: url)
                let authService = TwitchAuthService(clientId: ClientConfiguration.clientId)
                let account = try await authService.importTDMSession(token: token)
                
                navigation.minerManager.addAccount(account)
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
            } header: {
                Text("Mining Strategy")
            } footer: {
                switch settings.miningStrategy {
                case .mineAll:
                    Text("Mine any eligible campaign.")
                case .prioritiseSelected:
                    Text("Prioritize selected games, fallback to any eligible.")
                case .onlyPriority:
                    Text("Only mine selected games. Idle if none available.")
                }
            }

            Section {
                GamePreferencesSection(
                    settings: settings,
                    minerManager: navigation.minerManager
                )
            } header: {
                Text("Game Preferences")
            } footer: {
                Text("Search for games with active drop campaigns. Added games default to preferred, and clicking a chip cycles preferred, excluded, and neutral.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Advanced Settings

private struct AdvancedSettingsView: View {
    @ObservedObject var settings: Settings
    @State private var showResetConfirmation = false
    
    var body: some View {
        Form {
            Section {
                TextField("Twitch Client ID", text: $settings.twitchClientId)
                    .textFieldStyle(.roundedBorder)
                Text("Leave blank to use default built-in client.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("API Configuration")
            }
            
            Section {
                Button("Reset All Settings", role: .destructive) {
                    showResetConfirmation = true
                }
            } header: {
                Text("Maintenance")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset all settings?", isPresented: $showResetConfirmation) {
            Button("Reset", role: .destructive) { settings.resetToDefaults() }
        }
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
        .environment(NavigationModel(clientId: "preview"))
}
