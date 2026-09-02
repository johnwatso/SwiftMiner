import AppKit
import SwiftUI
import SwiftMinerCore
import SwiftMinerService

// Discord is a capability of an individual miner rather than a destination of
// its own, so everything the old standalone Discord tab offered — identity,
// link state, DM history, re-send, link/unlink — lives here, inside the
// selected miner's detail view.

// MARK: - Presentation

/// Resolved Discord state for one miner. Pure value type so the collapsed
/// summary, the expanded panel and the tests all read the same rules.
struct MinerDiscordPresentation: Equatable {
    enum Status: Equatable {
        case notLinked
        case connected
        /// SwiftBot itself is unreachable, so no DM can be delivered.
        case botOffline
        /// The linked snowflake resolves to no Discord account SwiftBot can see.
        case accountUnavailable
        /// The most recent send attempt from this session failed.
        case deliveryFailed

        var label: String {
            switch self {
            case .notLinked: return "Not linked"
            case .connected: return "Connected"
            case .botOffline: return "Bot offline"
            case .accountUnavailable: return "Account unavailable"
            case .deliveryFailed: return "Delivery failed"
            }
        }

        var isProblem: Bool {
            switch self {
            case .notLinked, .connected: return false
            case .botOffline, .accountUnavailable, .deliveryFailed: return true
            }
        }

        var tint: Color {
            switch self {
            case .connected: return .green
            case .notLinked: return .secondary
            case .botOffline, .accountUnavailable: return .orange
            case .deliveryFailed: return .red
            }
        }

        var symbol: String {
            switch self {
            case .connected: return "checkmark.circle.fill"
            case .notLinked: return "link"
            case .botOffline: return "bolt.horizontal.circle.fill"
            case .accountUnavailable: return "person.crop.circle.badge.questionmark"
            case .deliveryFailed: return "exclamationmark.triangle.fill"
            }
        }
    }

    struct LastDM: Equatable {
        let title: String
        let detail: String?
        let sentAt: Date
        /// Only successful sends reach the DM log, so a logged message was
        /// delivered unless a later attempt in this session failed.
        let isDelivered: Bool
    }

    let isLinked: Bool
    let status: Status
    let displayName: String
    let username: String?
    let avatarURL: URL?
    let lastDM: LastDM?
    let messageCount: Int

    /// One line explaining a non-healthy state, shown without expanding.
    var statusDetail: String? {
        switch status {
        case .connected:
            return nil
        case .notLinked:
            return "Discord notifications aren't available for this miner."
        case .botOffline:
            return "SwiftBot is unreachable, so reminders can't be delivered."
        case .accountUnavailable:
            return "SwiftBot can't see the linked Discord account any more."
        case .deliveryFailed:
            return "The last message couldn't be delivered to Discord."
        }
    }

    static func resolve(
        miner: MinerManager.ManagedMiner,
        discordUser: SwiftBotDiscordUser?,
        discordDisplayName: String?,
        connectionState: SwiftBotConnectionState,
        lastDM: LastDM?,
        messageCount: Int,
        recentSendFailed: Bool
    ) -> MinerDiscordPresentation {
        let isLinked = miner.ownerDiscordId != nil

        let status: Status
        if !isLinked {
            status = .notLinked
        } else if recentSendFailed {
            status = .deliveryFailed
        } else if connectionState != .connected {
            status = .botOffline
        } else if discordUser == nil {
            status = .accountUnavailable
        } else {
            status = .connected
        }

        let name = discordDisplayName?.nilIfBlank
            ?? discordUser?.displayName.nilIfBlank
            ?? discordUser?.username?.nilIfBlank
            ?? (isLinked ? "Discord user" : "Not linked")

        // A username identical to the display name is noise, not information.
        let username = discordUser?.username?.nilIfBlank.flatMap { $0 == name ? nil : $0 }

        return MinerDiscordPresentation(
            isLinked: isLinked,
            status: status,
            displayName: name,
            username: username,
            avatarURL: discordUser?.avatarURL,
            lastDM: isLinked ? lastDM : nil,
            messageCount: isLinked ? messageCount : 0
        )
    }
}

