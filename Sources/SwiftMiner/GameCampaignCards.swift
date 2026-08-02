// Grouped game deck cards, reward cards, and hover popovers for the Drops list.
import SwiftUI
import SwiftMinerCore
import CoreImage

// MARK: - Grouped Game Card
struct GameCampaignDeckCard: View {
    let group: GameAggregate
    let selectedAccountId: String?
    let activityProvider: (CampaignViewData) -> CampaignActivitySnapshot
    var onSteamIdSet: ((String) async -> Void)?

    @State private var isHovered = false
    @State private var showingSteamIdPopover = false
    @State private var showingInspectorPopover = false
    @State private var steamIdDraft = ""
    @State private var extractedArtworkTint: Color?

    private var cardState: CampaignCardState {
        group.aggregateState.asCampaignCardState
    }

    private var isActive: Bool {
        group.aggregateState == .inProgress
    }

    private var isFinishedOrEnded: Bool {
        group.aggregateState == .completed || group.aggregateState == .unavailable
    }

    private var campaignGame: Game {
        let firstCampaign = group.campaigns.first?.campaign
        return Game(id: firstCampaign?.gameId ?? "", name: group.gameName, boxArtURL: group.artworkURL)
    }

    private var supportsSteamArtwork: Bool {
        let firstCampaign = group.campaigns.first?.campaign
        return SteamArtworkService.supportsSteamArtwork(forGameName: group.gameName, gameId: firstCampaign?.gameId)
    }

    private var minerAccountStates: [AccountState] {
        var mergedStates: [String: AccountState] = [:]

        for account in group.campaigns.flatMap(\.campaign.accountStates) {
            if let existing = mergedStates[account.accountId] {
                mergedStates[account.accountId] = preferredAccountState(existing, account)
            } else {
                mergedStates[account.accountId] = account
            }
        }

        let statusOrder: [AccountMiningStatus: Int] = [
            .needsAuth: 0,
            .claimedUnlinked: 1,
            .blocked: 2,
            .mining: 3,
            .ready: 4,
            .claimed: 5,
            .idle: 6
        ]

        let sorted = mergedStates.values.sorted {
            let lhsOrder = statusOrder[$0.miningStatus] ?? Int.max
            let rhsOrder = statusOrder[$1.miningStatus] ?? Int.max
            if lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }
            return $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending
        }

