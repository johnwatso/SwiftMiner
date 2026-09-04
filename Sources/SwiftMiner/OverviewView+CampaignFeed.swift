import SwiftUI
import SwiftMinerCore
import AppKit

/// The prioritised campaign feed: the lookups a derivation resolves once, the
/// campaigns that qualify, and the rail items built from them.
extension OverviewView {
    // MARK: - Campaign Feed

    var campaignFeedSection: some View {
        // Build the (expensive) prioritised feed once per render. Previously this
        // chain was re-derived 3-4× per render — for `.isEmpty`, the `items:`
        // argument, and the `.onChange(of: …count)` keypath, which SwiftUI
        // re-evaluates on every render.
        let items = displayedPrioritisedFeedItems
        return VStack(alignment: .leading, spacing: 24) {
            if !items.isEmpty {
                priorityQueueSection(items: items)
            } else {
                addPrioritisedGameSection
            }
        }
        .padding(.vertical, 2)
    }

    /// The global game order, and only that. What each miner is doing now and what it
    /// is likely to pick up next stays in Miners — this section must not restate it.
    private func priorityQueueSection(items: [CampaignRailItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                sectionHeading("Priority Queue")

                Spacer()

                priorityQueueControls(canReorder: items.contains(where: \.isPriorityPinned))
            }

            PriorityQueueRail(
                items: items,
                prominence: .standard,
                isReordering: isReorderingPriorityQueue,
                onUploadCustomArtwork: presentCustomArtworkImporter(for:),
                onManageGames: { isShowingGameManagement = true },
                onMoveItem: movePrioritisedItem
            )
        }
    }

    @ViewBuilder
    private func priorityQueueControls(canReorder: Bool) -> some View {
        Group {
            if isReorderingPriorityQueue {
                Button {
                    setPriorityQueueReordering(false)
                } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Finish reordering")
            } else {
                Button {
                    setPriorityQueueReordering(true)
                } label: {
                    Label("Reorder", systemImage: "arrow.left.arrow.right")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canReorder)
                .help("Drag the cards to change global game priority")
            }
        }
    }

    private func setPriorityQueueReordering(_ isReordering: Bool) {
        withAnimation(.easeInOut(duration: 0.18)) {
            isReorderingPriorityQueue = isReordering
        }
    }

    private var addPrioritisedGameSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading("Priority Queue")

            MaterialEmptyStatePanel(
                "No prioritised games",
                systemImage: "star",
                description: "Add a game to keep it surfaced here and mine it first when drops are available."
            ) {
                Button {
                    isShowingGameManagement = true
                } label: {
                    Label("Add Prioritised Game", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
        }
    }

    private var preferredGames: [GamePreference] {
        settings.gamePreferences.filter { $0.state == .preferred }
    }

    /// Lookups the prioritised feed resolves once and then reuses for every campaign it
    /// touches. Rebuilding them per campaign is what made this chain the most expensive
    /// thing Overview did on a body pass.
    private struct CampaignFeedContext {
        let preferences: GameMatchIndex
        let watched: WatchedCampaignIndex
        let dropStates: PriorityQueueDropIndex
    }

    /// Campaigns a miner is currently watching, resolved from one pass over the miners
    /// rather than a fresh filtered array for every campaign asked about.
    struct WatchedCampaignIndex {
        let campaignIds: Set<String>
        let campaignNames: Set<String>

        init(miners: [MinerManager.ManagedMiner]) {
            var campaignIds: Set<String> = []
            var campaignNames: Set<String> = []
            for miner in miners where miner.status == .watching || miner.status == .claiming {
                if let id = miner.currentCampaignId {
                    campaignIds.insert(id)
                } else if let name = miner.currentCampaign {
                    campaignNames.insert(name)
                }
            }
            self.campaignIds = campaignIds
            self.campaignNames = campaignNames
        }

        func isWatched(_ campaign: CampaignViewData) -> Bool {
            campaignIds.contains(campaign.id) || campaignNames.contains(campaign.campaignName)
        }
    }

    /// The feed's sort order, resolved once per campaign. The comparator this replaces
    /// re-derived visual state and rescanned the priority list on both sides of every
    /// comparison, so a full sort paid for each of them thousands of times.
    private struct CampaignSortKey: Comparable {
        let displayPriority: Int
        let pinnedRank: Int
        let progressPercent: Double
        let endDate: Date
        let gameName: String

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.displayPriority != rhs.displayPriority {
                return lhs.displayPriority < rhs.displayPriority
            }
            if lhs.pinnedRank != rhs.pinnedRank {
                return lhs.pinnedRank < rhs.pinnedRank
            }
            if lhs.progressPercent != rhs.progressPercent {
                return lhs.progressPercent > rhs.progressPercent
            }
            if lhs.endDate != rhs.endDate {
                return lhs.endDate < rhs.endDate
            }
            return lhs.gameName < rhs.gameName
        }
    }

    private func makeArtworkIndex() -> OverviewArtworkResolver.ArtworkIndex {
        OverviewArtworkResolver.ArtworkIndex(sources: [
            campaigns.map { ($0.gameId, $0.gameName, $0.artworkURL) },
            navigation.minerManager.miners.flatMap(\.allCampaigns).map {
                ($0.game.id, $0.game.name, $0.game.boxArtURL)
            }
        ])
    }

    private func makeFeedContext() -> CampaignFeedContext {
        let watched = WatchedCampaignIndex(miners: navigation.minerManager.miners)
        return CampaignFeedContext(
            preferences: GameMatchIndex(
                gamePreferences: settings.gamePreferences,
                priorityGames: settings.priorityGames,
                excludedGames: settings.excludedGames
            ),
            watched: watched,
            dropStates: PriorityQueueDropIndex(campaigns: campaigns) { watched.isWatched($0) }
        )
    }

    private func sortKey(for campaign: CampaignViewData, context: CampaignFeedContext) -> CampaignSortKey {
        CampaignSortKey(
            displayPriority: displayPriority(for: campaign, watched: context.watched),
            pinnedRank: context.preferences.priorityRank(gameName: campaign.gameName),
            progressPercent: campaignProgressPercent(for: campaign),
            endDate: campaign.endDate,
            gameName: campaign.gameName
        )
    }

    private func prioritisedCampaigns(context: CampaignFeedContext) -> [CampaignViewData] {
        campaigns
            .filter { campaign in
                (campaign.relevance == .prioritised
                    || context.preferences.hasPreferredMatch(
                        gameId: campaign.gameId,
                        gameName: campaign.gameName
                    ))
                    && isPrioritisedRailEligible(campaign)
            }
            .map { (campaign: $0, key: sortKey(for: $0, context: context)) }
            .sorted { $0.key < $1.key }
            .map(\.campaign)
    }

    private func uniquePrioritisedCampaigns(context: CampaignFeedContext) -> [CampaignViewData] {
        var seen = Set<String>()
        return prioritisedCampaigns(context: context).filter { campaign in
            let normalizedName = normalizedGameKey(campaign.gameName)
            let key = normalizedName.isEmpty ? normalizedGameKey(campaign.gameId ?? campaign.id) : normalizedName
            return seen.insert(key).inserted
        }
    }


    private func isPrioritisedRailEligible(_ campaign: CampaignViewData) -> Bool {
        campaign.isDisplayableInOverview
            || (campaign.relevance == .prioritised && !campaign.isCompleted)
    }


    private func prioritisedFeedItems(context: CampaignFeedContext) -> [CampaignRailItem] {
        let campaignPool = uniquePrioritisedCampaigns(context: context)
        // Each campaign's match keys are resolved once here, so pairing preferences to
        // campaigns below is set membership rather than a locale comparison per pair.
        let poolKeys = campaignPool.map {
            Set(GameMatchIndex.keys(gameId: $0.gameId, gameName: $0.gameName))
        }
        var usedCampaignIds = Set<String>()
        var items: [CampaignRailItem] = []
        // Only built if some preferred game turns out to have no eligible campaign.
        var artworkIndex: OverviewArtworkResolver.ArtworkIndex?

        for preference in context.preferences.preferredPreferences {
            let preferenceKeys = Set(
                GameMatchIndex.keys(gameId: preference.gameId, gameName: preference.gameName)
            )
            if let poolIndex = campaignPool.indices.first(where: { index in
                !usedCampaignIds.contains(campaignPool[index].id)
                    && !poolKeys[index].isDisjoint(with: preferenceKeys)
            }) {
                let campaign = campaignPool[poolIndex]
                usedCampaignIds.insert(campaign.id)
                items.append(
                    makeRailItem(
                        for: campaign,
                        section: .prioritised,
                        context: context,
                        isPriorityPinned: true
                    )
                )
            } else {
                let artwork = artworkIndex ?? makeArtworkIndex()
                artworkIndex = artwork
                items.append(makePreferredGameItem(preference, artwork: artwork, context: context))
            }
        }

        let unpinnedCampaigns = campaignPool
            .filter { !usedCampaignIds.contains($0.id) }
            .map { makeRailItem(for: $0, section: .prioritised, context: context) }

        items.append(contentsOf: unpinnedCampaigns)
        return Array(deduplicatedPrioritisedItems(items).prefix(12))
    }

    private var displayedPrioritisedFeedItems: [CampaignRailItem] {
        prioritisedFeedItems(context: makeFeedContext())
    }

    private func makeRailItem(
        for campaign: CampaignViewData,
        section: CampaignFeedSection,
        context: CampaignFeedContext,
        isPriorityPinned: Bool = false
    ) -> CampaignRailItem {
        var state = visualState(for: campaign, watched: context.watched)
        if state == .idle && context.watched.isWatched(campaign) {
            state = .watching
        }
        let game = Game(id: campaign.gameId ?? campaign.id, name: campaign.gameName, boxArtURL: campaign.artworkURL)
        let preference = context.preferences.bestPreference(gameId: game.id, gameName: campaign.gameName)
        let artworkURL = preference?.customArtworkURL ?? campaign.artworkURL
        return CampaignRailItem(
            id: "\(section.rawValue)-\(campaign.id)",
            section: section,
            gameName: campaign.gameName,
            campaignName: campaign.campaignName,
            progressText: campaignDetailText(for: campaign, state: state),
            progressPercent: campaignProgressPercent(for: campaign),
            artworkURL: artworkURL,
            tint: tintColor(for: campaign),
            hasOnlyBadgesOrEmotes: false,
            visualState: state,
            watchers: watchers(for: campaign),
            isDimmed: state == .claimed,
            isPlaceholder: false,
            showsLiveMotion: section == .active && (state == .watching || state == .inProgress || state == .claimable),
            usesCustomArtwork: preference?.customArtworkURL != nil,
            game: game,
            dropState: context.dropStates.state(gameId: campaign.gameId, gameName: campaign.gameName),
            isPriorityPinned: isPriorityPinned
        )
    }

    private func currentCampaign(for miner: MinerManager.ManagedMiner) -> CampaignViewData? {
        if let campaignId = miner.currentCampaignId {
            return campaigns.first(where: { $0.id == campaignId })
        }

        guard let campaignName = miner.currentCampaign else {
            return nil
        }

        return campaigns.first(where: { $0.campaignName == campaignName })
    }

    private func normalizedGameKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func comparableGameName(_ value: String) -> String {
        value
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    func startLinkAccountFlow(for miner: MinerManager.ManagedMiner) {
        navigation.reconnectTwitchAccount(for: miner.id)
    }

    private func makePreferredGameItem(
        _ preference: GamePreference,
        artwork: OverviewArtworkResolver.ArtworkIndex,
        context: CampaignFeedContext
    ) -> CampaignRailItem {
        // This item is built precisely because the game has no *eligible* campaign,
        // but an ineligible one (completed, unlinked) usually still exists and
        // carries live Twitch art. Preferences hold no remote URL of their own once
        // a dead cache path is discarded, so without this the tile drops to initials.
        let campaignArtwork = artwork.artworkURL(for: preference)

        let artworkURL = preference.customArtworkURL
            ?? preference.resolvedBoxArtURL
            ?? campaignArtwork
        return CampaignRailItem(
            id: "preferred-\(preference.gameId.isEmpty ? preference.gameName : preference.gameId)",
            section: .prioritised,
            gameName: preference.gameName,
            campaignName: "",
            progressText: "Your preferred games are ready for the next campaign.",
            progressPercent: 0,
            artworkURL: artworkURL,
            tint: .secondary,
            hasOnlyBadgesOrEmotes: false,
            visualState: .idle,
            watchers: [],
            isDimmed: false,
            isPlaceholder: false,
            showsLiveMotion: false,
            usesCustomArtwork: preference.customArtworkURL != nil,
            game: Game(id: preference.gameId, name: preference.gameName, boxArtURL: artworkURL),
            dropState: context.dropStates.state(
                gameId: preference.gameId,
                gameName: preference.gameName
            ),
            isPriorityPinned: true
        )
    }

    private func movePrioritisedItem(_ item: CampaignRailItem, to targetIndex: Int) {
        guard let game = item.game else { return }
        let preferred = preferredGames
        guard preferred.count > 1,
              let sourceIndex = preferred.firstIndex(where: { preferenceMatches($0, game: game) }) else {
            return
        }

        let destinationIndex = min(max(targetIndex, 0), preferred.count - 1)
        guard sourceIndex != destinationIndex else { return }

        let toOffset = sourceIndex < destinationIndex ? destinationIndex + 1 : destinationIndex
        withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
            settings.moveGamePreferences(
                fromOffsets: IndexSet(integer: sourceIndex),
                toOffset: toOffset,
                inState: .preferred
            )
        }
        navigation.minerManager.updatePriorityGames(resolving: { settings.priorityGames(forAccountId: $0.accountId) })
    }

    private func preferenceMatches(_ preference: GamePreference, game: Game) -> Bool {
        let idMatches = !game.id.isEmpty && preference.gameId == game.id
        let nameMatches = preference.gameName.localizedCaseInsensitiveCompare(game.name) == .orderedSame
            || comparableGameName(preference.gameName) == comparableGameName(game.name)
        return idMatches || nameMatches
    }

    private func deduplicatedPrioritisedItems(_ items: [CampaignRailItem]) -> [CampaignRailItem] {
        var seenIds = Set<String>()
        var seenNames = Set<String>()
        return items.filter { item in
            let id = item.game?.id.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = comparableGameName(item.gameName)

            if (!id.isEmpty && seenIds.contains(id)) || (!name.isEmpty && seenNames.contains(name)) {
                return false
            }

            if !id.isEmpty {
                seenIds.insert(id)
            }
            if !name.isEmpty {
                seenNames.insert(name)
            }

            return true
        }
    }

    private func placeholderRailItem(for section: CampaignFeedSection) -> CampaignRailItem {
        switch section {
        case .prioritised:
            return CampaignRailItem(
                id: "placeholder-prioritised",
                section: .prioritised,
                gameName: settings.priorityGames.isEmpty ? "Pin favourites" : "Prioritised",
                campaignName: settings.priorityGames.isEmpty ? "Choose games to keep anchored here" : "Selected games stay surfaced first",
                progressText: settings.priorityGames.isEmpty
                    ? "Add preferred games in Settings."
                    : "Your preferred games are ready for the next campaign.",
                progressPercent: 0,
                artworkURL: preferredGames.first.flatMap { pref in
                    pref.customArtworkURL ?? pref.resolvedBoxArtURL
                },
                tint: .orange,
                hasOnlyBadgesOrEmotes: false,
                visualState: .idle,
                watchers: [],
                isDimmed: false,
                isPlaceholder: true,
                showsLiveMotion: false
            )
        case .active:
            return CampaignRailItem(
                id: "placeholder-active",
                section: .active,
                gameName: "No eligible campaigns",
                campaignName: "No campaign is mineable right now",
                progressText: "No eligible campaigns are available right now.",
                progressPercent: 0,
                artworkURL: nil,
                tint: .secondary,
                hasOnlyBadgesOrEmotes: false,
                visualState: .idle,
                watchers: [],
                isDimmed: false,
                isPlaceholder: true,
                showsLiveMotion: false
            )
        case .recent:
            return CampaignRailItem(
                id: "placeholder-recent",
                section: .recent,
                gameName: "Recent",
                campaignName: "Freshly claimed campaigns land here",
                progressText: "Completed campaigns stay visible for a while.",
                progressPercent: 0,
                artworkURL: nil,
                tint: .blue,
                hasOnlyBadgesOrEmotes: false,
                visualState: .claimed,
                watchers: [],
                isDimmed: true,
                isPlaceholder: true,
                showsLiveMotion: false
            )
        }
    }
}

