// Accounts and Mining panes of the Settings window.
import SwiftUI
import SwiftMinerCore
import SwiftMinerService
import AppKit
import UniformTypeIdentifiers

// MARK: - Account Settings

/// Column widths shared by the account list's header captions and its rows, so
/// the two stay aligned without a Grid.
private enum AccountRowMetrics {
    static let avatar: CGFloat = 40
    static let operatorColumn: CGFloat = 62
    /// Narrow because the source control is two brand marks, not two words.
    static let pictureColumn: CGFloat = 76
    static let removeColumn: CGFloat = 24
    static let spacing: CGFloat = 12
    static let horizontalPadding: CGFloat = 14
}

/// Twitch and Discord drawn with their own marks, the way the Integrations pane
/// already identifies them — an unselected mark is greyed rather than hidden so
/// the pair still reads as a choice.
private struct AccountSourceMark: View {
    let source: AccountAvatarSource
    var isMuted = false

    var body: some View {
        Group {
            switch source {
            case .twitch: TwitchLogo()
            case .discord: DiscordLogo()
            }
        }
        .grayscale(isMuted ? 1 : 0)
        .opacity(isMuted ? 0.55 : 1)
    }
}

struct AccountSettingsView: View {
    let navigation: NavigationModel
    private var twitchAvatars: TwitchAvatarStore { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                accountList
            }
        }
        .contentMargins(24, for: .scrollContent)
        .task(id: navigation.minerManager.miners.map(\.id)) {
            await refreshAvatarPreviews()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Accounts")
                .font(.headline)

            Spacer(minLength: 12)

            Button {
                navigation.showAddAccountSheet = true
            } label: {
                Label("Add Account\u{2026}", systemImage: "person.crop.circle.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
    }

    @ViewBuilder
    private var accountList: some View {
        if navigation.minerManager.miners.isEmpty {
            SettingsSecondaryText("No accounts connected yet. Add or import an account to start mining.")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .tahoeCard()
        } else {
            VStack(spacing: 0) {
                columnCaptions

                ForEach(navigation.minerManager.miners) { miner in
                    Divider()
                    AccountSettingsAccountRow(miner: miner, navigation: navigation)
                }
            }
            // Clipped before the card's own background so the tinted caption
            // strip follows the card's rounded top corners.
            .clipShape(RoundedRectangle(cornerRadius: TahoeMetrics.card, style: .continuous))
            .tahoeCard()
        }
    }

    /// Captions do the labelling the rows themselves no longer repeat, which is
    /// what lets each row collapse to a single line — and what lets the picture
    /// column be two brand marks with no words next to them.
    private var columnCaptions: some View {
        HStack(spacing: AccountRowMetrics.spacing) {
            Text("Account")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, AccountRowMetrics.avatar + AccountRowMetrics.spacing)

            Text("Operator")
                .frame(width: AccountRowMetrics.operatorColumn, alignment: .center)

            Text("Picture")
                .frame(width: AccountRowMetrics.pictureColumn, alignment: .center)

            Color.clear
                .frame(width: AccountRowMetrics.removeColumn, height: 1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, AccountRowMetrics.horizontalPadding)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.3))
    }

    private func refreshAvatarPreviews() async {
        let miners = navigation.minerManager.miners
        twitchAvatars.pruneEntries(keepingAccountIds: Set(miners.map(\.accountId)))
        guard !miners.isEmpty else { return }

        // Discord is optional and can take a few seconds to time out. Let its
        // best-effort refresh run independently so every account can resolve
        // its Twitch picture right away, including Discord selections that need
        // to use Twitch as their fallback.
        if Settings.shared.swiftBotEnabled,
           miners.contains(where: { $0.ownerDiscordId != nil }) {
            Task { await navigation.refreshDiscordDisplayNames() }
        }

        await twitchAvatars.refreshIfNeeded(miners: miners, manager: navigation.minerManager)
    }
}

struct AccountSettingsAccountRow: View {
    let miner: MinerManager.ManagedMiner
    let navigation: NavigationModel

    @State private var nickname: String
    @State private var isRemoveHovered = false
    @State private var isRowHovered = false
    @FocusState private var isNicknameFocused: Bool

    init(miner: MinerManager.ManagedMiner, navigation: NavigationModel) {
        self.miner = miner
        self.navigation = navigation
        self._nickname = State(initialValue: miner.nickname ?? "")
    }

