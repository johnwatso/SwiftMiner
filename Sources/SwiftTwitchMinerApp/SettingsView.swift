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
            } header: {
                Text("Notifications")
            }
        }
        .formStyle(.grouped)
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
                Spacer()
                Button {
                    navigation.showAddAccountSheet = true
                } label: {
                    Label("Add Account", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
            .background(.regularMaterial)
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
                    campaignStore: navigation.minerManager.campaignStore
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
