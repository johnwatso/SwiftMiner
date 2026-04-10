import SwiftUI
import SwiftMinerCore
import CoreImage

// MARK: - Drops List View

struct DropsListView: View {
    @Environment(NavigationModel.self) private var navigation
    @State private var filter: DropFilter = .active
    @State private var campaigns: [CampaignViewData] = []
    @State private var isRefreshing = false
    @AppStorage("preferSteamArtwork") private var preferSteamArtwork: Bool = false

    enum DropFilter: String, CaseIterable, Identifiable {
        case active = "Active"
        case claimable = "Claimable"
        case all = "All"

        var id: String { rawValue }
    }

    private var miners: [MinerManager.ManagedMiner] { navigation.minerManager.miners }
    private var hasAccounts: Bool { !miners.isEmpty }
    private var dropFilterItems: [GlassSelectionItem<DropFilter>] {
        [
            GlassSelectionItem(id: .active, title: "Active", systemImage: "dot.radiowaves.left.and.right"),
            GlassSelectionItem(id: .claimable, title: "Claimable", systemImage: "sparkles"),
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
                    title: "No campaigns yet",
                    message: "No campaigns yet",
                    description: "SwiftMiner will show campaigns here once your miners sync their latest Twitch drops data."
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
                        dashboardHeader

                        if let message = contextualBannerMessage {
                            fallbackBanner(message)
                        }

                        ForEach(renderedCampaigns) { campaign in
                            CampaignDeckCard(
                                campaign: campaign,
                                activity: activity(for: campaign),
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
                .help("Filter campaigns that are currently being mined, ready to claim, or part of your full campaign history.")
                .accessibilityLabel("Drops filter")
                .accessibilityHint("Choose Active, Claimable, or All campaigns.")
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

    private var activeMiningCampaigns: [CampaignViewData] {
        campaigns
            .filter { campaign in
                activity(for: campaign).state == .active
            }
            .sorted(by: campaignSort)
    }

    private var claimableCampaigns: [CampaignViewData] {
        campaigns
            .filter { activity(for: $0).claimableDropCount > 0 }
            .sorted(by: campaignSort)
    }

    private var renderedCampaigns: [CampaignViewData] {
        switch filter {
        case .active:
            return activeMiningCampaigns
        case .claimable:
            return claimableCampaigns
        case .all:
            return allCampaigns
        }
    }

    private var contextualBannerMessage: String? {
        switch filter {
        case .all where isRefreshing:
            return "Refreshing campaigns in the background"
        case .claimable where !claimableCampaigns.isEmpty && isRefreshing:
            return "Refreshing claimable rewards in the background"
        default:
            return nil
        }
    }

    private var emptyFilterMessage: String {
        switch filter {
        case .active:
            return "Nothing being mined right now"
        case .claimable:
            return "No rewards ready to claim yet"
        case .all:
            return "No campaigns yet"
        }
    }

    private var emptyFilterTitle: String {
        switch filter {
        case .active:
            return "Nothing being mined right now"
        case .claimable:
            return "No rewards ready to claim yet"
        case .all:
            return "No campaigns yet"
        }
    }

    private var emptyFilterDescription: String {
        switch filter {
        case .active:
            return "Start a miner or wait for Twitch to surface an eligible campaign, and active mining will appear here immediately."
        case .claimable:
            return "Rewards move here as soon as Twitch reports them ready to claim."
        case .all:
            return "Campaign history appears here once your miners have synced with Twitch."
        }
    }

    private var renderSignature: [String] {
        renderedCampaigns.map { campaign in
            let activity = activity(for: campaign)
            return "\(campaign.id)-\(activity.state.rawValue)-\(activity.activeMiners.count)-\(activity.claimableDropCount)-\(campaign.dropsClaimed)"
        }
    }

    private var dashboardHeader: some View {
        HStack(spacing: 12) {
            DashboardMetricCard(
                title: "Active miners",
                value: "\(miners.filter { $0.status == .watching || $0.status == .claiming }.count)",
                detail: "\(activeMiningCampaigns.count) \(activeMiningCampaigns.count == 1 ? "campaign" : "campaigns") in motion",
                tint: .green,
                systemImage: "person.2.fill"
            )

            DashboardMetricCard(
                title: "Rewards ready",
                value: claimableRewardCount == 0 ? "None" : "\(claimableRewardCount)",
                detail: claimableRewardCount == 0
                    ? "No rewards ready"
                    : "\(claimableCampaigns.count) \(claimableCampaigns.count == 1 ? "campaign" : "campaigns") waiting",
                tint: .orange,
                systemImage: "sparkles",
                isMuted: claimableRewardCount == 0
            )

            DashboardMetricCard(
                title: "Rewards claimed",
                value: "\(campaigns.reduce(0) { $0 + activity(for: $1).claimedRewardCount })",
                detail: "\(campaigns.count) \(campaigns.count == 1 ? "campaign" : "campaigns") tracked",
                tint: .blue,
                systemImage: "checkmark.circle.fill"
            )
        }
    }

    private var claimableRewardCount: Int {
        campaigns.reduce(0) { $0 + activity(for: $1).claimableDropCount }
    }

    @MainActor
    private func loadCampaignFeed() async {
        guard hasAccounts else {
            campaigns = []
            isRefreshing = false
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

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

        // Don't leave the UI waiting forever when one account is slow.
        // Let refresh continue in the background and apply results when ready.
        if !completedInTime {
            Task { @MainActor in
                await refreshTask.value
                guard hasAccounts else { return }
                let eventual = await navigation.minerManager.dataCoordinator.allCampaigns(
                    preferSteamArtwork: preferSteamArtwork
                )
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

        if !refreshed.isEmpty || campaigns.isEmpty {
            withAnimation(.easeInOut(duration: 0.24)) {
                campaigns = refreshed
            }
        }
    }

    private func activeMiners(for campaign: CampaignViewData) -> [MinerManager.ManagedMiner] {
        miners.filter { miner in
            guard miner.status == .watching || miner.status == .claiming else {
                return false
            }

            if let id = miner.currentCampaignId {
                return id == campaign.id
            }

            return miner.currentCampaign == campaign.campaignName
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
        let lhsActivity = activity(for: lhs)
        let rhsActivity = activity(for: rhs)

        if lhsActivity.state.priority != rhsActivity.state.priority {
            return lhsActivity.state.priority < rhsActivity.state.priority
        }

        if lhsActivity.activeMiners.count != rhsActivity.activeMiners.count {
            return lhsActivity.activeMiners.count > rhsActivity.activeMiners.count
        }

        if lhsActivity.claimableDropCount != rhsActivity.claimableDropCount {
            return lhsActivity.claimableDropCount > rhsActivity.claimableDropCount
        }

        if lhsActivity.claimedRewardCount != rhsActivity.claimedRewardCount {
            return lhsActivity.claimedRewardCount > rhsActivity.claimedRewardCount
        }

        return lhs.gameName < rhs.gameName
    }

    private func activity(for campaign: CampaignViewData) -> CampaignActivitySnapshot {
        let activeMiners = activeMiners(for: campaign)
        let claimedAccounts = campaign.accountStates.filter { $0.miningStatus == .claimed }
        let needsAuthAccounts = campaign.accountStates.filter { $0.miningStatus == .needsAuth }
        let claimableDropCount = campaign.drops.filter { $0.isClaimable && !$0.isClaimed }.count
        let claimedRewardCount = max(
            campaign.dropsClaimed,
            campaign.drops.filter(\.isClaimed).count
        )
        let remainingRewardCount = max(campaign.totalDrops - claimedRewardCount, 0)
        let allRewardsClaimed = remainingRewardCount == 0 && max(campaign.totalDrops, campaign.drops.count) > 0
        let isExpired = !allRewardsClaimed && Date() >= campaign.endDate

        let state: CampaignCardState
        if allRewardsClaimed {
            state = .claimed
        } else if isExpired {
            state = .expired
        } else if !activeMiners.isEmpty {
            state = .active
        } else if claimableDropCount > 0 {
            state = .claimable
        } else {
            state = .idle
        }

        return CampaignActivitySnapshot(
            state: state,
            activeMiners: activeMiners,
            claimedAccounts: claimedAccounts,
            needsAuthAccounts: needsAuthAccounts,
            claimableDropCount: claimableDropCount,
            claimedRewardCount: claimedRewardCount,
            remainingRewardCount: remainingRewardCount
        )
    }
}

// MARK: - Campaign Deck Card

private struct CampaignDeckCard: View {
    let campaign: CampaignViewData
    let activity: CampaignActivitySnapshot
    var onSteamIdSet: ((String) async -> Void)?
    @State private var isHovered = false
    @State private var showingSteamIdPopover = false
    @State private var steamIdDraft = ""
    @State private var extractedArtworkTint: Color?

    private var shownDrops: [DropViewData] {
        campaign.drops
    }

    private var campaignGame: Game {
        Game(id: "", name: campaign.gameName, boxArtURL: campaign.artworkURL)
    }

    private var hasAccountLinkIssue: Bool {
        campaign.startDate <= Date()
            && campaign.endDate > Date()
            && !campaign.isAccountConnected
            && activity.state != .claimed
    }

    private var isActive: Bool {
        activity.state == .active
    }

    private var statusSummary: String? {
        if hasAccountLinkIssue || !activity.needsAuthAccounts.isEmpty {
            return nil
        }

        switch activity.state {
        case .active:
            let minerCount = activity.activeMiners.count
            let minerCopy = "\(minerCount) miner\(minerCount == 1 ? "" : "s") watching now"
            if campaign.progress > 0 {
                return "\(minerCopy) • \(Int((campaign.progress * 100).rounded()))% complete"
            }
            return minerCopy
        case .claimable:
            return activity.claimableDropCount == 1
                ? "1 reward ready to claim"
                : "\(activity.claimableDropCount) rewards ready to claim"
        case .claimed:
            return "All campaign rewards claimed"
        case .expired:
            return "Campaign ended"
        case .inProgress:
            return campaign.progress > 0
                ? "\(Int((campaign.progress * 100).rounded()))% campaign progress"
                : nil
        case .idle:
            return activity.remainingRewardCount > 0
                ? "\(activity.remainingRewardCount) reward\(activity.remainingRewardCount == 1 ? "" : "s") still available"
                : nil
        }
    }

    private var requirementBannerCopy: (title: String, message: String, systemImage: String, tint: Color)? {
        if hasAccountLinkIssue {
            return (
                title: "Action required before mining can start",
                message: "Link the game account on Twitch to let miners earn these rewards.",
                systemImage: "link.badge.plus",
                tint: .orange
            )
        }

        if !activity.needsAuthAccounts.isEmpty {
            let accountCount = activity.needsAuthAccounts.count
            return (
                title: accountCount == 1 ? "1 miner needs attention" : "\(accountCount) miners need attention",
                message: "Reconnect the affected Twitch account\(accountCount == 1 ? "" : "s") before mining can continue.",
                systemImage: "exclamationmark.triangle.fill",
                tint: .orange
            )
        }

        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                CampaignArtworkIcon(url: campaign.artworkURL, tint: activity.state.tint)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(campaign.gameName)
                                .font(.title3.weight(.bold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Text(campaign.campaignName)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Spacer(minLength: 0)

                        HStack(spacing: 6) {
                            if isActive {
                                LivePulseDot(color: activity.state.tint)
                            } else {
                                Image(systemName: activity.state.symbol)
                                    .font(.caption2.weight(.bold))
                            }

                            Text(activity.state.title)
                                .lineLimit(1)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(activity.state.tint)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.regularMaterial.opacity(0.92), in: Capsule())
                    }

                    HStack(spacing: 8) {
                        CampaignMetricPill(
                            title: "\(activity.claimedRewardCount) claimed",
                            systemImage: "checkmark.circle.fill",
                            tint: .blue
                        )
                        CampaignMetricPill(
                            title: "\(activity.remainingRewardCount) remaining",
                            systemImage: "gift.fill",
                            tint: .secondary
                        )

                        if activity.claimableDropCount > 0 {
                            CampaignMetricPill(
                                title: "\(activity.claimableDropCount) ready",
                                systemImage: "sparkles",
                                tint: .orange
                            )
                        }
                    }

                    if let statusSummary {
                        Text(statusSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if isActive && campaign.progress > 0 {
                        ProgressView(value: campaign.progress, total: 1.0)
                            .progressViewStyle(.linear)
                            .tint(activity.state.tint)
                            .padding(.top, 2)
                    } else if isActive {
                        ProgressView()
                            .controlSize(.small)
                            .tint(activity.state.tint)
                            .padding(.top, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            if let requirementBannerCopy {
                CampaignRequirementBanner(
                    title: requirementBannerCopy.title,
                    message: requirementBannerCopy.message,
                    systemImage: requirementBannerCopy.systemImage,
                    tint: requirementBannerCopy.tint
                )
            }

            if shownDrops.isEmpty {
                Text("No rewards available for this campaign.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(shownDrops) { drop in
                        CampaignDropPreviewRow(
                            drop: drop,
                            activity: activity
                        )
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
                .strokeBorder(
                    hasAccountLinkIssue ? .orange.opacity(0.36) : activity.state.borderTint,
                    lineWidth: isActive ? 1.2 : 1
                )
        }
        .shadow(
            color: isActive
                ? activity.state.tint.opacity(isHovered ? 0.18 : 0.10)
                : .black.opacity(isHovered ? 0.10 : 0.06),
            radius: isHovered ? 10 : (isActive ? 8 : 4),
            y: isHovered ? 5 : (isActive ? 4 : 2)
        )
        .opacity(activity.state == .expired ? 0.62 : 1)
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

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.thinMaterial.opacity(isActive ? 0.98 : 0.95))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                materialTint.opacity(isActive ? 0.10 : 0.05),
                                materialTint.opacity(isActive ? 0.05 : 0.025),
                                Color.white.opacity(isActive ? 0.045 : 0.02)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isActive ? 0.12 : 0.08),
                                activity.state.tint.opacity(activity.state == .claimed ? 0.02 : (isActive ? 0.06 : 0.03)),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: UnitPoint(x: 0.75, y: 0.65)
                        )
                    )
            }
    }

    private var materialTint: Color {
        extractedArtworkTint ?? Color.gray
    }
}

// MARK: - Activity Support

private struct CampaignActivitySnapshot {
    let state: CampaignCardState
    let activeMiners: [MinerManager.ManagedMiner]
    let claimedAccounts: [AccountState]
    let needsAuthAccounts: [AccountState]
    let claimableDropCount: Int
    let claimedRewardCount: Int
    let remainingRewardCount: Int
}

private struct DashboardMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let tint: Color
    let systemImage: String
    var isMuted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isMuted ? .tertiary : .secondary)

            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(isMuted ? .secondary : .primary)

            Text(detail)
                .font(.caption)
                .foregroundStyle(isMuted ? .tertiary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial.opacity(isMuted ? 0.78 : 0.88), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tint.opacity(isMuted ? 0.08 : 0.14), lineWidth: 1)
        }
        .opacity(isMuted ? 0.82 : 1)
    }
}

private struct CampaignMetricPill: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.regularMaterial.opacity(0.72), in: Capsule())
    }
}

private struct CampaignRequirementBanner: View {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 1)
        }
    }
}

