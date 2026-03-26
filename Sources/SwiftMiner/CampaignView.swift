import SwiftUI
import SwiftMinerCore

// MARK: - Drops List View

struct DropsListView: View {
    @Environment(NavigationModel.self) private var navigation
    @State private var filter: DropFilter = .active
    @State private var campaigns: [CampaignViewData] = []
    @State private var isRefreshing = false
    @State private var hasLoadedFeed = false
    @AppStorage("preferSteamArtwork") private var preferSteamArtwork: Bool = false

    enum DropFilter: String, CaseIterable, Identifiable {
        case active = "Active"
        case claimed = "Claimed"
        case all = "All"

        var id: String { rawValue }
    }

    private var miners: [MinerManager.ManagedMiner] { navigation.minerManager.miners }
    private var hasAccounts: Bool { !miners.isEmpty }
    private var dropFilterItems: [GlassSelectionItem<DropFilter>] {
        [
            GlassSelectionItem(id: .active, title: "Active", systemImage: "dot.radiowaves.left.and.right"),
            GlassSelectionItem(id: .claimed, title: "Claimed", systemImage: "checkmark.circle.fill"),
            GlassSelectionItem(id: .all, title: "All", systemImage: "square.grid.2x2.fill")
        ]
    }

    /// Hero URL for a specific campaign — used to pass per-card blurred backdrop.
    private func heroURL(for campaign: CampaignViewData) -> URL? {
        guard preferSteamArtwork else { return nil }
        return navigation.minerManager.dataCoordinator.steamHeroOverrides[campaign.gameName]
    }

    private var accountSignature: String {
        miners
            .map { "\($0.id):\($0.accountId)" }
            .sorted()
            .joined(separator: "|")
    }

