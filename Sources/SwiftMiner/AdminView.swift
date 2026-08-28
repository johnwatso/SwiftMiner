import AppKit
import SwiftUI
import SwiftMinerCore
import SwiftMinerService

/// Discord oversight panel — tabular view of every miner with link/unlink/DM
/// controls and an inline detail panel for the selected row.
struct AdminView: View {
    @Environment(NavigationModel.self) private var navigation
    @State private var selectedMinerId: String?
    @State private var linkIntent: LinkIntent?
    @State private var discordNamesById: [String: String] = [:]
    @State private var discordUsersById: [String: SwiftBotDiscordUser] = [:]
    @State private var dmSummariesById: [String: DMLogStore.Summary] = [:]

    struct LinkIntent: Identifiable {
        let id = UUID()
        let miner: MinerManager.ManagedMiner
        let isRelink: Bool
    }

    private var miners: [MinerManager.ManagedMiner] { navigation.minerManager.miners }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                tableHeader
                rowsList
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .navigationTitle("Discord")
        .sheet(item: $linkIntent) { intent in
            LinkMinerSheet(miner: intent.miner, isRelink: intent.isRelink)
        }
        .task { await refreshAll() }
    }

    // MARK: - Header

    private var header: some View {
        Text("Manage Discord links, DM delivery and account health for all Twitch miners.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    // MARK: - Table

    private var tableHeader: some View {
        HStack(spacing: 12) {
            columnLabel("Discord").frame(maxWidth: .infinity, alignment: .leading)
            columnLabel("Miner (Twitch)").frame(maxWidth: .infinity, alignment: .leading)
            columnLabel("Status").frame(width: 140, alignment: .leading)
            columnLabel("Last DM").frame(width: 110, alignment: .leading)
            columnLabel("DM History").frame(width: 90, alignment: .leading)
            columnLabel("Actions").frame(width: 60, alignment: .center)
        }
        .padding(.horizontal, 8)
    }

    private func columnLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private var rowsList: some View {
        LazyVStack(spacing: 0) {
            if miners.isEmpty {
                Text("No miners yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(miners) { miner in
                    MinerRow(
                        miner: miner,
                        isSelected: selectedMinerId == miner.id,
                        discordUser: miner.ownerDiscordId.flatMap { discordUsersById[$0] },
                        discordName: miner.ownerDiscordId.flatMap { discordNamesById[$0] },
                        summary: miner.ownerDiscordId.flatMap { dmSummariesById[$0] },
                        onTap: { toggleSelection(miner.id) },
                        onLink: { linkIntent = LinkIntent(miner: miner, isRelink: false) },
                        onRelink: { linkIntent = LinkIntent(miner: miner, isRelink: true) },
                        onFix: { Task { await emitReauth(for: miner) } },
                        onSummaryChanged: { id, summary in
                            dmSummariesById[id] = summary
                        }
                    )
                    if selectedMinerId == miner.id {
                        DetailPanel(
                            miner: miner,
                            discordUser: miner.ownerDiscordId.flatMap { discordUsersById[$0] },
                            discordName: miner.ownerDiscordId.flatMap { discordNamesById[$0] },
                            onRelink: {
                                let isRelink = miner.ownerDiscordId != nil
                                linkIntent = LinkIntent(miner: miner, isRelink: isRelink)
                            },
                            onResendLast: {
                                Task { await resendLast(for: miner) }
                            }
                        )
                        .transition(.opacity)
                    }
                    Divider()
                }
            }
        }
    }

    private func toggleSelection(_ id: String) {
        withAnimation(.easeInOut(duration: 0.12)) {
            selectedMinerId = (selectedMinerId == id) ? nil : id
        }
    }

    private func emitReauth(for miner: MinerManager.ManagedMiner) async {
        guard let discordId = miner.ownerDiscordId else { return }
        await navigation.eventEmitter.emitUserReauthRequested(
            discordUserId: discordId,
            twitchAccountId: miner.accountId
        )
    }

    private func resendLast(for miner: MinerManager.ManagedMiner) async {
        guard let discordId = miner.ownerDiscordId else { return }
        guard let request = await navigation.dmLogStore.mostRecentProductionRequest(forDiscordId: discordId) else { return }
        _ = await navigation.swiftBotConnectionService.sendEventDM(to: discordId, request: request)
        let summaries = await navigation.dmLogStore.summaries(forDiscordIds: [discordId])
        if let s = summaries[discordId] {
            dmSummariesById[discordId] = s
        }
    }

    private func refreshAll() async {
        await navigation.refreshDiscordDisplayNames()
        discordNamesById = navigation.discordDisplayNamesById
        discordUsersById = navigation.discordUsersById
        let ids = miners.compactMap(\.ownerDiscordId)
        dmSummariesById = await navigation.dmLogStore.summaries(forDiscordIds: ids)
    }
}

// MARK: - Status

private enum LinkStatus {
    case linked
    case notLinked
    case needsAttention

    var label: String {
        switch self {
        case .linked: return "Linked"
        case .notLinked: return "Not Linked"
        case .needsAttention: return "Needs Attention"
        }
    }

    var color: Color {
        switch self {
        case .linked: return .green
        case .notLinked: return .secondary
        case .needsAttention: return .orange
        }
    }

    var subLabel: String? {
        switch self {
        case .linked: return "Healthy"
        case .notLinked: return nil
        case .needsAttention: return "Auth Expired"
        }
    }

    static func resolve(_ miner: MinerManager.ManagedMiner) -> LinkStatus {
        guard miner.ownerDiscordId != nil else { return .notLinked }
        if miner.needsAuth { return .needsAttention }
        return .linked
    }

    func issueDescription(for miner: MinerManager.ManagedMiner) -> String? {
        switch self {
        case .linked: return nil
        case .notLinked: return "This Twitch account has no Discord owner."
        case .needsAttention: return "Twitch authentication has expired or been revoked. Re-link required."
        }
    }
}

// MARK: - Row

private struct MinerRow: View {
    let miner: MinerManager.ManagedMiner
    let isSelected: Bool
    let discordUser: SwiftBotDiscordUser?
    let discordName: String?
    let summary: DMLogStore.Summary?
    let onTap: () -> Void
    let onLink: () -> Void
    let onRelink: () -> Void
    let onFix: () -> Void
    let onSummaryChanged: (String, DMLogStore.Summary) -> Void

    @Environment(NavigationModel.self) private var navigation
    @State private var showUnlinkConfirmation = false
    @State private var dmResult: Bool? = nil
    @State private var dmResultLabel: String? = nil
    @State private var hasReplayableMessage = false

    var body: some View {
        let status = LinkStatus.resolve(miner)

        HStack(spacing: 12) {
            // Discord
            DiscordPersonView(
                name: discordDisplayName,
                username: discordUsername,
                avatarURL: discordUser?.avatarURL,
                isLinked: miner.ownerDiscordId != nil
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            // Miner (Twitch)
            VStack(alignment: .leading, spacing: 1) {
                Text(miner.displayName)
                    .font(.system(size: 13, weight: .medium))
                Text(miner.username)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Status
            VStack(alignment: .leading, spacing: 2) {
                Text(status.label)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(status.color.opacity(0.15))
                    )
                    .foregroundStyle(status.color)
                if let sub = status.subLabel {
                    Text(sub)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 140, alignment: .leading)

            // Last DM
            Group {
                if let date = summary?.lastSentAt {
                    Text(relativeTimeString(for: date))
                        .font(.caption)
                } else {
                    Text("—")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 110, alignment: .leading)

            // DM history count
            HStack(spacing: 4) {
                if let count = summary?.count, count > 0 {
                    Image(systemName: "bubble.left")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(count)")
                        .font(.caption.monospacedDigit())
                } else {
                    Text("—")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 90, alignment: .leading)

            // Actions
            actionMenu(for: status)
                .frame(width: 60, alignment: .center)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .confirmationDialog(
            "Unlink \(miner.displayName)?",
            isPresented: $showUnlinkConfirmation,
            titleVisibility: .visible
        ) {
            Button("Unlink", role: .destructive) {
                Task { await performUnlink() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The Discord account will no longer be linked to this Twitch account.")
        }
        .task(id: miner.ownerDiscordId) { await refreshReplayableState() }
    }

    private var discordDisplayName: String {
        guard miner.ownerDiscordId != nil else { return "Not linked" }
        return discordName?.nilIfBlank
            ?? discordUser?.displayName.nilIfBlank
            ?? discordUser?.username?.nilIfBlank
            ?? "Discord user"
    }

    private var discordUsername: String? {
        guard miner.ownerDiscordId != nil else { return nil }
        return discordUser?.username?.nilIfBlank
    }

    @ViewBuilder
    private func actionMenu(for status: LinkStatus) -> some View {
        Menu {
            switch status {
            case .notLinked:
                Button(action: onLink) {
                    Label("Link", systemImage: "personalhotspot")
                }
            case .needsAttention:
                Button(action: onFix) {
                    Label("Fix connection", systemImage: "wrench.and.screwdriver")
                }
                Divider()
                Button(action: onRelink) {
                    Label("Re-link", systemImage: "personalhotspot")
                }
                Button(role: .destructive) {
                    showUnlinkConfirmation = true
                } label: {
                    Label(
                        "Unlink",
                        systemImage: SystemSymbolCompatibility.resolvedName(for: "personalhotspot.slash")
                    )
                }
            case .linked:
                Button {
                    Task { await sendOneOff(messageType: .welcome) }
                } label: {
                    Label("Send welcome message", systemImage: "checkmark.message")
                }
                Button {
                    Task { await resendLastMessage() }
                } label: {
                    Label("Re-send last message", systemImage: "ellipsis.message")
                }
                .disabled(!hasReplayableMessage)
                Divider()
                Button(action: onRelink) {
                    Label("Re-link", systemImage: "personalhotspot")
                }
                Button(role: .destructive) {
                    showUnlinkConfirmation = true
                } label: {
                    Label(
                        "Unlink",
                        systemImage: SystemSymbolCompatibility.resolvedName(for: "personalhotspot.slash")
                    )
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func sendOneOff(messageType: SwiftBotDMMessageType) async {
        guard let discordId = miner.ownerDiscordId else { return }
        let priorityGames = await MainActor.run { Settings.shared.priorityGames }
        let request = SwiftBotDMRequest(
            messageType: messageType,
            debug: false,
            twitchUsername: miner.username,
            priorityGames: priorityGames
        )
        let ok = await navigation.swiftBotConnectionService.sendEventDM(to: discordId, request: request)
        dmResult = ok
        dmResultLabel = "\(messageType.displayName) DM"
        await refreshReplayableState()
        await refreshSummary()
    }

    private func resendLastMessage() async {
        guard let discordId = miner.ownerDiscordId else { return }
        guard let lastRequest = await navigation.dmLogStore.mostRecentProductionRequest(forDiscordId: discordId) else {
            dmResult = false
            dmResultLabel = "Re-send"
            return
        }
        let ok = await navigation.swiftBotConnectionService.sendEventDM(to: discordId, request: lastRequest)
        dmResult = ok
        dmResultLabel = "Re-send (\(lastRequest.messageType.displayName))"
        await refreshSummary()
    }

    private func refreshReplayableState() async {
        guard let discordId = miner.ownerDiscordId else {
            hasReplayableMessage = false
            return
        }
        let last = await navigation.dmLogStore.mostRecentProductionRequest(forDiscordId: discordId)
        hasReplayableMessage = (last != nil)
    }

    private func refreshSummary() async {
        guard let discordId = miner.ownerDiscordId else { return }
        let summaries = await navigation.dmLogStore.summaries(forDiscordIds: [discordId])
        if let s = summaries[discordId] {
            onSummaryChanged(discordId, s)
        }
    }

    private func performUnlink() async {
        let result = await navigation.adminLinkingService.unlinkAccount(
            twitchAccountId: miner.accountId,
            operatorIdentity: .localAdmin
        )
        if case .unlinked = result {
            navigation.minerManager.setOwnerDiscordId(forAccountId: miner.accountId, to: nil)
        }
    }
}

private struct DiscordPersonView: View {
    let name: String
    let username: String?
    let avatarURL: URL?
    let isLinked: Bool

    var body: some View {
        HStack(spacing: 9) {
            avatar
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 13, weight: isLinked ? .medium : .regular))
                    .foregroundStyle(isLinked ? .primary : .secondary)
                    .lineLimit(1)
                if let username, isLinked, username != name {
                    Text(username)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if let avatarURL {
            CachedAvatarImage(url: avatarURL) {
                fallbackAvatar
            }
            .frame(width: 24, height: 24)
            .clipShape(Circle())
        } else {
            fallbackAvatar
                .frame(width: 24, height: 24)
        }
    }

    private var fallbackAvatar: some View {
        DiscordLogoFallback()
    }
}

private struct DiscordLogoFallback: View {
    private static let officialMark = Bundle.main
        .url(forResource: "DiscordMarkOfficial", withExtension: "svg")
        .flatMap(NSImage.init(contentsOf:))

    private let discordBlurple = Color(red: 0.345, green: 0.396, blue: 0.949)

    var body: some View {
        Circle()
            .fill(discordBlurple)
            .overlay {
                if let officialMark = Self.officialMark {
                    Image(nsImage: officialMark)
                        .resizable()
                        .scaledToFit()
                        .padding(5)
                } else {
                    Image(systemName: "message.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .accessibilityLabel("Discord")
    }
}

// MARK: - Inline detail panel

private struct DetailPanel: View {
    let miner: MinerManager.ManagedMiner
    let discordUser: SwiftBotDiscordUser?
    let discordName: String?
    let onRelink: () -> Void
    let onResendLast: () -> Void

    @Environment(NavigationModel.self) private var navigation
    @State private var entries: [DMLogStore.Entry] = []
    @State private var lastRequest: SwiftBotDMRequest?
    @State private var isLoading = true
    @State private var showAllHistory = false

    var body: some View {
        let status = LinkStatus.resolve(miner)
        HStack(alignment: .top, spacing: 24) {
            if let issue = status.issueDescription(for: miner) {
                issueColumn(issue: issue, status: status)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            lastDMColumn
                .frame(maxWidth: .infinity, alignment: .topLeading)
            historyColumn
                .frame(maxWidth: .infinity, alignment: .topLeading)
            infoColumn
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .task(id: miner.ownerDiscordId) { await load() }
        .sheet(isPresented: $showAllHistory) {
            AllHistorySheet(
                minerName: miner.displayName,
                entries: visibleEntries
            )
        }
    }

    @ViewBuilder
    private func issueColumn(issue: String, status: LinkStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text("Issue")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.orange)
            }
            Text(issue)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)

            if status == .needsAttention {
                Button(action: onRelink) {
                    Label("Re-link Discord Account", systemImage: "link")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 4)
            } else if status == .notLinked {
                Button(action: onRelink) {
                    Label("Link Discord Account", systemImage: "link")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 4)
            }
        }
    }

    private var lastDMColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Last DM")
            if let entry = entries.first(where: { !$0.isDebug }) {
                Text(messageTitle(for: entry, request: lastRequest))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = messageDetail(for: entry, request: lastRequest) {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Sent \(relativeTimeString(for: entry.sentAt)) • \(absoluteTimeString(for: entry.sentAt))")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)

                Button(action: onResendLast) {
                    Label("Resend Last DM", systemImage: "paperplane")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(lastRequest == nil)
                .padding(.top, 4)
            } else {
                Text("No DMs sent yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var historyColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                sectionHeader("DM History (\(visibleEntries.count))")
                Spacer()
                if visibleEntries.count > 5 {
                    Button("View All") { showAllHistory = true }
                        .font(.system(size: 11))
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
            }
            if isLoading {
                Text("Loading…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else if visibleEntries.isEmpty {
                Text("No DMs.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(visibleEntries.prefix(5).enumerated()), id: \.offset) { _, entry in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(relativeTimeString(for: entry.sentAt))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(minWidth: 70, alignment: .leading)
                            Text(displayLabel(for: entry.messageType))
                                .font(.system(size: 12))
                                .lineLimit(1)
                            if entry.isDebug {
                                Text("TEST")
                                    .font(.system(size: 8, weight: .semibold))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.orange.opacity(0.18), in: Capsule())
                                    .foregroundStyle(.orange)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private var infoColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Info")
            infoRow("Twitch", miner.username)
            if miner.ownerDiscordId != nil {
                infoRow("Discord", discordDisplayName)
                infoRow("Discord username", discordUser?.username?.nilIfBlank ?? "Unavailable")
            } else {
                Text("Not linked to a Discord account.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var discordDisplayName: String {
        discordName?.nilIfBlank
            ?? discordUser?.displayName.nilIfBlank
            ?? discordUser?.username?.nilIfBlank
            ?? "Discord user"
    }

    private func sectionHeader(_ text: String, color: Color = .primary) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
    }

    private func infoRow(_ label: String, _ value: String, monospaced: Bool = false, copyable: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(label):")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .system(size: 12).monospaced() : .system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if copyable {
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Copy")
            }
            Spacer(minLength: 0)
        }
    }

    private func messageTitle(for entry: DMLogStore.Entry, request: SwiftBotDMRequest?) -> String {
        guard let type = SwiftBotDMMessageType(rawValue: entry.messageType) else {
            return entry.messageType
        }
        if let request, request.messageType == type {
            switch type {
            case .dropClaimed:
                if let drop = request.milestoneTitle, !drop.isEmpty {
                    return "Drop claimed: \(drop)"
                }
            case .campaignDetected:
                if let name = request.campaignName, !name.isEmpty {
                    return "New campaign: \(name)"
                }
            case .campaignCompleted:
                if let name = request.campaignName, !name.isEmpty {
                    return "Campaign complete: \(name)"
                }
            case .prioritisedGameNeedsLinking:
                if let game = request.affectedGame, !game.isEmpty {
                    return "Link required for \(game)"
                }
            default:
                break
            }
        }
        return type.displayName
    }

    private func messageDetail(for entry: DMLogStore.Entry, request: SwiftBotDMRequest?) -> String? {
        guard let type = SwiftBotDMMessageType(rawValue: entry.messageType) else { return nil }
        guard let request, request.messageType == type else { return nil }
        switch type {
        case .dropClaimed:
            return request.campaignName
        case .accountActionRequired, .reauth:
            return request.recoveryReason
        default:
            return nil
        }
    }

    /// Recurring/configurable types are filtered against Settings toggles —
    /// the user shouldn't see entries for notifications they've turned off.
    private var visibleEntries: [DMLogStore.Entry] {
        entries.filter { isVisible(messageType: $0.messageType) }
    }

    private func isVisible(messageType: String) -> Bool {
        guard let type = SwiftBotDMMessageType(rawValue: messageType) else { return true }
        let s = Settings.shared
        switch type {
        case .welcome, .discordLinked, .setup, .linked:
            return true
        // Drop-claimed DMs are no longer sent; show any historical log entries.
        case .dropClaimed:
            return true
        case .reauth: return s.dmConnectionExpiredEnabled
        case .welcomeBack: return s.dmWelcomeBackEnabled
        case .campaignCompleted: return s.dmCampaignCompletedEnabled
        case .campaignDetected: return s.dmCampaignDetectedEnabled
        case .accountActionRequired: return s.dmAccountActionRequiredEnabled
        case .prioritisedGameNeedsLinking: return s.dmLinkRequiredEnabled
        // One-time announcement; always show in history.
        case .webDashboardAvailable: return true
        }
    }

    private func displayLabel(for messageType: String) -> String {
        SwiftBotDMMessageType(rawValue: messageType)?.displayName ?? messageType
    }

    private func load() async {
        guard let discordId = miner.ownerDiscordId else {
            isLoading = false
            entries = []
            lastRequest = nil
            return
        }
        isLoading = true
#if DEBUG
        let includeDebug = true
#else
        let includeDebug = false
#endif
        async let entriesResult = navigation.dmLogStore.recentEntries(
            forDiscordId: discordId,
            limit: 50,
            includeDebug: includeDebug
        )
        async let requestResult = navigation.dmLogStore.mostRecentProductionRequest(forDiscordId: discordId)
        entries = await entriesResult
        lastRequest = await requestResult
        isLoading = false
    }
}

// MARK: - View All sheet

private struct AllHistorySheet: View {
    let minerName: String
    let entries: [DMLogStore.Entry]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("DM History")
                        .font(.headline)
                    Text(minerName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            if entries.isEmpty {
                Text("No DMs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(20)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(relativeTimeString(for: entry.sentAt))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 80, alignment: .leading)
                                Text(SwiftBotDMMessageType(rawValue: entry.messageType)?.displayName ?? entry.messageType)
                                    .font(.caption)
                                if entry.isDebug {
                                    Text("TEST")
                                        .font(.system(size: 9, weight: .semibold))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.orange.opacity(0.18), in: Capsule())
                                        .foregroundStyle(.orange)
                                }
                                Spacer()
                                Text(absoluteTimeString(for: entry.sentAt))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 400)
            }
        }
        .frame(width: 480)
    }
}

// MARK: - Link sheet

private struct LinkMinerSheet: View {
    let miner: MinerManager.ManagedMiner
    let isRelink: Bool

    @Environment(NavigationModel.self) private var navigation
    @Environment(\.dismiss) private var dismiss
    @State private var discordUsers: [SwiftBotDiscordUser] = []
    @State private var selectedUserId: String?
    @State private var fallbackId = ""
    @State private var isLoading = true
    @State private var isProcessing = false
    @State private var errorMessage: String?

    private var useFallback: Bool { discordUsers.isEmpty && !isLoading }
    private var cleanFallbackId: String { fallbackId.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isFallbackValid: Bool {
        cleanFallbackId.count >= 17 && cleanFallbackId.count <= 19 && cleanFallbackId.allSatisfy(\.isNumber)
    }
    private var canSubmit: Bool {
        if useFallback { return isFallbackValid && !isProcessing }
        return selectedUserId != nil && !isProcessing
    }
    private var resolvedDiscordId: String? {
        useFallback ? (isFallbackValid ? cleanFallbackId : nil) : selectedUserId
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isRelink ? "Re-link \(miner.displayName)" : "Link \(miner.displayName)")
                .font(.title3.weight(.bold))

            Text(isRelink
                 ? "Choose a different Discord account to own this Twitch account."
                 : "Assign a Discord account to this Twitch account.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if isLoading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading Discord users…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if !discordUsers.isEmpty {
                Picker("Discord account", selection: $selectedUserId) {
                    Text("Select a user…").tag(String?.none)
                    ForEach(discordUsers) { user in
                        Text(user.displayName)
                            .tag(Optional(user.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Discord User ID", text: $fallbackId)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isProcessing)
                    if !cleanFallbackId.isEmpty && !isFallbackValid {
                        Text("Discord ID must be 17–19 digits.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Text("SwiftBot is not connected — enter a Discord ID manually.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .disabled(isProcessing)
                Spacer()
                Button(isRelink ? "Re-link" : "Link") {
                    Task { await performLink() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 380)
        .task { await loadUsers() }
    }

    private func loadUsers() async {
        isLoading = true
        discordUsers = await navigation.swiftBotConnectionService.fetchDiscordUsers()
        isLoading = false
    }

    private func performLink() async {
        guard let discordId = resolvedDiscordId else { return }
        isProcessing = true
        errorMessage = nil

        let policy: ReassignmentPolicy = isRelink
            ? .allowConfirmed(expectedCurrentOwner: miner.ownerDiscordId ?? "")
            : .rejectIfOwned

        let assignment = AdminAccountAssignment(
            twitchAccountId: miner.accountId,
            discordId: discordId,
            operatorIdentity: .localAdmin
        )
        let result = await navigation.adminLinkingService.assignAccount(assignment, policy: policy)

        await MainActor.run {
            isProcessing = false
            switch result {
            case .linked:
                navigation.minerManager.setOwnerDiscordId(forAccountId: miner.accountId, to: discordId)
                dismiss()
            case .alreadyLinked(let currentDiscordId):
                if currentDiscordId == discordId {
                    navigation.minerManager.setOwnerDiscordId(forAccountId: miner.accountId, to: discordId)
                    dismiss()
                } else {
                    let label = displayName(forDiscordId: currentDiscordId)
                    errorMessage = "Twitch account already linked to \(label). Use Re-link to reassign."
                }
            case .notFound:
                errorMessage = "Twitch account not found."
            case .invalidDiscordId:
                errorMessage = "Invalid Discord ID."
            case .internalError(let message):
                errorMessage = message
            }
        }
    }

    private func displayName(forDiscordId id: String) -> String {
        discordUsers.first(where: { $0.id == id })?.displayName.nilIfBlank
            ?? discordUsers.first(where: { $0.id == id })?.username?.nilIfBlank
            ?? "Discord user"
    }
}

// MARK: - Helpers

/// Minute-precision relative formatter — `Text(_, style: .relative)` ticks
/// down per-second which is too noisy for a list view.
private func relativeTimeString(for date: Date) -> String {
    let interval = Date().timeIntervalSince(date)
    if interval < 60 { return "Just now" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    formatter.dateTimeStyle = .numeric
    return formatter.localizedString(for: date, relativeTo: Date())
}

private func absoluteTimeString(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

#Preview {
    AdminView()
        .environment(NavigationModel(clientId: "preview"))
}
