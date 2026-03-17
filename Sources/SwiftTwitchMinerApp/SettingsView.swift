import SwiftUI

/// Settings panel for user preferences.
struct SettingsView: View {
    @StateObject private var settings = Settings.shared
    @State private var showResetConfirmation = false

    var body: some View {
        Form {
            // MARK: - Twitch API Section
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Paste your Twitch Client ID here", text: $settings.twitchClientId)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: settings.twitchClientId) { _, newValue in
                            // Auto-trim whitespace and newlines on every change
                            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            if trimmed != newValue {
                                settings.twitchClientId = trimmed
                            }
                        }

                    if !settings.twitchClientId.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            // Show first 6 and last 4 chars so user can verify without exposing full ID
                            let id = settings.twitchClientId
                            let preview = id.count > 10
                                ? "\(id.prefix(6))…\(id.suffix(4))  (\(id.count) chars)"
                                : id
                            Text(preview)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("Optional — leave blank to use Twitch's built-in client. To use your own app, find the Client ID at dev.twitch.tv (not the Client Secret).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Twitch API")
            }

            // MARK: - Multi-Miner Section
            Section("Multi-Miner") {
                Toggle("Auto-start all miners on launch", isOn: $settings.autoStartOnLaunch)
                    .help("Automatically start all configured miners when the app launches")

                Toggle("Sync miners state", isOn: $settings.syncMinersState)
                    .help("Keep all miners in sync - start/stop together")
            }

            // MARK: - Mining Section
            Section("Mining") {
                Toggle("Auto-claim drops", isOn: $settings.autoClaimEnabled)
                    .help("Automatically claim drops when they are ready across all miners")

                Toggle("Auto-claim channel points", isOn: $settings.autoClaimPointsEnabled)
                    .help("Automatically claim community points bonuses")
            }

            // MARK: - Global Rules Section
            Section("Global Mining Rules") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Priority Games")
                        .font(.subheadline.weight(.medium))
                    TextField("e.g. THE FINALS, Rust", text: $settings.priorityGamesString)
                        .textFieldStyle(.roundedBorder)
                    Text("Miners will always prioritize these games if campaigns are active.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Excluded Games")
                        .font(.subheadline.weight(.medium))
                    TextField("e.g. Fortnite, Valorant", text: $settings.excludedGamesString)
                        .textFieldStyle(.roundedBorder)
                    Text("Miners will ignore all campaigns for these games.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                
                Text("Separate multiple games with commas.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // MARK: - Display Section
            Section("Display") {
                Toggle("Show log console", isOn: $settings.showLogConsole)
                    .help("Show the log console at the bottom of the main window")

                Picker("Log level", selection: $settings.logLevel) {
                    ForEach(Settings.LogLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .help("Minimum log level to display in the console")

                Toggle("Claim notifications", isOn: $settings.showClaimNotifications)
                    .help("Show notifications when drops are claimed")
            }

            // MARK: - Advanced Section
            Section("Advanced") {
                Stepper(value: $settings.maxLogEntries, in: 100...2000, step: 100) {
                    HStack {
                        Text("Max log entries")
                        Spacer()
                        Text("\(settings.maxLogEntries)")
                            .foregroundStyle(.secondary)
                    }
                }
                .help("Maximum number of log entries to keep in memory")

                Toggle("Minimize to menu bar", isOn: $settings.minimizeToMenuBar)
                    .help("Hide the app from the Dock and show only in the menu bar")

                Toggle("Run in background", isOn: $settings.runInBackground)
                    .help("Continue mining when the app window is closed")
            }

            // MARK: - Reset Section
            Section {
                Button("Reset to Defaults", role: .destructive) {
                    showResetConfirmation = true
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 500)
        .confirmationDialog(
            "Reset all settings to default values?",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                settings.resetToDefaults()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - Toolbar Settings Button

struct SettingsToolbarButton: View {
    @State private var showSettings = false
    
    var body: some View {
        Button {
            showSettings = true
        } label: {
            Label("Settings", systemImage: "gear")
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .padding()
        }
    }
}

// MARK: - Account Section (for ContentView integration)

struct AccountSection: View {
    @Environment(AppModel.self) private var appModel
    @State private var showLogoutConfirmation = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "person.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.purple)
                
                VStack(alignment: .leading) {
                    Text("Connected Account")
                        .font(.headline)
                    Text("Authenticated")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button("Disconnect", role: .destructive) {
                    showLogoutConfirmation = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .confirmationDialog(
            "Disconnect your Twitch account?",
            isPresented: $showLogoutConfirmation,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                Task {
                    await logout()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will need to authenticate again to continue mining.")
        }
    }
    
    private func logout() async {
        await appModel.logout()
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
}