    var body: some View {
        Group {
            if !hasAccounts {
                noAccountsState
            } else if campaigns.isEmpty && isRefreshing {
                initialLoadingState
            } else if campaigns.isEmpty {
                contextualStandbyState(
                    message: "No active campaigns right now",
                    description: "Check back once your miner has synced campaign data."
                )
            } else if renderedCampaigns.isEmpty {
                contextualStandbyState(
                    message: emptyFilterMessage,
                    description: emptyFilterDescription
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if let message = contextualBannerMessage {
                            fallbackBanner(message)
                        }

                        ForEach(renderedCampaigns) { campaign in
                            CampaignDeckCard(
                                campaign: campaign,
                                heroURL: heroURL(for: campaign),
                                state: cardState(for: campaign),
                                queueWatchers: queuedMinerNames(for: campaign),
                                onSteamIdSet: { appId in
                                    await SteamArtworkService.shared.setManualAppId(for: campaign.gameName, appId: appId)
                                    await navigation.minerManager.dataCoordinator.clearSteamArtworkCache()
                                    await loadCampaignFeed()
                                }
                            )
                            .transition(.opacity.combined(with: .scale(scale: 0.985)))
                        }
                    }
                    .padding(24)
                }
                .animation(.easeInOut(duration: 0.28), value: renderSignature)
            }
        }
        .navigationTitle("Drops")
        .toolbar {
            ToolbarItem(placement: .principal) {
                GlassSelectionControl(
                    items: dropFilterItems,
                    selection: $filter,
                    axis: .horizontal,
                    itemSpacing: 4,
                    padding: 4,
                    contentInsets: EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12),
                    selectedCornerRadius: GlassRadius.large,
                    fillsAvailableSpace: true,
                    showsContainer: true,
                    contentAlignment: .center
                ) { item, isSelected in
                    Text(item.title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                }
                .frame(width: 212)
                .help("Filter campaigns by active, claimed, or all.")
                .accessibilityLabel("Drops filter")
                .accessibilityHint("Choose Active, Claimed, or All campaigns.")
                .accessibilityValue(filter.rawValue)
                .accessibilityElement(children: .contain)
                .animation(.spring(response: 0.3, dampingFraction: 0.82), value: filter)
            }
        }
        .task(id: accountSignature) {
            await loadCampaignFeed()
        }
        .onChange(of: preferSteamArtwork) { _, _ in
            Task {
                await navigation.minerManager.dataCoordinator.clearSteamArtworkCache()
                await loadCampaignFeed()
            }
        }
    }

    // MARK: - States

    private var noAccountsState: some View {
        MaterialEmptyStatePanel(
            "Add an account to load drops",
            systemImage: "person.crop.circle.badge.plus",
            description: "SwiftMiner will render cached and live campaigns here as soon as an account is connected."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var initialLoadingState: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)

            VStack(spacing: 6) {
                Text("Loading campaigns")
                    .font(.headline)

                Text("Your progress will be ready in a moment.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func contextualStandbyState(message: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            fallbackBanner(message)

            Color.clear
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Campaigns are syncing")
                            .font(.headline.weight(.semibold))

                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                }
                .frame(height: 220)
                .glassCard()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
    }

    @ViewBuilder
    private func fallbackBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles.tv")
                .foregroundStyle(.secondary)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial.opacity(0.75), in: RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous))
    }

    // MARK: - Data

    private var allCampaigns: [CampaignViewData] {
        campaigns.sorted(by: campaignSort)
    }

    private var activeQueueCampaigns: [CampaignViewData] {
        campaigns
            .filter { campaign in
                !queuedMinerNames(for: campaign).isEmpty || campaign.showsInActiveTab
            }
            .sorted(by: campaignSort)
    }

    private var claimedCampaigns: [CampaignViewData] {
        campaigns
            .filter(\.showsInClaimedTab)
            .sorted(by: campaignSort)
    }

    private var renderedCampaigns: [CampaignViewData] {
        switch filter {
        case .active:
            return activeQueueCampaigns
        case .claimed:
            return claimedCampaigns
        case .all:
            return allCampaigns
        }
    }

    private var contextualBannerMessage: String? {
        switch filter {
        case .all where isRefreshing:
            return "Refreshing campaigns in the background"
        case .claimed where !claimedCampaigns.isEmpty && isRefreshing:
            return "Refreshing claimed campaigns in the background"
        default:
            return nil
        }
    }

    private var emptyFilterMessage: String {
        switch filter {
        case .active:
            return "No active campaigns right now"
        case .claimed:
            return "No claimed campaigns yet"
        case .all:
            return "No campaigns available right now"
        }
    }

    private var emptyFilterDescription: String {
        switch filter {
        case .active:
            return "The Active tab only reflects miners currently queued to watch a campaign. Your other campaign history stays intact in All."
        case .claimed:
            return "Campaigns you've completed will appear here once inventory syncs."
        case .all:
            return "This view stays pinned to cached campaign history, so it will repopulate as soon as campaign data is available."
        }
    }

    private var renderSignature: [String] {
        renderedCampaigns.map { campaign in
            "\(campaign.id)-\(cardState(for: campaign).rawValue)-\(Int(campaign.progress * 100))-\(campaign.dropsClaimed)-\(queuedMinerNames(for: campaign).joined(separator: ","))"
        }
    }

    private func loadCampaignFeed() async {
        guard hasAccounts else {
            await MainActor.run {
                campaigns = []
                hasLoadedFeed = false
                isRefreshing = false
            }
            return
        }

        // Seed from last-known cache immediately (synchronous) so the view
        // shows artwork-complete campaigns while the async refresh runs.
        let lastKnown = navigation.minerManager.dataCoordinator.lastKnownAllCampaigns
        if campaigns.isEmpty && !lastKnown.isEmpty {
            campaigns = lastKnown
        }

        // Load ALL campaigns (not filtered) for the "All" tab
        let cached = await navigation.minerManager.dataCoordinator.allCampaigns(
            preferSteamArtwork: Settings.shared.preferSteamArtwork
        )
        await MainActor.run {
            if !cached.isEmpty {
                withAnimation(.easeInOut(duration: 0.2)) {
                    campaigns = cached
                }
            }
            isRefreshing = true
        }

        await navigation.minerManager.dataCoordinator.refreshAll()
        // Load ALL campaigns after refresh (not filtered)
        let refreshed = await navigation.minerManager.dataCoordinator.allCampaigns(
            preferSteamArtwork: Settings.shared.preferSteamArtwork
        )

        await MainActor.run {
            if !refreshed.isEmpty || campaigns.isEmpty {
                withAnimation(.easeInOut(duration: 0.24)) {
                    campaigns = refreshed
                }
            }
            hasLoadedFeed = true
            isRefreshing = false
        }
    }

    private func queuedMinerNames(for campaign: CampaignViewData) -> [String] {
        miners.compactMap { miner in
            if let id = miner.currentCampaignId, id == campaign.id, miner.isRunning {
                return miner.username
            }

            if miner.currentCampaign == campaign.campaignName, miner.isRunning {
                return miner.username
            }

            return nil
        }
    }

    private func campaignSort(lhs: CampaignViewData, rhs: CampaignViewData) -> Bool {
        let lhsState = cardState(for: lhs)
        let rhsState = cardState(for: rhs)

        if lhsState.priority != rhsState.priority {
            return lhsState.priority < rhsState.priority
        }

        if lhs.progress != rhs.progress {
            return lhs.progress > rhs.progress
        }

        return lhs.gameName < rhs.gameName
    }

    private func cardState(for campaign: CampaignViewData) -> CampaignCardState {
        if !queuedMinerNames(for: campaign).isEmpty {
            return .active
        }

        switch campaign.miningStatus {
        case .claimable:
            return .claimable
        case .inProgress:
            return .inProgress
        case .claimed:
            return .claimed
        case .expired:
            return .expired
        case .available:
            return campaign.status == CampaignStatus.expired.rawValue ? .expired : .idle
        }
    }
}

