import SwiftUI
import SwiftMinerCore
import CoreImage

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
                    title: emptyFilterTitle,
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

    private func contextualStandbyState(title: String = "Campaigns are syncing", message: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            fallbackBanner(message)

            Color.clear
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
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

    private var emptyFilterTitle: String {
        switch filter {
        case .active:
            return "No campaigns in Active"
        case .claimed:
            return "No campaigns in Claimed"
        case .all:
            return "Campaigns are syncing"
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

    @MainActor
    private func loadCampaignFeed() async {
        guard hasAccounts else {
            campaigns = []
            hasLoadedFeed = false
            isRefreshing = false
            return
        }
        print("[DropsListView] loadCampaignFeed start: miners=\(miners.count), existingCampaigns=\(campaigns.count), filter=\(filter.rawValue)")

        isRefreshing = true
        defer {
            hasLoadedFeed = true
            isRefreshing = false
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
        print("[DropsListView] cached campaigns count=\(cached.count)")
        if !cached.isEmpty {
            withAnimation(.easeInOut(duration: 0.2)) {
                campaigns = cached
            }
        }

        let preferSteamArtwork = Settings.shared.preferSteamArtwork
        let refreshTask = Task {
            await navigation.minerManager.dataCoordinator.refreshAll()
        }
        let completedInTime = await waitForRefreshTask(
            refreshTask,
            timeout: .seconds(45)
        )
        print("[DropsListView] refresh wait completedInTime=\(completedInTime)")

        // Don't leave the UI waiting forever when one account is slow.
        // Let refresh continue in the background and apply results when ready.
        if !completedInTime {
            Task { @MainActor in
                await refreshTask.value
                guard hasAccounts else { return }
                let eventual = await navigation.minerManager.dataCoordinator.allCampaigns(
                    preferSteamArtwork: preferSteamArtwork
                )
                print("[DropsListView] eventual campaigns after slow refresh=\(eventual.count)")
                if !eventual.isEmpty || campaigns.isEmpty {
                    withAnimation(.easeInOut(duration: 0.24)) {
                        campaigns = eventual
                    }
                }
            }
            return
        }

        // Load ALL campaigns after refresh (not filtered)
        let refreshed = await navigation.minerManager.dataCoordinator.allCampaigns(
            preferSteamArtwork: preferSteamArtwork
        )
        print("[DropsListView] refreshed campaigns count=\(refreshed.count)")

        if !refreshed.isEmpty || campaigns.isEmpty {
            withAnimation(.easeInOut(duration: 0.24)) {
                campaigns = refreshed
            }
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

    private func waitForRefreshTask(_ task: Task<Void, Never>, timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await task.value
                return true
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return false
                } catch {
                    return true
                }
            }

            let first = await group.next() ?? true
            group.cancelAll()
            return first
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
        let hasAccountStates = !campaign.accountStates.isEmpty
        let allRewardsClaimedByMiners: Bool

        if hasAccountStates {
            allRewardsClaimedByMiners = campaign.accountStates.allSatisfy { $0.miningStatus == .claimed }
        } else {
            allRewardsClaimedByMiners = campaign.isClaimed || (campaign.totalDrops > 0 && campaign.dropsClaimed >= campaign.totalDrops)
        }

        if allRewardsClaimedByMiners {
            return .claimed
        }

        let anyMinerActivelyProgressing = campaign.accountStates.contains { $0.miningStatus == .mining }
        if anyMinerActivelyProgressing || !queuedMinerNames(for: campaign).isEmpty {
            return .active
        }

        let hasAnyUserProgress = campaign.progress > 0 ||
            campaign.dropsClaimed > 0 ||
            campaign.accountStates.contains { $0.miningStatus == .claimed }
        if hasAnyUserProgress {
            return .inProgress
        }

        return Date() > campaign.endDate ? .expired : .idle
    }
}

// MARK: - Campaign Deck Card

private struct CampaignDeckCard: View {
    let campaign: CampaignViewData
    let state: CampaignCardState
    let queueWatchers: [String]
    var onSteamIdSet: ((String) async -> Void)?
    @State private var isHovered = false
    @State private var showingSteamIdPopover = false
    @State private var steamIdDraft = ""
    @State private var extractedArtworkTint: Color?

    private var shownDrops: [DropViewData] {
        Array(campaign.drops.prefix(3))
    }

    private var campaignGame: Game {
        Game(id: "", name: campaign.gameName, boxArtURL: campaign.artworkURL)
    }

    private var hasAccountLinkIssue: Bool {
        campaign.relevance == .prioritised
            && campaign.startDate <= Date()
            && campaign.endDate > Date()
            && !campaign.isAccountConnected
            && campaign.drops.contains(where: { !$0.isClaimed })
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
                progressMetadata

                if !campaign.accountStates.isEmpty {
                    CampaignAccountStrip(accountStates: campaign.accountStates)
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
                .strokeBorder(hasAccountLinkIssue ? .orange.opacity(0.36) : state.borderTint, lineWidth: 1)
        }
        .shadow(color: .black.opacity(isHovered ? 0.10 : 0.06), radius: isHovered ? 8 : 4, y: isHovered ? 4 : 2)
        .opacity(state == .expired ? 0.62 : 1)
        .saturation(1)
        .brightness(isHovered ? 0.008 : 0)
        .animation(.easeInOut(duration: 0.18), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .task(id: campaign.artworkURL?.absoluteString ?? campaign.id) {
            extractedArtworkTint = await CampaignArtworkTintSampler.shared.tintColor(from: campaign.artworkURL)
        }
        .contextMenu {
            Button {
                Settings.shared.setGamePreference(campaignGame, state: .preferred)
            } label: {
                Label("Prioritise Game", systemImage: "star")
            }

            Button {
                Settings.shared.setGamePreference(campaignGame, state: .excluded)
            } label: {
                Label("Exclude Game", systemImage: "minus.circle")
            }

            Divider()

            Button {
                steamIdDraft = ""
                showingSteamIdPopover = true
            } label: {
                Label("Set Steam ID", systemImage: "photo.artframe")
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
        if hasAccountLinkIssue {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("Link Required")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.orange.opacity(0.86), in: Capsule())
        } else {
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
                EmptyView()
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
    }

    private var statusLine: String {
        if hasAccountLinkIssue {
            return "Link the game publisher account on Twitch to start mining."
        }

        switch state {
        case .active:
            return "\(queueWatchersLabel) watching"
        case .inProgress:
            return "Tracking reward progress"
        case .claimable:
            return "Rewards ready to claim"
        case .claimed:
            return campaign.isClosed ? "Campaign closed" : "Completed"
        case .expired:
            return "Campaign window has ended"
        case .idle:
            return campaign.progress > 0 ? "In progress" : "Available"
        }
    }

    private var queueWatchersLabel: String {
        queueWatchers.isEmpty ? "Queued" : queueWatchers.joined(separator: ", ")
    }

    @ViewBuilder
    private var progressMetadata: some View {
        switch state {
        case .claimed:
            Label("Completed", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green.opacity(0.92))
        case .active, .inProgress, .claimable:
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: campaign.progress, total: 1.0)
                    .progressViewStyle(.linear)
                    .tint(state.tint)

                Text(progressSecondaryText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary.opacity(0.78))
            }
        case .idle:
            if hasAccountLinkIssue {
                Label("Account link required before rewards can be earned", systemImage: "link.badge.plus")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange.opacity(0.88))
            } else {
                Text(campaign.progress > 0 ? "In progress" : "Available")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary.opacity(0.86))
            }
        case .expired:
            Text("Expired")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var progressSecondaryText: String {
        if state == .claimable {
            return "Ready to claim"
        }

        if let timeRemaining = campaign.timeRemaining {
            return timeRemaining.formattedRemaining
        }

        return "In progress"
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.thinMaterial.opacity(0.98))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                materialTint.opacity(0.09),
                                materialTint.opacity(0.06),
                                materialTint.opacity(0.04)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .mask {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(
                                RadialGradient(
                                    colors: [
                                        .clear,
                                        .black.opacity(0.60),
                                        .black
                                    ],
                                    center: .center,
                                    startRadius: 12,
                                    endRadius: 240
                                )
                            )
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
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.white.opacity(0.10),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 150
                        )
                    )
            }
    }

    private var materialTint: Color {
        extractedArtworkTint ?? Color.gray
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
    private let avatarDiameter: CGFloat = 21

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: -avatarDiameter * 0.24) {
                ForEach(Array(accountStates.enumerated()), id: \.element.id) { index, account in
                    accountCircle(for: account)
                        .help("\(account.username) — \(statusTitle(for: account.miningStatus))")
                        .zIndex(Double(accountStates.count - index))
                }
            }
            .padding(.trailing, 6) // Breathing room for the last avatar
        }
        .frame(height: avatarDiameter + 4)
    }

    @ViewBuilder
    private func accountCircle(for account: AccountState) -> some View {
        let swatch = AvatarColorPalette.swatch(for: account.accountId, username: account.username)

        ZStack(alignment: .bottomTrailing) {
            Text(account.initials)
                .font(.system(size: avatarDiameter * 0.34, weight: .semibold, design: .rounded))
                .tracking(0.16)
                .foregroundStyle(swatch.text)
                .frame(width: avatarDiameter, height: avatarDiameter)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle()
                        .fill(swatch.gradient)
                        .opacity(0.9)
                }
                .overlay {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.24), .clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .opacity(0.72)
                }
                .overlay {
                    Circle()
                        .strokeBorder(.white.opacity(0.68), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.045), radius: 2, y: 1)

            if account.miningStatus == .mining {
                LivePulseDot(color: .green)
                    .offset(x: 1.5, y: 1.5)
            } else if account.miningStatus == .needsAuth {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.orange)
                    .padding(1.5)
                    .background(.regularMaterial, in: Circle())
                    .offset(x: 1.5, y: 1.5)
            } else if account.miningStatus == .claimed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.blue)
                    .padding(1.5)
                    .background(.regularMaterial, in: Circle())
                    .offset(x: 1.5, y: 1.5)
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
}

