// Accounts and Mining panes of the Settings window.
import SwiftUI
import SwiftMinerCore
import SwiftMinerService
import AppKit
import UniformTypeIdentifiers

// MARK: - Account Settings

struct AccountSettingsView: View {
    let navigation: NavigationModel

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
                    Button {
                        navigation.showAddAccountSheet = true
                    } label: {
                        Label("Add Account\u{2026}", systemImage: "person.crop.circle.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
        .contentMargins(24, for: .scrollContent)
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

}

struct AccountSettingsAccountRow: View {
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

            Toggle("Mark as operator", isOn: Binding(
                get: { miner.isOperator },
                set: { newValue in
                    Task {
                        await navigation.minerManager.updateMinerOperatorStatus(minerId: miner.id, isOperator: newValue)
                    }
                }
            ))
            .toggleStyle(.checkbox)
            .font(.caption)
            .foregroundStyle(.secondary)
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

struct MiningSettingsView: View {
    @Bindable var settings: Settings
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

                Toggle("Mine IRL campaigns", isOn: $settings.mineIRLCampaigns)
                    .onChange(of: settings.mineIRLCampaigns) { _, _ in
                        Task { await refreshMiningPreferences() }
                    }
                SettingsSecondaryText("Allows Twitch IRL-category campaigns to be treated as special earn-anywhere drops. Turn this off to skip IRL campaigns.")

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

    private func refreshMiningPreferences() async {
        await navigation.refreshRunningMinerPreferences()
    }

}
