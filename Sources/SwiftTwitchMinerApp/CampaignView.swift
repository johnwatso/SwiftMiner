import SwiftUI
import SwiftTwitchMiner

// MARK: - Drops List View

struct DropsListView: View {
    @Environment(NavigationModel.self) private var navigation
    @State private var filter: DropFilter = .active
    @State private var campaigns: [CampaignViewData] = []
    @State private var isRefreshing = false
    @State private var hasLoadedFeed = false

    enum DropFilter: String, CaseIterable, Identifiable {
        case active = "Active"
        case claimed = "Claimed"
        case all = "All"

        var id: String { rawValue }
    }

    private var miners: [MinerManager.ManagedMiner] { navigation.minerManager.miners }
    private var hasAccounts: Bool { !miners.isEmpty }
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
                    description: "Cached campaigns will appear here instantly as soon as data is available."
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
                                state: cardState(for: campaign),
                                queueWatchers: queuedMinerNames(for: campaign)
                            )
                            .transition(.opacity.combined(with: .scale(scale: 0.985)))
                        }
                    }
                    .padding(24)
                }
                .scrollContentBackground(.hidden)
                .animation(.easeInOut(duration: 0.28), value: renderSignature)
            }
        }
        .navigationTitle("Drops")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    Task {
                        let settings = Settings.shared
                        await navigation.minerManager.startAll(
                            priorityGames: settings.priorityGames,
                            excludedGames: settings.excludedGames,
                            strategy: settings.miningStrategy,
                            enableBadgesEmotes: settings.enableBadgesEmotes
                        )
                    }
                } label: {
                    Label("Start All", systemImage: "play.fill")
                }
                .help("Start all miners")

                Button {
                    Task { await navigation.minerManager.stopAll() }
                } label: {
                    Label("Stop All", systemImage: "stop.fill")
                }
                .help("Stop all miners")
            }

            ToolbarItem(placement: .primaryAction) {
                Picker("Filter", selection: $filter) {
                    ForEach(DropFilter.allCases) { choice in
                        Text(choice.rawValue).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }
        }
        .task(id: accountSignature) {
            await loadCampaignFeed()
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

                Text("Cached drops will appear instantly on future launches.")
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

            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.thinMaterial.opacity(0.84))
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Campaigns update in place")
                            .font(.headline.weight(.semibold))

                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                }
                .frame(height: 220)
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
        .background(.ultraThinMaterial.opacity(0.75), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Data

    private var allCampaigns: [CampaignViewData] {
        campaigns.sorted(by: campaignSort)
    }

    private var activeQueueCampaigns: [CampaignViewData] {
        campaigns
            .filter { !queuedMinerNames(for: $0).isEmpty }
            .sorted(by: campaignSort)
    }

    private var claimedCampaigns: [CampaignViewData] {
        campaigns
            .filter(isClaimedCampaign(_:))
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
            return "Claimed campaigns will appear here automatically as inventory-backed status updates arrive."
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

        let cached = await navigation.minerManager.dataCoordinator.currentCampaigns()
        await MainActor.run {
            if !cached.isEmpty {
                withAnimation(.easeInOut(duration: 0.2)) {
                    campaigns = cached
                }
            }
            isRefreshing = true
        }

        await navigation.minerManager.dataCoordinator.refreshAll()
        let refreshed = await navigation.minerManager.dataCoordinator.currentCampaigns()

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

    private func isClaimedCampaign(_ campaign: CampaignViewData) -> Bool {
        campaign.isClaimed ||
        campaign.miningStatus == .claimed ||
        campaign.accountStates.contains(where: { $0.miningStatus == .claimed })
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
    let state: CampaignCardState
    let queueWatchers: [String]

    @State private var isExpanded: Bool

    init(campaign: CampaignViewData, state: CampaignCardState, queueWatchers: [String]) {
        self.campaign = campaign
        self.state = state
        self.queueWatchers = queueWatchers
        self._isExpanded = State(initialValue: state == .active || state == .claimable || state == .inProgress)
    }

    private var shownDrops: [DropViewData] {
        if isExpanded {
            return campaign.drops
        }
        return Array(campaign.drops.prefix(3))
    }

    private var progressPercent: Int {
        Int((campaign.progress * 100).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                    isExpanded.toggle()
                }
            } label: {
                VStack(alignment: .leading, spacing: 16) {
                    hero

                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(campaign.gameName)
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.78))

                            Text(campaign.campaignName)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.leading)

                            Text(summaryText)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.84))
                        }

                        Spacer(minLength: 0)

                        VStack(alignment: .trailing, spacing: 10) {
                            CampaignStatePill(state: state)

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

                        if state == .inProgress || state == .active || state == .claimable {
                            ProgressView(value: campaign.progress, total: 1.0)
                                .progressViewStyle(.linear)
                                .tint(state.tint)
                        }
                    }
                }
                .padding(18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !shownDrops.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(shownDrops) { drop in
                        CampaignDropPreviewRow(drop: drop)
                    }

                    if !isExpanded && campaign.drops.count > shownDrops.count {
                        Text("Show \(campaign.drops.count - shownDrops.count) more drops")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(backgroundLayer)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(state.borderTint, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.10), radius: 18, y: 10)
        .opacity(state == .expired ? 0.62 : (state == .claimed ? 0.78 : 1))
        .saturation(state == .claimed ? 0.82 : 1)
    }

    @ViewBuilder
    private var hero: some View {
        ZStack(alignment: .topLeading) {
            CampaignCardArtwork(url: campaign.artworkURL, tint: state.tint)
                .frame(height: 148)

            LinearGradient(
                colors: [.black.opacity(0.10), .black.opacity(0.58)],
                startPoint: .top,
                endPoint: .bottom
            )

            if state == .active {
                HStack(spacing: 8) {
                    LivePulseDot(color: state.tint)
                    Text("Running now")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.94))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(14)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var backgroundLayer: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(.thinMaterial.opacity(0.88))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.08),
                                state.tint.opacity(state == .claimed ? 0.05 : 0.12),
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

    private var summaryText: String {
        switch state {
        case .active:
            return queueWatchers.isEmpty ? "Queued right now" : "\(queueWatchers.joined(separator: ", ")) watching"
        case .inProgress:
            if let timeRemaining = campaign.timeRemaining {
                return "\(progressPercent)% complete with \(timeRemaining.formattedHoursMinutes) remaining"
            }
            return "\(progressPercent)% complete across cached progress"
        case .claimable:
            return "Rewards are ready to claim"
        case .claimed:
            return "Everything here has been claimed"
        case .expired:
            return "Campaign window has ended"
        case .idle:
            return "Available in your cached campaign history"
        }
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
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

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
        .background(.ultraThinMaterial.opacity(0.86), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .opacity(primaryState == .locked ? 0.72 : 1)
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
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
        .foregroundStyle(.white.opacity(0.86))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

private struct CampaignAccountStrip: View {
    let accountStates: [AccountState]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(accountStates.prefix(5)) { account in
                Text(account.initials)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(width: 24, height: 24)
                    .background(backgroundColor(for: account.miningStatus), in: Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    }
            }

            if accountStates.count > 5 {
                Text("+\(accountStates.count - 5)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func backgroundColor(for status: AccountMiningStatus) -> Color {
        switch status {
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

    var body: some View {
        ZStack {
            if let url {
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
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [tint.opacity(0.82), tint.opacity(0.38), Color.black.opacity(0.52)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
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

// MARK: - Preview

#Preview("Drops List") {
    DropsListView()
        .environment(NavigationModel(clientId: "preview"))
        .frame(width: 700, height: 680)
}