// MARK: - Section

/// Compact Discord summary for the selected miner, sitting between the campaign
/// queue and Status. Collapsed it answers "is Discord communication working?";
/// expanded it becomes the management surface: last DM, recent history, and the
/// account link. Disclosure alone carries that split — there is no second menu.
struct MinerDiscordSection: View {
    let miner: MinerManager.ManagedMiner

    @Environment(NavigationModel.self) private var navigation
    @Environment(\.openSettings) private var openSettings
    private var settings: Settings { .shared }

    @AppStorage("minerDiscordSectionExpanded", store: Settings.appStorageStore)
    private var isExpanded = false

    @State private var entries: [DMLogStore.Entry] = []
    @State private var lastRequest: SwiftBotDMRequest?
    @State private var isLoading = true
    @State private var showAllHistory = false
    @State private var linkIntent: MinerDiscordLinkIntent?
    @State private var showUnlinkConfirmation = false
    @State private var recentSendFailed = false
    @State private var isSending = false

    private var displayedDiscordUser: SwiftBotDiscordUser? {
#if DEBUG
        if MarketingScreenshotFixture.isEnabled {
            return SwiftBotDiscordUser(
                id: MarketingScreenshotFixture.fakeDiscordId,
                displayName: "Nova",
                username: "nova.drops"
            )
        }
#endif
        return miner.ownerDiscordId.flatMap { navigation.discordUsersById[$0] }
    }

    private var displayedConnectionState: SwiftBotConnectionState {
#if DEBUG
        if MarketingScreenshotFixture.isEnabled { return .connected }
#endif
        return navigation.swiftBotState
    }

    private var displayedLastRequest: SwiftBotDMRequest? {
#if DEBUG
        if MarketingScreenshotFixture.isEnabled {
            return SwiftBotDMRequest(
                messageType: .campaignCompleted,
                debug: false,
                twitchUsername: miner.username,
                campaignName: "Live Update 1.42.0",
                minerDisplayName: miner.displayName
            )
        }
#endif
        return lastRequest
    }

    private var displaysExpandedContent: Bool {
#if DEBUG
        return isExpanded || MarketingScreenshotFixture.isEnabled
#else
        return isExpanded
#endif
    }

    private var presentation: MinerDiscordPresentation {
        MinerDiscordPresentation.resolve(
            miner: miner,
            discordUser: displayedDiscordUser,
            discordDisplayName: displayedDiscordUser?.displayName,
            connectionState: displayedConnectionState,
            lastDM: lastDM,
            messageCount: visibleEntries.count,
            recentSendFailed: recentSendFailed
        )
    }

    var body: some View {
        TahoeSection("Discord") {
            VStack(spacing: 0) {
                MinerDiscordSummaryRow(
                    presentation: presentation,
                    isExpanded: displaysExpandedContent
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                }

                if displaysExpandedContent {
                    TahoeRowDivider(leadingInset: 14)
                    expandedContent
                }
            }
        }
        .task(id: miner.ownerDiscordId) { await load() }
        .sheet(item: $linkIntent) { intent in
            MinerDiscordLinkSheet(miner: intent.miner, isRelink: intent.isRelink)
        }
        .sheet(isPresented: $showAllHistory) {
            MinerDiscordHistorySheet(
                minerName: miner.displayName,
                entries: visibleEntries
            )
        }
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
    }

    // MARK: Expanded