    var body: some View {
        HStack(spacing: AccountRowMetrics.spacing) {
            profilePicture

            VStack(alignment: .leading, spacing: 3) {
                Text(miner.username)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                TextField("Nickname", text: $nickname)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($isNicknameFocused)
                    .onSubmit { saveNickname() }
                    .onChange(of: isNicknameFocused) { _, focused in
                        if !focused {
                            saveNickname()
                        }
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            operatorToggle

            profilePictureSourcePicker

            removeButton
        }
        .padding(.horizontal, AccountRowMetrics.horizontalPadding)
        .padding(.vertical, 9)
        .background(isRowHovered ? Color.primary.opacity(0.04) : .clear)
        .onHover { isRowHovered = $0 }
        .onChange(of: miner.nickname) { _, newValue in
            nickname = newValue ?? ""
        }
    }

    private var operatorToggle: some View {
        Toggle("Mark as operator", isOn: Binding(
            get: { miner.isOperator },
            set: { newValue in
                Task {
                    await navigation.minerManager.updateMinerOperatorStatus(minerId: miner.id, isOperator: newValue)
                }
            }
        ))
        .toggleStyle(.switch)
        .controlSize(.small)
        .labelsHidden()
        .frame(width: AccountRowMetrics.operatorColumn, alignment: .center)
        .help("Mark \(miner.username) as an operator")
        .accessibilityLabel("Mark \(miner.username) as an operator")
    }

    private var settings: Settings { .shared }

    private var twitchAvatars: TwitchAvatarStore { .shared }

    private var avatarSource: AccountAvatarSource {
        settings.avatarSource(forAccountId: miner.accountId)
    }

    private var twitchAvatarURL: URL? {
        twitchAvatars.url(forAccountId: miner.accountId)
    }

    private var discordAvatarURL: URL? {
        guard let discordId = miner.ownerDiscordId else { return nil }
        return navigation.discordUsersById[discordId]?.avatarURL
    }

    private var avatarURL: URL? {
        avatarSource.resolve(discord: discordAvatarURL, twitch: twitchAvatarURL)
    }

    /// Whether a Discord picture is reachable at all: the account has to be linked
    /// and SwiftBot has to be on for `refreshDiscordDisplayNames` to resolve one.
    private var canUseDiscord: Bool {
        miner.ownerDiscordId != nil && settings.swiftBotEnabled
    }

    /// The service the drawn picture actually came from, which is not always the
    /// selected one — the badge reports this rather than the selection so it never
    /// claims Discord over a Twitch image.
    private var resolvedSource: AccountAvatarSource? {
        guard let avatarURL else { return nil }
        return avatarURL == MinerAvatarURL.secure(discordAvatarURL) ? .discord : .twitch
    }

    private var profilePicture: some View {
        CachedAvatarImage(url: avatarURL) {
            initialAvatar
        }
        .frame(width: AccountRowMetrics.avatar, height: AccountRowMetrics.avatar)
        .clipShape(Circle())
        .overlay(alignment: .bottomTrailing) {
            if let resolvedSource {
                profilePictureSourceBadge(for: resolvedSource)
                    .offset(x: 2, y: 2)
            }
        }
        .accessibilityLabel(avatarAccessibilityLabel)
    }

    private var initialAvatar: some View {
        Circle()
            .fill(.tint)
            .overlay {
                Text(String(miner.username.trimmingCharacters(in: .whitespacesAndNewlines).first ?? "?").uppercased())
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
    }

    /// The service mark on its own light disc rather than knocked out in white,
    /// so both brands keep their own colour at 9pt.
    private func profilePictureSourceBadge(for source: AccountAvatarSource) -> some View {
        AccountSourceMark(source: source)
            .frame(width: 9, height: 9)
            .frame(width: 16, height: 16)
            .background(.background, in: Circle())
            .overlay {
                Circle().strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.16), radius: 1, y: 0.5)
            .accessibilityHidden(true)
    }

    private var avatarAccessibilityLabel: String {
        guard let resolvedSource else { return "No profile picture" }
        if resolvedSource != avatarSource {
            return "\(avatarSource.label) profile picture selected; using \(resolvedSource.label) fallback"
        }
        return "\(resolvedSource.label) profile picture"
    }

    /// Hand-rolled rather than a segmented `Picker`: a segmented picker only
    /// renders `Text`/`Image` content, and these segments are the services' own
    /// vector marks.
    private var profilePictureSourcePicker: some View {
        HStack(spacing: 2) {
            ForEach(AccountAvatarSource.allCases) { source in
                sourceSegment(source)
            }
        }
        .padding(2)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
        }
        .frame(width: AccountRowMetrics.pictureColumn)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Profile picture source for \(miner.username)")
    }

    private func sourceSegment(_ source: AccountAvatarSource) -> some View {
        let isSelected = avatarSource == source
        // Only the unreachable segment dims. Dimming the whole control would
        // also grey out Twitch, which is perfectly usable on an unlinked account.
        let isAvailable = source != .discord || canUseDiscord
        return Button {
            guard !isSelected else { return }
            settings.setAvatarSource(source, forAccountId: miner.accountId)
            Task { await refreshAvatarPreview() }
        } label: {
            AccountSourceMark(source: source, isMuted: !isSelected)
                .frame(width: 14, height: 14)
                .frame(maxWidth: .infinity, minHeight: 19)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .opacity(isAvailable ? 1 : 0.3)
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                .opacity(isSelected ? 1 : 0)
        }
        .accessibilityLabel(source.label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help(isAvailable
              ? source.detail
              : "Link this account to a Discord user and enable SwiftBot to use a Discord picture.")
    }

    private var removeButton: some View {
        Button {
            Task { await navigation.minerManager.removeAccount(minerId: miner.id) }
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 12, weight: .medium))
                .frame(width: AccountRowMetrics.removeColumn, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(isRemoveHovered ? .red : .secondary)
        .onHover { isRemoveHovered = $0 }
        .help("Remove account")
        .accessibilityLabel("Remove \(miner.username)")
    }

    private func saveNickname() {
        let normalized = Account.normalizedNickname(nickname)
        guard normalized != miner.nickname else { return }

        Task {
            await navigation.minerManager.updateMinerNickname(minerId: miner.id, nickname: normalized)
        }
    }

    private func refreshAvatarPreview() async {
        if canUseDiscord {
            // Either selection can end up drawing the Discord picture, so refresh
            // it regardless — detached, because a slow Discord round trip must not
            // hold up the Twitch lookup shown in the meantime.
            Task { await navigation.refreshDiscordDisplayNames() }
        }
        await twitchAvatars.refreshIfNeeded(miners: [miner], manager: navigation.minerManager)
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