// MARK: - Campaign Deck Card

private struct CampaignDeckCard: View {
    let campaign: CampaignViewData
    var heroURL: URL? = nil
    let state: CampaignCardState
    let queueWatchers: [String]
    var onSteamIdSet: ((String) async -> Void)?
    @State private var isHovered = false
    @State private var showingSteamIdPopover = false
    @State private var steamIdDraft = ""

    private var shownDrops: [DropViewData] {
        Array(campaign.drops.prefix(3))
    }

    private var progressPercent: Int {
        Int((campaign.progress * 100).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                CampaignArtworkIcon(url: campaign.artworkURL, tint: state.tint)

                VStack(alignment: .leading, spacing: 6) {
                    Text(campaign.gameName)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(campaign.campaignName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    Text(statusLine)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 10) {
                    statusBadge

                    if !queueWatchers.isEmpty {
                        CampaignQueueBadge(usernames: queueWatchers)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    metricLabel("\(campaign.dropsClaimed)/\(campaign.totalDrops) claimed")

                    if progressPercent > 0, state != .claimed, state != .expired {
                        metricLabel("\(progressPercent)% progress")
                    }

                    if let timeRemaining = campaign.timeRemaining, state != .claimed, state != .expired {
                        metricLabel(timeRemaining.formattedHoursMinutes)
                    }
                }

                if !campaign.accountStates.isEmpty {
                    CampaignAccountStrip(accountStates: campaign.accountStates)
                }

                if showsProgress {
                    ProgressView(value: campaign.progress, total: 1.0)
                        .progressViewStyle(.linear)
                        .tint(state.tint)
                }
            }

            if shownDrops.isEmpty {
                Text("No rewards available for this campaign.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(shownDrops) { drop in
                        CampaignDropPreviewRow(drop: drop)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(state.borderTint, lineWidth: 1)
        }
        .shadow(color: .black.opacity(isHovered ? 0.10 : 0.06), radius: isHovered ? 8 : 4, y: isHovered ? 4 : 2)
        .opacity(state == .expired ? 0.62 : 1)
        .saturation(1)
        .brightness(isHovered ? 0.008 : 0)
        .animation(.easeInOut(duration: 0.18), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            Button("Set Steam App ID…") {
                steamIdDraft = ""
                showingSteamIdPopover = true
            }
        }
        .popover(isPresented: $showingSteamIdPopover, arrowEdge: .bottom) {
            SteamIdInputPopover(
                gameName: campaign.gameName,
                appId: $steamIdDraft,
                onConfirm: {
                    showingSteamIdPopover = false
                    let id = steamIdDraft.trimmingCharacters(in: .whitespaces)
                    guard !id.isEmpty else { return }
                    Task { await onSteamIdSet?(id) }
                },
                onCancel: { showingSteamIdPopover = false }
            )
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch state {
        case .active:
            HStack(spacing: 8) {
                LivePulseDot(color: .green)
                Text("Active")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.green.opacity(0.82), in: Capsule())
        case .claimed:
            if campaign.isClosed {
                HStack(spacing: 8) {
                    Image(systemName: "archivebox.fill")
                    Text("Closed")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.secondary.opacity(0.82), in: Capsule())
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.green)
            }
        case .idle, .expired:
            Text(state == .expired ? "Expired" : "Idle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
        case .inProgress:
            Text("In Progress")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.blue.opacity(0.72), in: Capsule())
        case .claimable:
            Text("Claimable")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.orange.opacity(0.78), in: Capsule())
        }
    }

    private var statusLine: String {
        switch state {
        case .active:
            if let timeRemaining = campaign.timeRemaining {
                return "\(queueWatchersLabel) watching • \(timeRemaining.formattedHoursMinutes)"
            }
            return "\(queueWatchersLabel) watching"
        case .inProgress:
            if let timeRemaining = campaign.timeRemaining {
                return "\(progressPercent)% complete • \(timeRemaining.formattedHoursMinutes)"
            }
            return "\(progressPercent)% complete"
        case .claimable:
            return "Rewards ready to claim"
        case .claimed:
            return campaign.isClosed
                ? "Campaign closed after all drops were claimed"
                : "\(campaign.dropsClaimed)/\(campaign.totalDrops) drops claimed"
        case .expired:
            return "Campaign window has ended"
        case .idle:
            return progressPercent > 0 ? "\(progressPercent)% complete" : "Available in your cached campaign history"
        }
    }

    private var queueWatchersLabel: String {
        queueWatchers.isEmpty ? "Queued" : queueWatchers.joined(separator: ", ")
    }

    private var showsProgress: Bool {
        state == .active || state == .inProgress || state == .claimable
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.thinMaterial)
            .overlay {
                if let heroURL {
                    AsyncImage(url: heroURL) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .scaledToFill()
                                .blur(radius: 22, opaque: true)
                                .opacity(0.22)
                                .transition(.opacity.animation(.easeInOut(duration: 0.5)))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .allowsHitTesting(false)
                } else {
                    CampaignBackgroundAccent(url: campaign.artworkURL, tint: state.tint)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.10),
                                state.tint.opacity(state == .claimed ? 0.03 : 0.06),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
    }

    private func metricLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Drop Preview Row

private struct CampaignDropPreviewRow: View {
    let drop: DropViewData

    private var primaryState: DropPreviewState {
        if drop.isClaimed { return .claimed }
        if drop.isClaimable { return .claimable }
        if drop.isEarnable || drop.progress > 0 { return .inProgress }
        return .locked
    }

    private var progressPercent: Int {
        Int((drop.progress * 100).rounded())
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let url = drop.imageURL {
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                    } placeholder: {
                        placeholder
                    }
                } else {
                    placeholder
                }
            }
            .frame(width: 38, height: 38)
            .clipShape(RoundedRectangle(cornerRadius: GlassRadius.artwork, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(drop.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                if primaryState == .claimed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    ProgressView(value: drop.progress, total: 1.0)
                        .progressViewStyle(.linear)
                        .frame(width: 82)
                        .tint(progressTint)

                    Text("\(progressPercent)%")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial.opacity(0.86), in: RoundedRectangle(cornerRadius: GlassRadius.small, style: .continuous))
        .opacity(primaryState == .locked ? 0.72 : 1)
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: GlassRadius.artwork, style: .continuous)
            .fill(.thinMaterial)
            .overlay {
                Image(systemName: "gift.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
    }

    private var progressTint: Color {
        switch primaryState {
        case .claimed:
            return .green
        case .claimable:
            return .orange
        case .inProgress:
            return .blue
        case .locked:
            return .secondary
        }
    }

    private var statusText: String {
        switch primaryState {
        case .claimed:
            return "Claimed"
        case .claimable:
            return "Ready to claim"
        case .inProgress:
            return "\(drop.currentMinutes)/\(drop.requiredMinutes) min"
        case .locked:
            return drop.isEarnable ? "\(drop.currentMinutes)/\(drop.requiredMinutes) min" : "Locked"
        }
    }
}

// MARK: - Card Chrome

private struct CampaignStatePill: View {
    let state: CampaignCardState

    var body: some View {
        Label(state.title, systemImage: state.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(state.tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial.opacity(0.9), in: Capsule())
    }
}

private struct CampaignQueueBadge: View {
    let usernames: [String]

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.2.fill")
                .font(.caption2)

            Text(usernames.joined(separator: ", "))
                .lineLimit(1)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
    }
}

private struct CampaignAccountStrip: View {
    let accountStates: [AccountState]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(accountStates) { account in
                    accountCircle(for: account)
                        .help("\(account.username) — \(statusTitle(for: account.miningStatus))")
                }
            }
            .padding(.trailing, 4) // Breath room for the last circle
        }
        .frame(height: 28)
    }

    @ViewBuilder
    private func accountCircle(for account: AccountState) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Text(account.initials)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 24, height: 24)
                .background(backgroundColor(for: account.miningStatus), in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                }