        guard let selectedAccountId else { return sorted }
        return sorted.filter { $0.accountId == selectedAccountId }
    }

    private var activeMinerCount: Int {
        let accountIds = Set(group.campaigns.flatMap { activityProvider($0.campaign).activeMiners.map(\.accountId) })
        guard let selectedAccountId else { return accountIds.count }
        return accountIds.contains(selectedAccountId) ? 1 : 0
    }

    private var completedCurrentRewardMinerCount: Int {
        let activeCampaigns = group.campaigns.filter { !$0.campaign.isExpired() }
        guard let currentCampaign = activeCampaigns.first(where: { activityProvider($0.campaign).state == .active || activityProvider($0.campaign).state == .inProgress })?.campaign
            ?? activeCampaigns.first?.campaign
        else { return 0 }

        let accountStates = currentCampaign.accountStates.filter { account in
            selectedAccountId == nil || account.accountId == selectedAccountId
        }

        return accountStates.filter { account in
            account.miningStatus == .claimed
                || account.miningStatus == .claimedUnlinked
                || account.claimedDropCount > 0
                || (account.progressFraction ?? 0) >= 0.995
        }.count
    }

    private var hasSubscriptionRequiredRewards: Bool {
        group.campaigns.contains { $0.campaign.hasSubscriptionRequiredRewards }
    }

    private var hasOnlySubscriptionRequiredRewards: Bool {
        let activeCampaigns = group.campaigns.filter { !$0.campaign.isExpired() && !$0.campaign.isCompleted }
        return !activeCampaigns.isEmpty && activeCampaigns.allSatisfy { $0.campaign.hasOnlySubscriptionRequiredRewards }
    }

    private func preferredAccountState(_ lhs: AccountState, _ rhs: AccountState) -> AccountState {
        let statusOrder: [AccountMiningStatus: Int] = [
            .needsAuth: 0,
            .claimedUnlinked: 1,
            .blocked: 2,
            .mining: 3,
            .ready: 4,
            .claimed: 5,
            .idle: 6
        ]

        let lhsOrder = statusOrder[lhs.miningStatus] ?? Int.max
        let rhsOrder = statusOrder[rhs.miningStatus] ?? Int.max

        if lhsOrder != rhsOrder {
            return lhsOrder < rhsOrder ? lhs : rhs
        }

        let lhsProgress = lhs.progressFraction ?? 0
        let rhsProgress = rhs.progressFraction ?? 0
        if lhsProgress != rhsProgress {
            return lhsProgress > rhsProgress ? lhs : rhs
        }

        return lhs.claimedDropCount >= rhs.claimedDropCount ? lhs : rhs
    }

    private func eligibleMiners(from minerAccountStates: [AccountState]) -> [AccountState] {
        minerAccountStates.filter { account in
            if Settings.shared.excludedGames.contains(where: { $0.localizedCaseInsensitiveCompare(group.gameName) == .orderedSame }) {
                return false
            }
            if isClaimedButNotLinked(account) {
                return true
            }
            if account.miningStatus == .blocked {
                return false
            }
            let gameId = group.campaigns.first?.campaign.gameId ?? ""
            if Settings.shared.isIgnoringAccountLinkWarnings(for: account.accountId, gameId: gameId) ||
               Settings.shared.isIgnoringAccountLinkWarnings(for: account.accountId, gameId: "all") {
                return false
            }
            let campaignId = group.campaigns.first?.campaign.id ?? ""
            if Settings.shared.isIgnoringSubscriptionRequiredWarnings(for: account.accountId, campaignId: campaignId) {
                return false
            }
            return true
        }
    }

    private var campaignExpiryText: String {
        guard let firstCampaign = group.campaigns.first?.campaign else { return "" }
        if firstCampaign.endDate <= Date() {
            return "Ended"
        }
        let remaining = firstCampaign.endDate.timeIntervalSince(Date())
        return remaining.formattedRemaining
    }

    private func aggregateStatusSummary(
        minerAccountStates: [AccountState],
        activeCount: Int,
        claimedCount: Int
    ) -> CardStatusSummary {
        if activeCount > 0 {
            let title = activeCount == 1 ? "1 Miner Active" : "\(activeCount) Miners Active"
            return CardStatusSummary(title: title, icon: "dot.radiowaves.left.and.right")
        }
        let claimedUnlinkedCount = minerAccountStates.filter(isClaimedButNotLinked).count
        if claimedUnlinkedCount > 0 {
            let title = claimedUnlinkedCount == 1
                ? "Claimed · not linked"
                : "\(claimedUnlinkedCount) claimed · not linked"
            return CardStatusSummary(title: title, icon: "checkmark.circle.badge.questionmark.fill")
        }
        if claimedCount == minerAccountStates.count && !minerAccountStates.isEmpty {
            return CardStatusSummary(title: "Completed", icon: "checkmark.circle.fill")
        }
        if claimedCount > 0 {
            let title = claimedCount == 1 ? "1 Miner Completed" : "\(claimedCount) Miners Completed"
            return CardStatusSummary(title: title, icon: "checkmark.circle.fill")
        }
        if hasOnlySubscriptionRequiredRewards {
            return CardStatusSummary(title: "Needs Sub", icon: "creditcard.fill")
        }
        if group.aggregateState == .actionRequired {
            return CardStatusSummary(title: "Needs Setup", icon: "exclamationmark.triangle.fill")
        }
        if group.aggregateState == .unavailable {
            return CardStatusSummary(title: "Campaign Ended", icon: "clock.badge.exclamationmark")
        }
        return CardStatusSummary(title: "Looking for Streams", icon: "antenna.radiowaves.left.and.right")
    }

    private func isClaimedButNotLinked(_ account: AccountState) -> Bool {
        account.miningStatus == .claimedUnlinked
            || (account.miningStatus == .blocked && (account.claimedDropCount > 0 || (account.progressFraction ?? 0) >= 0.995))
    }

    private var aggregateStatusColor: Color {
        if hasOnlySubscriptionRequiredRewards {
            return .pink
        }
        switch group.aggregateState {
        case .inProgress:
            return .green
        case .actionRequired:
            return .orange
        case .completed:
            return .green
        case .unavailable:
            return .secondary
        case .ready:
            return .secondary
        }
    }

    private var displayDrops: [DropViewData] {
        // Collapse repeated rewards across every campaign in this game group.
        // Twitch can expose the same reward through more than one campaign entry
        // (e.g. duplicate/region variants or a creators campaign that shares the
        // base drops), which would otherwise render the same reward tile twice.
        // Identity is the reward name + required watch time; fall back to the
        // drop id only when the name is missing.
        var seen = Set<String>()
        var result: [DropViewData] = []
        for item in group.campaigns {
            for drop in item.campaign.drops {
                let key = drop.name.isEmpty
                    ? drop.id
                    : "\(drop.name.lowercased())|\(drop.requiredMinutes)"
                if seen.insert(key).inserted {
                    result.append(drop)
                }
            }
        }
        return result
    }

    var body: some View {
        let drops = displayDrops
        let accountStates = minerAccountStates
        let eligibleMiners = eligibleMiners(from: accountStates)
        let status = aggregateStatusSummary(
            minerAccountStates: accountStates,
            activeCount: activeMinerCount,
            claimedCount: completedCurrentRewardMinerCount
        )

        HStack(alignment: .center, spacing: 16) {
            // LEFT ARTWORK (Anchors the cluster, prominent 120x160 size)
            GameArtworkCard(url: group.artworkURL, tint: group.aggregateState.tint)

            // CONTENT CLUSTER (titles, metadata, and reward shelf sit together)
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.gameName)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let firstCampaign = group.campaigns.first?.campaign {
                        Text(firstCampaign.campaignName)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    // Compact Metadata Row
                    HStack(spacing: 12) {
                        HStack(spacing: 4) {
                            Image(systemName: "gift.fill")
                            Text("\(drops.count) \(drops.count == 1 ? "reward" : "rewards")")
                        }
                        
                        if !campaignExpiryText.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "calendar")
                                Text(campaignExpiryText)
                            }
                        }
                        
                        let count = eligibleMiners.count
                        if count > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "person.2.fill")
                                Text("\(count) eligible")
                            }
                        }

                        if hasSubscriptionRequiredRewards {
                            HStack(spacing: 4) {
                                Image(systemName: "creditcard.fill")
                                Text("needs paid sub")
                            }
                            .foregroundStyle(.pink)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                // Reward Shelf directly beneath metadata
                if !drops.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 8) {
                            ForEach(drops) { drop in
                                BeautifulRewardCard(drop: drop)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 2)
                    }
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                } else {
                    Text("No rewards available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 64)
        }
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                // Compact Semantic Status Pill
                HStack(spacing: 4) {
                    AnimatedStatusIcon(symbol: status.icon, color: aggregateStatusColor, size: 10, weight: .semibold)
                    Text(status.title)
                        .font(.system(size: 10, weight: status.title == "Completed" ? .medium : .semibold))
                }
                .foregroundStyle(aggregateStatusColor.opacity(0.85))
                .padding(.horizontal, 8)
                .padding(.vertical, 4.5)
                .background(aggregateStatusColor.opacity(0.06), in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(aggregateStatusColor.opacity(0.15), lineWidth: 1)
                }
                .saturation(status.title == "Completed" ? 0.65 : 1.0)
                .opacity(status.title == "Completed" ? 0.85 : 1.0)

                Button {
                    showingInspectorPopover = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(.regularMaterial.opacity(0.65), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Show miner operational details")
                .popover(isPresented: $showingInspectorPopover, arrowEdge: .bottom) {
                    CampaignMinerInspectorPopover(gameName: group.gameName, miners: eligibleMiners)
                }
            }
            .padding(.top, 14)
            .padding(.trailing, 14)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(cardState.borderTint.opacity(isActive ? 0.75 : 0.40), lineWidth: isActive ? 1.0 : 0.6)
        }
        .shadow(
            color: isActive
                ? group.aggregateState.tint.opacity(isHovered ? 0.12 : 0.08)
                : .black.opacity(isHovered ? 0.08 : 0.04),
            radius: isHovered ? 8 : (isActive ? 6 : 3),
            y: isHovered ? 4 : (isActive ? 3 : 1)
        )
        .animation(.easeInOut(duration: 0.18), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
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

            if supportsSteamArtwork {
                Button {
                    steamIdDraft = ""
                    showingSteamIdPopover = true
                } label: {
                    Label("Set Steam ID", systemImage: "photo.artframe")
                }
            }
        }
        .popover(isPresented: $showingSteamIdPopover, arrowEdge: .bottom) {
            SteamIdInputPopover(
                gameName: group.gameName,
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
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(.thinMaterial.opacity(isActive ? 0.98 : 0.94))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                cardState.tint.opacity(isActive ? 0.11 : (isFinishedOrEnded ? 0.025 : 0.055)),
                                Color.white.opacity(isActive ? 0.055 : 0.025),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
    }
}

struct GameArtworkCard: View {
    let url: URL?
    let tint: Color

    var body: some View {
        CampaignCardArtwork(url: url, tint: tint)
            .frame(width: 120, height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
    }
}

struct BeautifulRewardCard: View {
    let drop: DropViewData
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .center) {
            // Main image thumbnail
            Group {
                if let url = drop.imageURL?.highResolutionArtworkURL {
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                    } placeholder: {
                        placeholderArtwork
                    }
                } else {
                    placeholderArtwork
                }
            }
            .frame(width: 76, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(isHovered ? 0.15 : 0.10), radius: isHovered ? 6 : 4, y: isHovered ? 3 : 2)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isHovered ? .white.opacity(0.20) : .white.opacity(0.08), lineWidth: 1)
            }

            // Completion checkmark (Frosted Glass Outer Circle, Apple Photos selection style)
            if drop.isClaimed {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.12), radius: 2)

                    Circle()
                        .fill(Color.green)
                        .frame(width: 13, height: 13)

                    Image(systemName: "checkmark")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 76, height: 76, alignment: .topTrailing)
                .padding(4)
            } else if drop.isSubscriptionRequired {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.12), radius: 2)

                    Circle()
                        .fill(Color.pink)
                        .frame(width: 13, height: 13)

                    Image(systemName: "creditcard.fill")
                        .font(.system(size: 6.5, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 76, height: 76, alignment: .topTrailing)
                .padding(4)
            } else if drop.isClaimable {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.12), radius: 2)
                    
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 13, height: 13)
                    
                    Image(systemName: "sparkles")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 76, height: 76, alignment: .topTrailing)
                .padding(4)
            }

            // Duration Overlay Badge (Bottom Right)
            Text(drop.isSubscriptionRequired && !drop.isClaimed ? "Sub" : "\(drop.requiredMinutes)m")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 4.5)
                .padding(.vertical, 2.5)
                .background((drop.isSubscriptionRequired && !drop.isClaimed ? Color.pink : Color.black).opacity(drop.isSubscriptionRequired && !drop.isClaimed ? 0.84 : 0.68), in: RoundedRectangle(cornerRadius: 4.5, style: .continuous))
                .frame(width: 76, height: 76, alignment: .bottomTrailing)
                .padding(4)
        }
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .popover(isPresented: $isHovered, arrowEdge: .top) {
            BeautifulRewardHoverCard(drop: drop)
        }
    }

    private var statusTitle: String {
        if drop.isClaimed { return "Claimed" }
        if drop.isClaimable { return "Ready to Claim" }
        if drop.isSubscriptionRequired { return "Needs Paid Sub" }
        if drop.progress > 0 { return "Mining (\(Int(drop.progress * 100))%)" }
        return "Locked"
    }

    private var placeholderArtwork: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.thinMaterial)
            .overlay {
                Image(systemName: rewardIcon)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.secondary)
            }
    }

    private var rewardIcon: String {
        switch drop.rewardType {
        case .badge: return "person.badge.shield.check.fill"
        case .emote: return "face.smiling.fill"
        case .inGame: return "gift.fill"
        }
    }
}

