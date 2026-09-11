// Advanced pane of the Settings window.
import SwiftUI
import SwiftMinerCore
import SwiftMinerService
import AppKit
import SafariServices
import UniformTypeIdentifiers

private enum SafariQueryHashExtensionBridge {
    static let identifier = "com.swiftminer.app.SafariQueryHash"

    static func fetchEnabledState(
        completion: @escaping @MainActor @Sendable (Bool?) -> Void
    ) {
        SFSafariExtensionManager.getStateOfSafariExtension(
            withIdentifier: identifier
        ) { state, _ in
            let isEnabled = state?.isEnabled
            Task { @MainActor in
                completion(isEnabled)
            }
        }
    }

    static func showPreferences(
        completion: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        SFSafariApplication.showPreferencesForExtension(
            withIdentifier: identifier
        ) { error in
            let errorDescription = error?.localizedDescription
            Task { @MainActor in
                completion(errorDescription)
            }
        }
    }
}

// MARK: - Advanced Settings

struct AdvancedSettingsView: View {
    @Bindable var settings: Settings
    @Environment(NavigationModel.self) private var navigation
    @State private var showClientIdAlert = false
    @State private var tempClientId = ""
    @State private var backupMessage: String?
    @State private var selectedQuery: GQLQuery = .viewerDropsDashboard
    @State private var queryHashDraft = ""
    @State private var queryHashMessage: String?
    @State private var queryHashStateVersion = 0
    @State private var automaticQueryHashDiscovery = false
    @State private var safariExtensionEnabled: Bool?

    var body: some View {
        Form {
            apiConfigurationSection
            twitchCompatibilitySection
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

    private var twitchCompatibilitySection: some View {
        let store = TwitchQueryHashStore.standard
        let resolution = store.resolution(for: selectedQuery)
        _ = queryHashStateVersion

        return Section {
            Toggle("Discover query hashes in Safari", isOn: $automaticQueryHashDiscovery)
                .onChange(of: automaticQueryHashDiscovery) { _, enabled in
                    store.automaticDiscoveryEnabled = enabled
                    queryHashStateVersion &+= 1
                }

            SettingsSecondaryText("Optional. The SwiftMiner Safari extension watches only Twitch Drops request names and hashes. It never keeps cookies, tokens, variables, or responses.")

            LabeledContent("Safari extension") {
                Text(safariExtensionEnabled == true ? "Enabled" : "Not enabled")
                    .foregroundStyle(safariExtensionEnabled == true ? Color.green : Color.secondary)
            }

            DisclosureGroup("Manual compatibility override") {
                Picker("Twitch query", selection: $selectedQuery) {
                    ForEach(GQLQuery.allCases) { query in
                        Text(query.displayName).tag(query)
                    }
                }
                .onChange(of: selectedQuery) { _, _ in
                    queryHashDraft = ""
                    queryHashMessage = nil
                    queryHashStateVersion &+= 1
                }

                LabeledContent("Active source") {
                    Text(queryHashSourceLabel(resolution.source))
                        .foregroundStyle(resolution.source == .bundled ? Color.secondary : Color.green)
                }

                Text(resolution.hash)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(2)

                TextField("Paste 64-character SHA-256 hash", text: $queryHashDraft)
                    .font(.caption.monospaced())
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 8) {
                    Button("Save & Test") {
                        submitQueryHashCandidate()
                    }
                    .disabled(queryHashDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Reset to Bundled", role: .destructive) {
                        store.reset(selectedQuery)
                        queryHashDraft = ""
                        queryHashMessage = "Restored SwiftMiner's bundled hash."
                        queryHashStateVersion &+= 1
                        refreshQueryHashUsers()
                    }
                    .disabled(resolution.source == .bundled)
                }

                if let queryHashMessage {
                    SettingsSecondaryText(queryHashMessage)
                } else if resolution.source == .candidate {
                    SettingsSecondaryText("Waiting for the next Twitch request to validate this candidate.", tint: .orange)
                } else if let accepted = store.date(for: .accepted, query: selectedQuery) {
                    SettingsSecondaryText("Twitch accepted this override \(accepted.formatted(date: .abbreviated, time: .shortened)).", tint: .green)
                } else if let rejected = store.date(for: .rejected, query: selectedQuery) {
                    SettingsSecondaryText("The last candidate was rejected \(rejected.formatted(date: .abbreviated, time: .shortened)); the bundled hash was restored.", tint: .orange)
                }
            }

            HStack(spacing: 8) {
                Button("Open Twitch Drops in Safari") {
                    openTwitchDropsInSafari()
                }
                Button("Safari Extension Settings\u{2026}") {
                    openSafariExtensionSettings()
                }
            }
        } header: {
            Text("Twitch Compatibility")
        } footer: {
            Text("Runtime overrides apply without rebuilding or restarting. Unknown or rejected values never replace SwiftMiner's bundled fallback.")
        }
        .onAppear {
            automaticQueryHashDiscovery = store.automaticDiscoveryEnabled
            refreshSafariExtensionState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            queryHashStateVersion &+= 1
            refreshSafariExtensionState()
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

    private func submitQueryHashCandidate() {
        let candidate = queryHashDraft
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let store = TwitchQueryHashStore.standard
        guard store.submitCandidate(candidate, for: selectedQuery) else {
            queryHashMessage = "Enter exactly 64 hexadecimal characters."
            return
        }

        queryHashDraft = ""
        queryHashMessage = candidate == selectedQuery.bundledHash
            ? "That is already SwiftMiner's bundled hash."
            : nil
        queryHashStateVersion &+= 1
        refreshQueryHashUsers()
    }

    private func refreshQueryHashUsers() {
        Task {
            await navigation.minerManager.forceRefreshAllMiners()
            _ = navigation.refreshDropsInBackground(force: true)
            queryHashStateVersion &+= 1
        }
    }

    private func queryHashSourceLabel(_ source: TwitchQueryHashSource) -> String {
        switch source {
        case .bundled: return "Bundled fallback"
        case .override: return "Validated override"
        case .candidate: return "Testing candidate"
        }
    }

    private func openSafariExtensionSettings() {
        SafariQueryHashExtensionBridge.showPreferences { errorDescription in
            queryHashMessage = errorDescription.map {
                "Safari could not open extension settings: \($0)"
            }
        }
    }

    private func refreshSafariExtensionState() {
        SafariQueryHashExtensionBridge.fetchEnabledState { isEnabled in
            safariExtensionEnabled = isEnabled
        }
    }

    private func openTwitchDropsInSafari() {
        guard let url = URL(string: "https://www.twitch.tv/drops/campaigns") else { return }
        guard let safari = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Safari"
        ) else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: safari,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

}