            if account.miningStatus == .mining {
                LivePulseDot(color: .green)
                    .offset(x: 2, y: 2)
            } else if account.miningStatus == .needsAuth {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.orange)
                    .background(Color.white, in: Circle())
                    .offset(x: 2, y: 2)
            } else if account.miningStatus == .claimed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.blue)
                    .background(Color.white, in: Circle())
                    .offset(x: 2, y: 2)
            }
        }
    }

    private func statusTitle(for status: AccountMiningStatus) -> String {
        switch status {
        case .mining: return "Watching"
        case .claimed: return "Claimed"
        case .needsAuth: return "Needs Re-auth"
        case .idle: return "Idle"
        }
    }

    private func backgroundColor(for status: AccountMiningStatus) -> Color {
        switch status {
        case .needsAuth:
            return .orange.opacity(0.82)
        case .mining:
            return .green.opacity(0.85)
        case .claimed:
            return .blue.opacity(0.72)
        case .idle:
            return .white.opacity(0.18)
        }
    }
}

private struct LivePulseDot: View {
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: false)) { context in
            let scale = 0.92 + 0.16 * ((sin(context.date.timeIntervalSinceReferenceDate * 2.4) + 1) / 2)

            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .scaleEffect(scale)
                .shadow(color: color.opacity(0.6), radius: 6)
        }
    }
}

