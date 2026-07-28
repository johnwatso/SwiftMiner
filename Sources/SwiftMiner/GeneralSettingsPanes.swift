// General, Appearance, and Updates panes of the Settings window.
import SwiftUI
import SwiftMinerCore
import SwiftMinerService
import TipKit
import AppKit
import UniformTypeIdentifiers

// MARK: - General Settings

struct GeneralSettingsView: View {
    @Bindable var settings: Settings
    @EnvironmentObject private var updater: AppUpdater
    @Environment(NavigationModel.self) private var navigation
    @State private var loginItemSettings = LoginItemSettings()

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
}

// MARK: - Appearance Settings

struct AppearanceSettingsView: View {
    @Bindable var settings: Settings
    @Environment(NavigationModel.self) private var navigation
    @State private var artworkRefreshState: ArtworkRefreshState = .idle

    private enum ArtworkRefreshState: Equatable {
        case idle
        case refreshing
        case finished
    }

    var body: some View {
        Form {
            Section {
                Toggle("Use Steam artwork for game images", isOn: $settings.preferSteamArtwork)
                    .minerTip(SteamArtworkTip())
                SettingsSecondaryText("Falls back to Twitch artwork when a game is not found on Steam.")

                LabeledContent("Cached Artwork") {
                    HStack(spacing: 8) {
                        Button("Clear and Redownload") {
                            Task { await refreshArtwork() }
                        }
                        .disabled(artworkRefreshState == .refreshing)

                        switch artworkRefreshState {
                        case .refreshing:
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("Redownloading artwork")
                        case .finished:
                            // Transient confirmation rather than an alert: the action
                            // is recoverable and interrupting the user to acknowledge
                            // a cache refresh would be disproportionate.
                            Label("Updated", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.callout)
                                .transition(.opacity)
                        case .idle:
                            EmptyView()
                        }
                    }
                }
                SettingsSecondaryText("Discards downloaded game images and fetches them again. Artwork you uploaded yourself is kept.")
            } header: {
                Text("Artwork")
            }

            Section {
                Picker("Take pictures from", selection: $settings.minerAvatarSource) {
                    ForEach(MinerAvatarSource.allCases) { source in
                        Text(source.label).tag(source)
                    }
                }
                .frame(maxWidth: 320)
                SettingsSecondaryText(settings.minerAvatarSource.detail)
            } header: {
                Text("Miner Pictures")
            }

            Section {
                Toggle("Show in-app tips", isOn: $settings.tipsEnabled)
                SettingsSecondaryText("Show occasional hints for features like game rules and filtering drops.")
            } header: {
                Text("Tips")
            }

            Section {
                Toggle("Show icons in Activity Log", isOn: $settings.showActivityLogIcons)
                SettingsSecondaryText("Display category icons next to Activity Log rows.")
            } header: {
                Text("Activity Log")
            }

            Section {
                Toggle("Use simpler visual effects", isOn: simplerVisualEffectsBinding)
                SettingsSecondaryText("Turns off row animations and animated or multi-colour status badges.")
            } header: {
                Text("Motion & Status")
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .padding(.top, 10)
    }

    /// Clears every derived artwork cache and pulls fresh images.
    ///
    /// Order matters: the stale preference links go first, so nothing re-reads a
    /// dead cache path while the images are being refetched.
    private func refreshArtwork() async {
        withAnimation { artworkRefreshState = .refreshing }

        settings.clearCachedArtworkLinks()

        let coordinator = navigation.minerManager.dataCoordinator
        await CampaignArtworkCache.shared.clearCache()
        await coordinator.clearSteamArtworkCache()
        await coordinator.refreshAll()
        _ = await coordinator.allCampaigns(preferSteamArtwork: settings.preferSteamArtwork)
        NotificationCenter.default.post(name: .dropsCampaignsDidUpdate, object: coordinator)

        withAnimation { artworkRefreshState = .finished }

        // Let the confirmation stand long enough to read, then return the row to
        // rest so it doesn't imply a permanent state.
        try? await Task.sleep(for: .seconds(3))
        withAnimation { artworkRefreshState = .idle }
    }

    private var simplerVisualEffectsBinding: Binding<Bool> {
        Binding {
            !settings.animateActivityLogRows || !settings.animatedStatusIcons || !settings.coloredStatusIcons
        } set: { useSimplerEffects in
            settings.animateActivityLogRows = !useSimplerEffects
            settings.animatedStatusIcons = !useSimplerEffects
            settings.coloredStatusIcons = !useSimplerEffects
        }
    }
}

// MARK: - Updates Settings

struct UpdatesSettingsView: View {
    @EnvironmentObject private var updater: AppUpdater
    @Bindable private var settings = Settings.shared

    private var updateInstallPolicyDescription: String {
        switch settings.autoUpdateInstallPolicy {
        case .immediate:
            return "Updates install (and relaunch SwiftMiner) as soon as they finish downloading."
        case .whenIdle:
            return "Updates download silently anytime, then install the moment no miner is actively earning progress. Stalled or errored miners don't delay it — an update may be the fix. Installs within 24 hours regardless."
        case .scheduled:
            return "Updates download silently anytime, but the install and relaunch wait until \(updateHourLabel(settings.autoUpdateInstallHour))."
        }
    }

    private func updateHourLabel(_ hour: Int) -> String {
        let date = Calendar.current.date(from: DateComponents(hour: hour, minute: 0)) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        Form {
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

                if updater.automaticallyDownloadsUpdates {
                    Picker("Install timing", selection: $settings.autoUpdateInstallPolicy) {
                        ForEach(AutoUpdateInstallPolicy.allCases) { policy in
                            Text(policy.label).tag(policy)
                        }
                    }
                    .frame(maxWidth: 320)
                    if settings.autoUpdateInstallPolicy == .scheduled {
                        Picker("Install time", selection: $settings.autoUpdateInstallHour) {
                            ForEach(0..<24, id: \.self) { hour in
                                Text(updateHourLabel(hour)).tag(hour)
                            }
                        }
                        .frame(maxWidth: 220)
                    }
                    SettingsSecondaryText(updateInstallPolicyDescription)
                }

                Button("Check for Updates...") {
                    updater.checkForUpdates()
                }
                .buttonStyle(.bordered)
                .disabled(!updater.canCheckForUpdates)

                VStack(alignment: .leading, spacing: 4) {
                    Text("If automatic updates fail, you can download the latest version manually from:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Link("GitHub Releases", destination: URL(string: "https://github.com/johnwatso/SwiftMiner/releases")!)
                        .font(.caption)
                        .underline()
                }
                .padding(.leading, 2)
                .padding(.top, 2)

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