/// Per-game drop state for the Overview priority queue, resolved in one pass over
/// the campaign list rather than once per card.
///
/// The question this answers is deliberately small: is a miner on this game right
/// now, and if not, is there anything left to earn? Campaign-level detail belongs
/// to Miners and Drops.
struct PriorityQueueDropIndex {
    private struct Counts {
        var activeCampaigns = 0
        var remainingRewards = 0
    }

    private let countsByKey: [String: Counts]

    init(
        campaigns: [CampaignViewData],
        now: Date = Date(),
        isWatched: (CampaignViewData) -> Bool
    ) {
        var countsByKey: [String: Counts] = [:]
        for campaign in campaigns {
            let key = Self.key(gameId: campaign.gameId, gameName: campaign.gameName)
            guard !key.isEmpty else { continue }
            var counts = countsByKey[key] ?? Counts()

            if isWatched(campaign) {
                counts.activeCampaigns += 1
            }

            // The same "mineable right now" test Overview's active campaign count uses.
            if campaign.isAccountConnected,
               campaign.startDate <= now,
               campaign.endDate > now,
               !campaign.isCompleted {
                counts.remainingRewards += campaign.overviewRemainingRewardCount
            }

            countsByKey[key] = counts
        }
        self.countsByKey = countsByKey
    }

    func state(gameId: String?, gameName: String) -> PriorityQueueDropState {
        let counts = countsByKey[Self.key(gameId: gameId, gameName: gameName)] ?? Counts()

        if counts.activeCampaigns > 0 {
            return PriorityQueueDropState(tone: .active, label: "\(counts.activeCampaigns) active")
        }

        if counts.remainingRewards > 0 {
            let noun = counts.remainingRewards == 1 ? "drop" : "drops"
            return PriorityQueueDropState(
                tone: .available,
                label: "\(counts.remainingRewards) \(noun)"
            )
        }

        return PriorityQueueDropState(tone: .idle, label: "No drops")
    }

    /// One canonical key per game, matching how the feed dedupes cards: the name
    /// reduced to lowercased alphanumerics, falling back to the game id.
    private static func key(gameId: String?, gameName: String) -> String {
        let comparable = String(
            gameName.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        )
        if !comparable.isEmpty {
            return "name:" + comparable
        }
        if let gameId, !gameId.isEmpty {
            return "id:" + gameId
        }
        return ""
    }
}
