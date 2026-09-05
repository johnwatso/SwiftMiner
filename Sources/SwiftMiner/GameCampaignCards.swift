// Grouped game deck cards, reward cards, and hover popovers for the Drops list.
import SwiftUI
import SwiftMinerCore
import CoreImage

/// A grouped game card can contain an unfinished campaign and an older campaign whose
/// reward is already claimed but still inside its advertised window. The unfinished state
/// must win; otherwise the whole game card falsely reads "claimed · not linked".
func dropsCardAccountStatusPriority(_ status: AccountMiningStatus) -> Int {
    switch status {
    case .needsAuth: return 0
    case .blocked: return 1
    case .mining: return 2
    case .ready: return 3
    case .claimedUnlinked: return 4
    case .claimed: return 5
    case .idle: return 6
    }
}

/// `claimedDropCount > 0` means a campaign has started paying out, not that it is finished.
/// Keep the near-complete fallback for older snapshots that predate `claimedUnlinked`, but do
/// not let one claimed tier turn a partially complete campaign into a delivery-only state.
func isDropsCardClaimedButNotLinked(_ account: AccountState) -> Bool {
    account.miningStatus == .claimedUnlinked
        || (account.miningStatus == .blocked && (account.progressFraction ?? 0) >= 0.995)
}

/// Completion is a campaign-level state. A non-zero claimed count only proves that one
/// reward tier completed, which is not enough for a grouped card to say the miner is done.
func isDropsCardCompleted(_ account: AccountState) -> Bool {
    account.miningStatus == .claimed
        || account.miningStatus == .claimedUnlinked
        || (account.progressFraction ?? 0) >= 0.995
}

// MARK: - Grouped Game Card
struct GameCampaignDeckCard: View {
    let group: GameAggregate
    let selectedAccountId: String?
    let activityProvider: (CampaignViewData) -> CampaignActivitySnapshot

    @State private var isHovered = false
    @State private var showingInspectorPopover = false
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