// MARK: - Drop Preview Row

private struct CampaignDropPreviewRow: View {
    let drop: DropViewData
    let activity: CampaignActivitySnapshot

    private var status: DropPreviewState {
        if drop.isClaimed { return .claimed }
        if drop.isClaimable { return .claimable }
        if drop.progress > 0 || !activity.activeMiners.isEmpty {
            return .inProgress
        }
        return .locked
    }

    private var showsProgressBar: Bool {
        activity.state == .active && drop.progress > 0 && !drop.isClaimed && !drop.isClaimable
    }

    private var progressPercent: Int {
        Int((drop.progress * 100).rounded())
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            thumbnail

            VStack(alignment: .leading, spacing: 3) {
                Text(drop.name)
                    .font(.subheadline.weight(activity.state == .active ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text("Watch \(drop.requiredMinutes) minutes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Group {
                if showsProgressBar {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("\(progressPercent)%")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)

                        ProgressView(value: drop.progress, total: 1.0)
                            .progressViewStyle(.linear)
                            .tint(status.tint)
                            .frame(width: 44)
                    }
                } else {
                    Image(systemName: status.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(status.tint)
                        .frame(width: 20, height: 20)
                }
            }
            .help(status.title)
        }
        .padding(.vertical, 8)
        .help(status.helpText)
    }

    private var thumbnail: some View {
        Group {
            if let url = drop.imageURL {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                } placeholder: {
                    thumbnailPlaceholder
                }
            } else {
                thumbnailPlaceholder
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        }
    }

    private var thumbnailPlaceholder: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(.thinMaterial)
            .overlay {
                Image(systemName: "gift.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
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
        case .active: return "Watching now"
        case .inProgress: return "In progress"
        case .claimable: return "Reward ready"
        case .claimed: return "All rewards claimed"
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
        case .idle: return "person.crop.circle.badge.xmark"
        }
    }

    var tint: Color {
        switch self {
        case .active: return .green
        case .inProgress: return .blue
        case .claimable: return .secondary
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
            return .white.opacity(0.12)
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

    var title: String {
        switch self {
        case .claimed: return "Claimed"
        case .claimable: return "Claimable"
        case .inProgress: return "In progress"
        case .locked: return "Locked"
        }
    }

    var symbol: String {
        switch self {
        case .claimed: return "checkmark.circle.fill"
        case .claimable: return "sparkles"
        case .inProgress: return "chart.bar.fill"
        case .locked: return "lock.fill"
        }
    }

    var tint: Color {
        switch self {
        case .claimed: return .green
        case .claimable: return .orange
        case .inProgress: return .blue
        case .locked: return .secondary
        }
    }

    var helpText: String {
        switch self {
        case .claimed: return "Reward already claimed"
        case .claimable: return "Reward ready to claim"
        case .inProgress: return "Reward currently being mined"
        case .locked: return "Reward not available yet"
        }
    }
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
