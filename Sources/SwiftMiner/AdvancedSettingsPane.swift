// Advanced pane of the Settings window and its resource usage popover.
import SwiftUI
import SwiftMinerCore
import SwiftMinerService
import TipKit
import AppKit
import UniformTypeIdentifiers

// MARK: - Advanced Settings

/// Small popup summarising SwiftMiner's own CPU/memory usage while the
/// resource-usage diagnostic is enabled. Reads the live snapshot from the
/// observable monitor, so it updates in place as new samples arrive.
struct ResourceUsagePopover: View {
    let monitor: ResourceUsageMonitor

    var body: some View {
        let snapshot = monitor.snapshot
        VStack(alignment: .leading, spacing: 12) {
            Text("Resource Usage")
                .font(.headline)

            if snapshot.sampleCount == 0 {
                Text(monitor.isRunning
                    ? "Collecting the first sample\u{2026}"
                    : "Enable \u{201C}Monitor resource usage\u{201D} to start collecting.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        Color.clear.frame(width: 0, height: 0)
                        Text("CPU").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text("Memory").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    usageRow("Current", cpu: snapshot.currentCPUPercent, memory: snapshot.currentMemoryBytes)
                    usageRow("Average", cpu: snapshot.averageCPUPercent, memory: snapshot.averageMemoryBytes)
                    usageRow("Peak", cpu: snapshot.peakCPUPercent, memory: snapshot.peakMemoryBytes)
                }

                Text("\(snapshot.sampleCount) sample\(snapshot.sampleCount == 1 ? "" : "s")\(durationSuffix(from: snapshot.startedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("Reset") { monitor.reset() }
                    .disabled(snapshot.sampleCount == 0)
                Button("Export CSV\u{2026}") { exportCSV() }
                    .disabled(snapshot.sampleCount == 0)
                Spacer()
            }

            Text("CPU is relative to one core.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 300)
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "SwiftMiner Resource Usage.csv"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? monitor.csvRepresentation().data(using: .utf8)?.write(to: url, options: .atomic)
    }

    private func usageRow(_ label: String, cpu: Double, memory: UInt64) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(Self.cpuText(cpu)).monospacedDigit()
            Text(Self.memoryText(memory)).monospacedDigit()
        }
    }

    private func durationSuffix(from start: Date?) -> String {
        guard let start else { return "" }
        let seconds = Int(Date().timeIntervalSince(start))
        if seconds < 60 { return " over \(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return " over \(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? " over \(hours)h" : " over \(hours)h \(remainder)m"
    }

    static func cpuText(_ percent: Double) -> String {
        String(format: "%.1f%%", percent)
    }

    static func memoryText(_ bytes: UInt64) -> String {
        let megabytes = Double(bytes) / (1024 * 1024)
        if megabytes >= 1024 {
            return String(format: "%.2f GB", megabytes / 1024)
        }
        return String(format: "%.0f MB", megabytes)
    }
}

struct AdvancedSettingsView: View {
    @Bindable var settings: Settings
    @Environment(NavigationModel.self) private var navigation
    @State private var showResetConfirmation = false
    @State private var showDropCacheConfirmation = false
    @State private var showClientIdAlert = false
    @State private var tempClientId = ""
    @State private var backupMessage: String?
    @State private var showResourceUsage = false

    var body: some View {
        Form {
            apiConfigurationSection
            backupSection
            maintenanceSection
            diagnosticsSection

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

    private var diagnosticsSection: some View {
        Section {
            Toggle("Monitor resource usage", isOn: $settings.monitorResourceUsage)
                .onChange(of: settings.monitorResourceUsage) { _, newValue in
                    navigation.setResourceUsageMonitoring(enabled: newValue)
                }

            Button("Resource Usage\u{2026}") {
                showResourceUsage = true
            }
            .buttonStyle(.link)
            .popover(isPresented: $showResourceUsage, arrowEdge: .bottom) {
                ResourceUsagePopover(monitor: navigation.resourceUsageMonitor)
            }

            SettingsSecondaryText("Samples SwiftMiner's own CPU and memory every 15 seconds so you can see how much it uses. Off by default and nothing is sampled while off — there is no overhead for normal use.")
        } header: {
            Text("Diagnostics")
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