    @ViewBuilder
    private var expandedContent: some View {
        if presentation.isLinked {
            VStack(alignment: .leading, spacing: 0) {
                // Last DM and recent history are one glance at the same thing,
                // so they sit side by side and fall into a stack when narrow.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 0) {
                        lastDMArea
                            .frame(maxWidth: .infinity, alignment: .topLeading)

                        Divider()
                            .padding(.vertical, 12)

                        recentMessagesArea
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }

                    VStack(spacing: 0) {
                        lastDMArea
                        TahoeRowDivider(leadingInset: 14)
                        recentMessagesArea
                    }
                }

                TahoeRowDivider(leadingInset: 14)

                accountArea
            }
        } else {
            unlinkedArea
        }
    }

    private var lastDMArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            areaHeader("Last DM")

            if let lastDM = presentation.lastDM {
                Text(lastDM.title)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)

                if let detail = lastDM.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 5) {
                    Text("Sent \(MinerDiscordFormat.relative(lastDM.sentAt))")
                    Text("•")
                    Text(lastDM.isDelivered ? "Delivered" : "Not delivered")
                        .foregroundStyle(lastDM.isDelivered ? Color.green : Color.red)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text(isLoading ? "Loading…" : "No DMs sent yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            messageActions
                .padding(.top, 3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    /// The manual messaging operations, kept together because they are the same
    /// kind of act: sending this miner's owner something out of band.
    private var messageActions: some View {
        HStack(spacing: 8) {
            Button {
                Task { await resendLast() }
            } label: {
                Label("Resend Last DM", systemImage: "paperplane")
            }
            .disabled(displayedLastRequest == nil || isSending)

            Button {
                Task { await sendWelcome() }
            } label: {
                Label("Send Welcome Message", systemImage: "checkmark.message")
            }
            .disabled(isSending)

            // Only reachable while Twitch auth is actually broken; it asks the
            // owner over Discord to reconnect the account.
            if miner.needsAuth {
                Button {
                    Task { await emitReauth() }
                } label: {
                    Label("Fix Connection", systemImage: "wrench.and.screwdriver")
                }
                .disabled(isSending)
            }
        }
        .tahoeButtonStyle()
        .controlSize(.small)
    }

    private var recentMessagesArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            areaHeader("Recent messages")

            if visibleEntries.isEmpty {
                Text(isLoading ? "Loading…" : "No messages yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(visibleEntries.prefix(Self.recentMessageLimit).enumerated()), id: \.offset) { _, entry in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(MinerDiscordFormat.title(for: entry, request: displayedLastRequest))
                                .font(.caption)
                                .lineLimit(1)

                            if entry.isDebug {
                                Text("TEST")
                                    .font(.system(size: 8, weight: .semibold))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.orange.opacity(0.18), in: Capsule())
                                    .foregroundStyle(.orange)
                            }

                            // A small gap rather than a Spacer: the timestamp
                            // reads as part of its row, not as a second column
                            // pinned to the far edge of the card.
                            Text(MinerDiscordFormat.relative(entry.sentAt))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)

                            Spacer(minLength: 0)
                        }
                    }
                }

                if visibleEntries.count > Self.recentMessageLimit {
                    Button("View full message history") { showAllHistory = true }
                        .buttonStyle(.link)
                        .font(.caption)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    /// Link management, deliberately quiet and below the activity it governs.
    private var accountArea: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                areaHeader("Account")

                Text("Discord account \(presentation.displayName) is linked to this miner.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Button {
                    navigation.requestDiscordSettings()
                    openSettings()
                } label: {
                    Label("Discord Settings…", systemImage: "gearshape")
                }

                Button {
                    linkIntent = MinerDiscordLinkIntent(miner: miner, isRelink: true)
                } label: {
                    Label("Re-link Account", systemImage: "personalhotspot")
                }

                // Red on the label only. Tinting the whole control would make
                // the one destructive action the loudest thing in the card.
                Button(role: .destructive) {
                    showUnlinkConfirmation = true
                } label: {
                    Label(
                        "Unlink",
                        systemImage: SystemSymbolCompatibility.resolvedName(for: "personalhotspot.slash")
                    )
                    .foregroundStyle(.red)
                }
            }
            .tahoeButtonStyle()
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var unlinkedArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Link a Discord account to send this miner's reminders and recovery messages as DMs.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    linkIntent = MinerDiscordLinkIntent(miner: miner, isRelink: false)
                } label: {
                    Label("Link Discord Account", systemImage: "link")
                }

                Button {
                    navigation.requestDiscordSettings()
                    openSettings()
                } label: {
                    Label("Discord Settings…", systemImage: "gearshape")
                }
            }
            .tahoeButtonStyle()
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func areaHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    // MARK: Actions


    private func sendWelcome() async {
        guard let discordId = miner.ownerDiscordId else { return }
        let portal = SwiftMinerPortalLink(base: NavigationModel.portalBase())
        let request = SwiftBotDMRequest(
            messageType: .welcome,
            debug: false,
            twitchUsername: miner.username,
            priorityGames: settings.priorityGames(forAccountId: miner.accountId),
            portalURL: portal?.dashboard,
            portalDestination: portal.map { _ in SwiftBotPortalDestination.dashboard.rawValue },
            helpURL: SwiftMinerHelpLink.webDashboard
        )
        await send(request, to: discordId)
    }

    private func resendLast() async {
        guard let discordId = miner.ownerDiscordId, let displayedLastRequest else { return }
#if DEBUG
        if MarketingScreenshotFixture.isEnabled { return }
#endif
        await send(displayedLastRequest, to: discordId)
    }

    private func send(_ request: SwiftBotDMRequest, to discordId: String) async {
        isSending = true
        defer { isSending = false }
        let sent = await navigation.swiftBotConnectionService.sendEventDM(to: discordId, request: request)
        // Refresh history first: `load()` clears the transient failure flag, so
        // this send's outcome has to be applied after it, never before.
        await load()
        recentSendFailed = !sent
    }

    private func emitReauth() async {
        guard let discordId = miner.ownerDiscordId else { return }
        await navigation.eventEmitter.emitUserReauthRequested(
            discordUserId: discordId,
            twitchAccountId: miner.accountId
        )
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

    // MARK: Data

    private static let recentMessageLimit = 4

    private var lastDM: MinerDiscordPresentation.LastDM? {
        guard let entry = visibleEntries.first else { return nil }
        return MinerDiscordPresentation.LastDM(
            title: MinerDiscordFormat.title(for: entry, request: displayedLastRequest),
            detail: MinerDiscordFormat.detail(for: entry, request: displayedLastRequest),
            sentAt: entry.sentAt,
            isDelivered: !recentSendFailed
        )
    }

    /// Configurable message types are filtered against Settings — history
    /// shouldn't list notifications the operator has turned off.
    private var visibleEntries: [DMLogStore.Entry] {
#if DEBUG
        if MarketingScreenshotFixture.isEnabled {
            let now = Date()
            return [
                DMLogStore.Entry(messageType: SwiftBotDMMessageType.campaignCompleted.rawValue, sentAt: now.addingTimeInterval(-12 * 60), isDebug: false),
                DMLogStore.Entry(messageType: SwiftBotDMMessageType.dropClaimed.rawValue, sentAt: now.addingTimeInterval(-68 * 60), isDebug: false),
                DMLogStore.Entry(messageType: SwiftBotDMMessageType.campaignDetected.rawValue, sentAt: now.addingTimeInterval(-3 * 60 * 60), isDebug: false),
                DMLogStore.Entry(messageType: SwiftBotDMMessageType.welcome.rawValue, sentAt: now.addingTimeInterval(-25 * 60 * 60), isDebug: false)
            ]
        }
#endif
        return entries.filter { MinerDiscordFormat.isVisible(messageType: $0.messageType, settings: settings) }
    }

    private func load() async {
        // Never let the previous miner's history linger while the new one loads.
        entries = []
        lastRequest = nil
        recentSendFailed = false

#if DEBUG
        if MarketingScreenshotFixture.isEnabled {
            isLoading = false
            return
        }
#endif

        guard let discordId = miner.ownerDiscordId else {
            isLoading = false
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

// MARK: - Collapsed summary

/// The always-visible header: who Discord talks to for this miner, whether that
/// is working, and how much history there is. The whole row is the disclosure
/// target — the chevron is an affordance, not the hit area.
struct MinerDiscordSummaryRow: View {
    let presentation: MinerDiscordPresentation
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 11) {
                MinerDiscordAvatar(url: presentation.avatarURL)
                    .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(presentation.displayName)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(presentation.isLinked ? .primary : .secondary)
                            .lineLimit(1)

                        if let username = presentation.username {
                            Text(username)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                statusBadge

                if presentation.messageCount > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "bubble.left")
                            .font(.caption2)
                        Text(messageCountLabel)
                            .font(.caption.monospacedDigit())
                    }
                    .foregroundStyle(.secondary)
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Hide Discord details" : "Show Discord details")
    }

    private var messageCountLabel: String {
        let count = presentation.messageCount
        return "\(count) \(count == 1 ? "Message" : "Messages")"
    }

    private var subtitle: String {
        if presentation.status.isProblem, let detail = presentation.statusDetail {
            return detail
        }
        if presentation.isLinked {
            return "Linked to this miner"
        }
        return presentation.statusDetail ?? "Not linked"
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: presentation.status.symbol)
                .font(.caption2.weight(.semibold))
            Text(presentation.status.label)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(presentation.status.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(presentation.status.tint.opacity(0.12), in: Capsule())
    }
}

// MARK: - Avatar

struct MinerDiscordAvatar: View {
    let url: URL?

    var body: some View {
        if let url {
            CachedAvatarImage(url: url) {
                DiscordLogoFallback()
            }
            .clipShape(Circle())
        } else {
            DiscordLogoFallback()
        }
    }
}

struct DiscordLogoFallback: View {
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

// MARK: - Formatting

enum MinerDiscordFormat {
    /// Minute-precision relative formatter — `Text(_, style: .relative)` ticks
    /// down per-second which is too noisy for a summary row.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 60 { return "Just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func absolute(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// The specific subject line where the stored payload still describes the
    /// newest entry, falling back to the message type's own name.
    static func title(for entry: DMLogStore.Entry, request: SwiftBotDMRequest?) -> String {
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
                    return "Link \(game) to Twitch"
                }
            default:
                break
            }
        }
        return type.displayName
    }

    static func detail(for entry: DMLogStore.Entry, request: SwiftBotDMRequest?) -> String? {
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

    static func displayLabel(for messageType: String) -> String {
        SwiftBotDMMessageType(rawValue: messageType)?.displayName ?? messageType
    }

    @MainActor
    static func isVisible(messageType: String, settings: Settings) -> Bool {
        guard let type = SwiftBotDMMessageType(rawValue: messageType) else { return true }
        switch type {
        case .welcome, .discordLinked, .setup, .linked:
            return true
        // Drop-claimed DMs are no longer sent; show any historical log entries.
        case .dropClaimed:
            return true
        case .reauth: return settings.dmConnectionExpiredEnabled
        case .welcomeBack: return settings.dmWelcomeBackEnabled
        case .campaignCompleted: return settings.dmCampaignCompletedEnabled
        case .campaignDetected: return settings.dmCampaignDetectedEnabled
        case .accountActionRequired: return settings.dmAccountActionRequiredEnabled
        case .prioritisedGameNeedsLinking: return settings.dmLinkRequiredEnabled
        // One-time announcement; always show in history.
        case .webDashboardAvailable: return true
        }
    }
}

// MARK: - History sheet

struct MinerDiscordHistorySheet: View {
    let minerName: String
    let entries: [DMLogStore.Entry]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Message History")
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
                Text("No messages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(20)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(MinerDiscordFormat.relative(entry.sentAt))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 80, alignment: .leading)
                                Text(MinerDiscordFormat.displayLabel(for: entry.messageType))
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
                                Text(MinerDiscordFormat.absolute(entry.sentAt))
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

struct MinerDiscordLinkIntent: Identifiable {
    let id = UUID()
    let miner: MinerManager.ManagedMiner
    let isRelink: Bool
}

struct MinerDiscordLinkSheet: View {
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