struct CardStatusSummary {
    let title: String
    let icon: String
}

// MARK: - Premium Frosted Hover Card Popover
struct BeautifulRewardHoverCard: View {
    let drop: DropViewData

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                // Tiny reward artwork preview!
                if let url = drop.imageURL?.highResolutionArtworkURL {
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 6).fill(.secondary.opacity(0.2))
                    }
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(drop.name)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    
                    Text(statusText)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(statusColor)
                }
            }
            
            if let desc = drop.description, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.system(size: 9))
                Text("Required: \(drop.requiredMinutes) min")
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(.secondary.opacity(0.8))
        }
        .padding(12)
        .frame(width: 200)
    }

    private var statusText: String {
        if drop.isClaimed { return "Claimed" }
        if drop.isClaimable { return "Ready to Claim" }
        if drop.isSubscriptionRequired { return "Needs Paid Sub" }
        if drop.progress > 0 { return "Mining (\(Int(drop.progress * 100))%)" }
        return "Locked"
    }

    private var statusColor: Color {
        if drop.isClaimed { return .green }
        if drop.isClaimable { return .orange }
        if drop.isSubscriptionRequired { return .pink }
        if drop.progress > 0 { return .blue }
        return .secondary
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
        let totalSeconds = max(self, 0)
        let totalDays = Int(totalSeconds / 86400)
        
        if totalDays == 0 {
            let hours = Int(totalSeconds / 3600)
            let minutes = Int((totalSeconds.truncatingRemainder(dividingBy: 3600)) / 60)
            if hours > 0 {
                return minutes > 0 ? "\(hours)h \(minutes)m left" : "\(hours)h left"
            }
            return "\(max(minutes, 1))m left"
        }
        
        let weeks = totalDays / 7
        let days = totalDays % 7
        
        if weeks > 0 {
            if days > 0 {
                return "\(weeks) \(weeks == 1 ? "week" : "weeks") and \(days) \(days == 1 ? "day" : "days") left"
            } else {
                return "\(weeks) \(weeks == 1 ? "week" : "weeks") left"
            }
        } else {
            return "\(days) \(days == 1 ? "day" : "days") left"
        }
    }
}

// MARK: - Steam ID Input Popover

struct SteamIdInputPopover: View {
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