private struct LivePulseDot: View {
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: false)) { context in
            let scale = 0.92 + 0.16 * ((sin(context.date.timeIntervalSinceReferenceDate * 2.4) + 1) / 2)

            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .scaleEffect(scale)
                .shadow(color: color.opacity(0.28), radius: 3, y: 0.5)
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

private actor CampaignArtworkTintSampler {
    static let shared = CampaignArtworkTintSampler()

    private var cache: [URL: ArtworkRGB] = [:]
    private var inFlight: [URL: Task<ArtworkRGB?, Never>] = [:]

    func tintColor(from artworkURL: URL?) async -> Color? {
        guard let artworkURL else { return nil }

        if let cached = cache[artworkURL] {
            return cached.color
        }

        if let existingTask = inFlight[artworkURL] {
            return await existingTask.value?.color
        }

        let task = Task<ArtworkRGB?, Never> {
            await Self.fetchAndExtractTint(from: artworkURL.highResolutionArtworkURL)
        }
        inFlight[artworkURL] = task

        let extracted = await task.value
        inFlight[artworkURL] = nil

        if let extracted {
            cache[artworkURL] = extracted
        }

        return extracted?.color
    }

    private static func fetchAndExtractTint(from url: URL) async -> ArtworkRGB? {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                return nil
            }

            return extractDominantColor(from: data)?.softenedForGlass
        } catch {
            return nil
        }
    }

    private static func extractDominantColor(from data: Data) -> ArtworkRGB? {
        guard let ciImage = CIImage(data: data) else { return nil }
        let extent = ciImage.extent
        guard !extent.isEmpty else { return nil }

        guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)
        guard let outputImage = filter.outputImage else { return nil }

        let context = CIContext()
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            outputImage,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )

        return ArtworkRGB(
            red: Double(pixel[0]) / 255.0,
            green: Double(pixel[1]) / 255.0,
            blue: Double(pixel[2]) / 255.0
        )
    }
}

