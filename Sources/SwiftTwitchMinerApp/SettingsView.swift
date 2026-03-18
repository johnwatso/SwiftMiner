import SwiftUI
import SwiftTwitchMiner

/// Production-quality macOS Preferences window (Phase 6).
struct SettingsView: View {
    @StateObject private var settings = Settings.shared
    @Environment(NavigationModel.self) private var navigation
    
    var body: some View {
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
        .frame(width: 500, height: 400)
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
            .background(.bar)
        }
    }
}

// MARK: - Mining Settings

private struct MiningSettingsView: View {
    @ObservedObject var settings: Settings
    
    var body: some View {
        Form {
            Section {
                Toggle("Auto-claim drops", isOn: $settings.autoClaimEnabled)
                Toggle("Auto-claim community points", isOn: $settings.autoClaimPointsEnabled)
            } header: {
                Text("Automation")
            }
            
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Priority Games")
                        .font(.subheadline.weight(.medium))
                    TextField("e.g. THE FINALS, Rust", text: $settings.priorityGamesString)
                        .textFieldStyle(.roundedBorder)
                    Text("Miners will prioritize these games.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Excluded Games")
                        .font(.subheadline.weight(.medium))
                    TextField("e.g. Fortnite, Valorant", text: $settings.excludedGamesString)
                        .textFieldStyle(.roundedBorder)
                    Text("Miners will ignore these games.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Rules")
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
