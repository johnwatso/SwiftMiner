import SwiftUI
import SwiftTwitchMiner

// MARK: - Sidebar

/// Sidebar list of all active campaigns.
struct CampaignSidebarView: View {
    @Environment(AppModel.self) private var appModel
    @Binding var selectedId: String?

    private var campaigns: [Campaign] { appModel.campaigns }

    var body: some View {
        List(campaigns, selection: $selectedId) { campaign in
            CampaignRowView(campaign: campaign)
                .tag(campaign.id)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Campaigns")
        .overlay {
            if campaigns.isEmpty {
                MaterialEmptyStatePanel(
                    "No Active Campaigns",
                    systemImage: "calendar.badge.exclamationmark",
                    description: "Start the miner to fetch campaigns."
                )
            }
        }
    }
}

/// One row in the campaign sidebar.
struct CampaignRowView: View {
    let campaign: Campaign

    private var claimedCount: Int { campaign.drops.filter(\.isClaimed).count }
    private var totalCount: Int   { campaign.drops.count }

    var body: some View {
        HStack(spacing: 10) {
            // Game box art
            if let url = campaign.game.boxArtURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.tertiary)
                }
                .frame(width: 36, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.tertiary)
                    .frame(width: 36, height: 48)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(campaign.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)

                Text(campaign.game.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("\(claimedCount)/\(totalCount) drops")
                    .font(.caption2)
                    .foregroundStyle(claimedCount == totalCount ? .green : .secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Campaign Detail

/// Detail panel showing the drops for a selected campaign.
struct CampaignDetailView: View {
    let campaign: CampaignViewData
    @Environment(NavigationModel.self) private var navigation
    @ObservedObject private var settings = Settings.shared

    private var bannerURL: URL? {
        guard settings.preferSteamArtwork else { return nil }
        return navigation.minerManager.dataCoordinator.steamHeroOverrides[campaign.gameName]
    }

    var body: some View {
        ZStack {
            if let bannerURL {
                AsyncImage(url: bannerURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .blur(radius: 40, opaque: true)
                        .opacity(0.4)
                        .overlay {
                            Color.black.opacity(0.2)
                        }
                } placeholder: {
                    Color.clear
                }
                .ignoresSafeArea()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    campaignHeader

                    if campaign.drops.isEmpty {
                        MaterialEmptyStatePanel(
                            "No drops available",
                            systemImage: "gift.slash",
                            description: "This campaign doesn’t have any drop items to display yet."
                        )
                        .frame(maxWidth: .infinity)
                    } else {
                        VStack(spacing: 12) {
                            ForEach(campaign.drops) { drop in
                                DropRowView(drop: drop, fallbackURL: campaign.artworkURL)
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
        .navigationTitle(campaign.gameName)
    }

    private var campaignHeader: some View {
        HStack(spacing: 16) {
            campaignArtwork

            VStack(alignment: .leading, spacing: 6) {
                Text(campaign.gameName)
                    .font(.title3.weight(.semibold))

                Text(campaign.campaignName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Text("\(campaign.dropsClaimed)/\(campaign.totalDrops) claimed")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let timeRemaining = campaign.timeRemaining {
                        Text("•")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(timeRemaining.formattedHoursMinutes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 0)

            CampaignStatusPill(title: campaign.status, claimed: campaign.isClaimed)
        }
        .padding(18)
        .glassContentSurface(cornerRadius: 26)
    }

    @ViewBuilder
    private var campaignArtwork: some View {
        if let url = campaign.artworkURL {
            AsyncImage(url: url) { image in
                image
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } placeholder: {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.thinMaterial)
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.thinMaterial)
                .overlay {
                    Image(systemName: "gamecontroller.fill")
                        .foregroundStyle(.secondary)
                }
                .frame(width: 72, height: 72)
        }
    }
}

/// One row for a single drop.
struct DropRowView: View {
    let drop: DropViewData
    /// Fallback image URL (e.g., campaign artwork) when drop image is missing
    var fallbackURL: URL? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            dropArtwork

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Text(drop.name)
                        .font(.headline)
                        .lineLimit(2)

                    Spacer(minLength: 0)

                    DropStateBadge(drop: drop)
                }

                ProgressView(value: drop.progress, total: 1.0)
                    .progressViewStyle(.linear)
                    .tint(progressTint)

                HStack(spacing: 8) {
                    Text("\(drop.currentMinutes) / \(drop.requiredMinutes) min")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let description = drop.description, !description.isEmpty {
                        Text("•")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(16)
        .glassPanel(cornerRadius: 22)
        .opacity(drop.isEarnable || drop.isClaimable || drop.isClaimed ? 1.0 : 0.62)
    }

    /// Determines the best URL to use: drop image first, then fallback, then nil
    private var imageURLToUse: URL? {
        drop.imageURL ?? fallbackURL
    }

    @ViewBuilder
    private var dropArtwork: some View {
        if let url = imageURLToUse {
            AsyncImage(url: url) { image in
                image
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } placeholder: {
                placeholderArtwork
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            placeholderArtwork
                .frame(width: 52, height: 52)
        }
    }

    private var placeholderArtwork: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.thinMaterial)
            .overlay {
                Image(systemName: rewardIcon)
                    .font(.system(size: 18, weight: .medium))
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

    private var progressTint: Color {
        if drop.isClaimed { return .green }
        if drop.isClaimable { return .blue }
        if drop.isEarnable { return .accentColor }
        return .secondary
    }
}

// MARK: - Badges

private extension TimeInterval {
    var formattedHoursMinutes: String {
        let totalMinutes = max(Int(self / 60), 0)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m remaining"
        }
        return "\(minutes)m remaining"
    }
}

private struct CampaignStatusPill: View {
    let title: String
    let claimed: Bool

    var body: some View {
        Text(claimed ? "Completed" : title.replacingOccurrences(of: "_", with: " ").capitalized)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(claimed ? .green : .secondary)
            .glassControlSurface(cornerRadius: 999)
    }
}

private struct DropStateBadge: View {
    let drop: DropViewData

    var body: some View {
        Label(title, systemImage: icon)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .foregroundStyle(color)
            .background(backgroundColor, in: Capsule())
    }

    private var title: String {
        if drop.isClaimed { return "Claimed" }
        if drop.isClaimable { return "Claimable" }
        if drop.isEarnable { return "Earnable" }
        return "Locked"
    }

    private var icon: String {
        if drop.isClaimed { return "checkmark.circle.fill" }
        if drop.isClaimable { return "sparkles" }
        if drop.isEarnable { return "circle.fill" }
        return "lock.fill"
    }

    private var color: Color {
        if drop.isClaimed { return .green }
        if drop.isClaimable { return .blue }
        if drop.isEarnable { return .secondary }
        return .secondary.opacity(0.8)
    }

    private var backgroundColor: Color {
        if drop.isClaimed { return .green.opacity(0.12) }
        if drop.isClaimable { return .blue.opacity(0.12) }
        if drop.isEarnable { return .white.opacity(0.08) }
        return .white.opacity(0.05)
    }
}

// MARK: - Status indicator (toolbar)

/// Shows the current session status in the toolbar.
struct StatusIndicatorView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusColor.opacity(0.6), radius: 3)

            Text(appModel.sessionStatus.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)

            if let progress = appModel.overallProgress {
                Text("·")
                    .foregroundStyle(.secondary)
                Text("\(progress.claimedDrops)/\(progress.totalDrops) drops")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusColor: Color {
        switch appModel.sessionStatus {
        case .watching:          return .green
        case .authenticating:    return .orange
        case .fetchingCampaigns: return .blue
        case .claiming:          return .yellow
        case .error:             return .red
        case .stopped, .idle:    return .gray
        case .paused:            return .orange
        }
    }
}

// MARK: - Log console

/// Scrolling log console for the detail column.
struct LogConsoleView: View {
    @Environment(AppModel.self) private var appModel
    @State private var isAutoScrolling = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Log")
                    .font(.headline)
                Spacer()
                Toggle("Auto-scroll", isOn: $isAutoScrolling)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(appModel.logMessages) { entry in
                            LogEntryView(entry: entry)
                                .id(entry.id)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: appModel.logMessages.count) { _, _ in
                    if isAutoScrolling, let last = appModel.logMessages.last {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .glassPanel(cornerRadius: 20)
        .navigationTitle("Log")
    }
}

struct LogEntryView: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(entry.timestamp.formatted(.dateTime.hour().minute().second()))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 72, alignment: .leading)

            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(textColor)
                .textSelection(.enabled)
        }
    }

    private var textColor: Color {
        switch entry.level {
        case .error:   return .red
        case .warning: return .orange
        case .info:    return .primary
        case .debug:   return .secondary
        }
    }
}