private struct ArtworkRGB: Sendable, Hashable {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color {
        Color(red: red.clamped01, green: green.clamped01, blue: blue.clamped01)
    }

    var softenedForGlass: ArtworkRGB {
        let luminance = ((red * 0.299) + (green * 0.587) + (blue * 0.114)).clamped01
        let desaturation: Double = 0.38
        let whiteMix: Double = 0.22

        let softenedRed = ((red * (1 - desaturation)) + (luminance * desaturation)).clamped01
        let softenedGreen = ((green * (1 - desaturation)) + (luminance * desaturation)).clamped01
        let softenedBlue = ((blue * (1 - desaturation)) + (luminance * desaturation)).clamped01

        return ArtworkRGB(
            red: ((softenedRed * (1 - whiteMix)) + whiteMix).clamped01,
            green: ((softenedGreen * (1 - whiteMix)) + whiteMix).clamped01,
            blue: ((softenedBlue * (1 - whiteMix)) + whiteMix).clamped01
        )
    }
}

private extension Double {
    var clamped01: Double {
        min(max(self, 0), 1)
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

    var formattedRemaining: String {
        let totalMinutes = max(Int(self / 60), 0)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return minutes > 0
                ? "\(hours)h \(minutes)m remaining"
                : "\(hours)h remaining"
        }

        return "\(minutes)m remaining"
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