    private var minerAccountStates: [AccountState] {
        var mergedStates: [String: AccountState] = [:]

        for account in group.campaigns.flatMap(\.campaign.accountStates) {
            if let existing = mergedStates[account.accountId] {
                mergedStates[account.accountId] = preferredAccountState(existing, account)
            } else {
                mergedStates[account.accountId] = account
            }
        }

        let sorted = mergedStates.values.sorted {
            let lhsOrder = dropsCardAccountStatusPriority($0.miningStatus)
            let rhsOrder = dropsCardAccountStatusPriority($1.miningStatus)
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

        return accountStates.filter(isDropsCardCompleted).count
    }

    private var hasSubscriptionRequiredRewards: Bool {
        group.campaigns.contains { $0.campaign.hasSubscriptionRequiredRewards }
    }

    private var hasOnlySubscriptionRequiredRewards: Bool {
        let activeCampaigns = group.campaigns.filter { !$0.campaign.isExpired() && !$0.campaign.isCompleted }
        return !activeCampaigns.isEmpty && activeCampaigns.allSatisfy { $0.campaign.hasOnlySubscriptionRequiredRewards }
    }

    private func preferredAccountState(_ lhs: AccountState, _ rhs: AccountState) -> AccountState {
        let lhsOrder = dropsCardAccountStatusPriority(lhs.miningStatus)
        let rhsOrder = dropsCardAccountStatusPriority(rhs.miningStatus)

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
        // The game is either excluded or it is not; asking once per miner rescanned the
        // whole exclusion list for the same answer.
        let isExcludedGame = Settings.shared.excludedGames.contains {
            $0.localizedCaseInsensitiveCompare(group.gameName) == .orderedSame
        }
        guard !isExcludedGame else { return [] }

        return minerAccountStates.filter { account in
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
            return CardStatusSummary(title: title, icon: "bolt.fill")
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
        isDropsCardClaimedButNotLinked(account)
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
            GameArtworkCard(url: group.artworkURL)

            // CONTENT CLUSTER (titles, metadata, and reward shelf sit together)
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.gameName)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let firstCampaign = group.campaigns.first?.campaign {
                        let additionalCampaignCount = group.campaigns.count - 1
                        Text(
                            additionalCampaignCount > 0
                                ? "\(firstCampaign.campaignName) + \(additionalCampaignCount) more"
                                : firstCampaign.campaignName
                        )
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
                        LazyHStack(alignment: .top, spacing: 12) {
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
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(.thinMaterial.opacity(isActive ? 0.98 : 0.94))
    }
}

struct GameArtworkCard: View {
    let url: URL?

    var body: some View {
        CampaignCardArtwork(url: url)
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

    /// Deliberately smaller than the 120x160 game artwork, so each card keeps one
    /// dominant image, but large enough to read mixed reward shapes at a glance.
    private let wellSize: CGFloat = 88
    private let wellRadius: CGFloat = 12

    var body: some View {
        VStack(spacing: 6) {
            rewardWell
            durationLabel
        }
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(helpText)
    }

    /// Twitch reward art arrives at assorted aspect ratios with transparent bounds, so a
    /// bare thumbnail leaves the row looking ragged. Each reward is fitted — never
    /// cropped — inside a shared well, and it is the well, not the artwork, that aligns
    /// the row. The fill sits just above the card behind it; any heavier and the shelf
    /// reads as a row of nested cards.
    private var rewardWell: some View {
        artwork
            .padding(10)
            .frame(width: wellSize, height: wellSize)
            .background(
                RoundedRectangle(cornerRadius: wellRadius, style: .continuous)
                    .fill(.white.opacity(isHovered ? 0.10 : 0.06))
            )
            .overlay {
                RoundedRectangle(cornerRadius: wellRadius, style: .continuous)
                    .strokeBorder(.white.opacity(isHovered ? 0.16 : 0.08), lineWidth: 1)
            }
            .overlay(alignment: .topTrailing) {
                statusBadge.padding(5)
            }
    }

    private var artwork: some View {
        Group {
            if let url = drop.imageURL?.highResolutionArtworkURL {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } placeholder: {
                    placeholderArtwork
                }
            } else {
                placeholderArtwork
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if drop.isClaimed {
            badge("checkmark", color: .green, glyphSize: 9)
        } else if drop.isSubscriptionRequired {
            badge("creditcard.fill", color: .pink, glyphSize: 8)
        } else if drop.isClaimable {
            badge("sparkles", color: .orange, glyphSize: 9)
        }
    }

    /// A solid disc reads clearly on its own. The frosted ring this used to sit in only
    /// drew a second edge around the glyph.
    private func badge(_ symbol: String, color: Color, glyphSize: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.system(size: glyphSize, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(Circle().fill(color))
            .shadow(color: .black.opacity(0.25), radius: 2)
    }

    /// Sits under the well rather than over the art, so nothing covers a reward.
    private var durationLabel: some View {
        let needsSubscription = drop.isSubscriptionRequired && !drop.isClaimed
        return HStack(spacing: 3) {
            Image(systemName: needsSubscription ? "creditcard.fill" : "timer")
                .font(.system(size: 8, weight: .semibold))
            Text(needsSubscription ? "Sub" : "\(drop.requiredMinutes)m")
                .font(.system(size: 10, weight: .medium, design: .rounded))
        }
        .foregroundStyle(needsSubscription ? AnyShapeStyle(Color.pink) : AnyShapeStyle(.secondary))
        .lineLimit(1)
    }

    /// The card already shows the artwork, the claim state and the required minutes.
    /// Only the reward's name and description are worth surfacing on hover, so this is
    /// a tooltip rather than a popover covering the cards around it.
    private var helpText: String {
        var lines = ["\(drop.name) — \(statusTitle)"]
        if let description = drop.description, !description.isEmpty {
            lines.append(description)
        }
        lines.append("Requires \(drop.requiredMinutes) min")
        return lines.joined(separator: "\n")
    }

    private var statusTitle: String {
        if drop.isClaimed { return "Claimed" }
        if drop.isClaimable { return "Ready to Claim" }
        if drop.isSubscriptionRequired { return "Needs Paid Sub" }
        if drop.progress > 0 { return "Mining (\(Int(drop.progress * 100))%)" }
        return "Locked"
    }

    /// The well already supplies the surface, so the placeholder is just the glyph.
    private var placeholderArtwork: some View {
        Image(systemName: rewardIcon)
            .font(.system(size: 24, weight: .medium))
            .foregroundStyle(.secondary)
    }

    private var rewardIcon: String {
        switch drop.rewardType {
        case .badge: return SystemSymbolCompatibility.resolvedName(for: "person.badge.shield.check.fill")
        case .emote: return "face.smiling.fill"
        case .inGame: return "gift.fill"
        }
    }
}

struct CardStatusSummary {
    let title: String
    let icon: String
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
