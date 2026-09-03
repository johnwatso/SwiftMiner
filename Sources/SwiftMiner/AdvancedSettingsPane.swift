// Advanced pane of the Settings window.
import SwiftUI
import SwiftMinerCore
import SwiftMinerService
import AppKit
import UniformTypeIdentifiers

// MARK: - Advanced Settings

struct AdvancedSettingsView: View {
    @Bindable var settings: Settings
    @Environment(NavigationModel.self) private var navigation
    @State private var showClientIdAlert = false
    @State private var tempClientId = ""
    @State private var backupMessage: String?

    var body: some View {
        Form {
            apiConfigurationSection
            backupSection
            diagnosticsSection
        }
        .formStyle(.grouped)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .padding(.top, 10)
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

    private var diagnosticsSection: some View {
        Section {
            Picker(selection: $settings.maxLogEntries) {
                ForEach(Settings.logEntryChoices, id: \.self) { count in
                    Text(count.formatted(.number.grouping(.automatic)) + " entries").tag(count)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Activity Log history")
                    Text("Stored separately for each activity category")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: settings.maxLogEntries) { _, newValue in
                navigation.setActivityLogRetention(newValue)
            }

            LabeledContent {
                Text("Always included")
                    .foregroundStyle(.secondary)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Performance and earnings")
                    Text("CPU, memory and seven-day earning history")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("With five miners, 5,000 log entries is roughly 75 minutes of history. Automatic measurements are added to exported diagnostic reports.")
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

}