private struct CampaignCardArtwork: View {
    let url: URL?
    let tint: Color

    private var resolvedURL: URL? {
        url?.highResolutionArtworkURL
    }

    var body: some View {
        ZStack {
            if let resolvedURL {
                AsyncImage(url: resolvedURL) { image in
                    image
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [tint.opacity(0.82), tint.opacity(0.38), Color.black.opacity(0.52)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct CampaignArtworkIcon: View {
    let url: URL?
    let tint: Color

    var body: some View {
        CampaignCardArtwork(url: url, tint: tint)
            .frame(width: 48, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: GlassRadius.artwork, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: GlassRadius.artwork, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            }
    }
}

private struct CampaignBackgroundAccent: View {
    let url: URL?
    let tint: Color

    var body: some View {
        ZStack {
            if let highResURL = url?.highResolutionArtworkURL {
                AsyncImage(url: highResURL) { image in
                    image
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                } placeholder: {
                    Color.clear
                }
                .opacity(0.09)
                .blur(radius: 18)
                .scaleEffect(1.08)
            } else {
                LinearGradient(
                    colors: [
                        tint.opacity(0.08),
                        tint.opacity(0.02),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous))
        .allowsHitTesting(false)
    }
}

private extension URL {
    var highResolutionArtworkURL: URL {
        let replacements: [(String, String)] = [
            ("{width}", "1200"),
            ("{height}", "1600"),
            ("%7Bwidth%7D", "1200"),
            ("%7Bheight%7D", "1600")
        ]

        let resolved = replacements.reduce(absoluteString) { partial, pair in
            partial.replacingOccurrences(of: pair.0, with: pair.1)
        }

        return URL(string: resolved) ?? self
    }
}

private enum CampaignCardState: String {
    case active
    case inProgress
    case claimable
    case claimed
    case expired
    case idle

    var priority: Int {
        switch self {
        case .active: return 0
        case .claimable: return 1
        case .inProgress: return 2
        case .idle: return 3
        case .claimed: return 4
        case .expired: return 5
        }
    }

    var title: String {
        switch self {
        case .active: return "Active"
        case .inProgress: return "In Progress"
        case .claimable: return "Claimable"
        case .claimed: return "Claimed"
        case .expired: return "Expired"
        case .idle: return "Idle"
        }
    }

    var symbol: String {
        switch self {
        case .active: return "dot.radiowaves.left.and.right"
        case .inProgress: return "chart.bar.fill"
        case .claimable: return "sparkles"
        case .claimed: return "checkmark.circle.fill"
        case .expired: return "clock.badge.exclamationmark"
        case .idle: return "circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .active: return .green
        case .inProgress: return .blue
        case .claimable: return .orange
        case .claimed: return .green
        case .expired: return .secondary
        case .idle: return .secondary
        }
    }

    var borderTint: Color {
        switch self {
        case .active:
            return .green.opacity(0.28)
        case .claimable:
            return .orange.opacity(0.28)
        case .inProgress:
            return .blue.opacity(0.20)
        case .claimed:
            return .green.opacity(0.14)
        case .expired, .idle:
            return .white.opacity(0.12)
        }
    }
}

private enum DropPreviewState {
    case claimed
    case claimable
    case inProgress
    case locked
}

private extension TimeInterval {
    var formattedHoursMinutes: String {
        let totalMinutes = max(Int(self / 60), 0)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m left"
        }

        return "\(minutes)m left"
    }
}

// MARK: - Steam ID Input Popover

private struct SteamIdInputPopover: View {
    let gameName: String
    @Binding var appId: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set Steam App ID")
                .font(.headline)
            Text("Override artwork lookup for \"\(gameName)\"")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("App ID (e.g. 2073850)", text: $appId)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Set") { onConfirm() }
                    .keyboardShortcut(.return)
                    .disabled(appId.trimmingCharacters(in: .whitespaces).isEmpty)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

// MARK: - Preview

#Preview("Drops List") {
    DropsListView()
        .environment(NavigationModel(clientId: "preview"))
        .frame(width: 700, height: 680)
}
