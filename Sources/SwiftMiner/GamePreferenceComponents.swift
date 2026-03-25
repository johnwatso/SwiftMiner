import SwiftUI
import SwiftTwitchMiner

// MARK: - Game Preferences Section

/// Top-level container for the game preferences UI.
/// Replaces the old "Rules" section with search-driven token selection.
struct GamePreferencesSection: View {
    @ObservedObject var settings: Settings
    let minerManager: MinerManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GameSearchField(settings: settings, minerManager: minerManager)

            if !settings.gamePreferences.isEmpty {
                GameTokensContainer(settings: settings, minerManager: minerManager)
            }
        }
    }
}

// MARK: - Search Field

/// Autocomplete search field that suggests games from active campaigns.
struct GameSearchField: View {
    @ObservedObject var settings: Settings
    let minerManager: MinerManager
    @State private var searchText = ""
    @State private var showSuggestions = false
    @State private var availableGames: [Game] = []
    @State private var hasLoadedGames = false
    @State private var isLoadingGames = false
    @State private var twitchSearchResults: [Game] = []
    @State private var twitchSearchErrorMessage: String?
    @State private var twitchSearchRequiresReauth = false
    @State private var isSearchingTwitch = false
    @State private var twitchSearchTask: Task<Void, Never>?
    @FocusState private var isSearchFocused: Bool

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedQuery: String {
        searchQuery.lowercased()
    }

    /// Track campaign feed updates from the shared store so search stays in sync
    /// with the rest of the app without maintaining its own stale cache.
    private var campaignRefreshToken: String {
        minerManager.campaignStore.campaigns
            .map(\.id)
            .sorted()
            .joined(separator: "|")
    }

    private var hasAccounts: Bool {
        !minerManager.miners.isEmpty
    }

    /// Games matching search query, excluding already-selected ones
    private var filteredGames: [Game] {
        let existingIds = Set(settings.gamePreferences.map { $0.gameId })
        return availableGames
            .filter { game in
                !existingIds.contains(game.id)
                && !settings.gamePreferences.contains(where: {
                    $0.gameName.localizedCaseInsensitiveCompare(game.name) == .orderedSame
                })
            }
            .filter { normalizedQuery.isEmpty || $0.name.lowercased().contains(normalizedQuery) }
    }

    private var shouldShowLoadingState: Bool {
        hasAccounts && !hasLoadedGames && availableGames.isEmpty && isLoadingGames
    }

    private var shouldShowAddAccountState: Bool {
        !hasAccounts && !hasLoadedGames
    }

    private var shouldShowNoMatchesState: Bool {
        !normalizedQuery.isEmpty
            && !isSearchingTwitch
            && allSuggestions.isEmpty
            && filteredGames.isEmpty
            && twitchSearchResults.isEmpty
            && twitchSearchErrorMessage == nil
            && hasAccounts
    }

    private var shouldShowSearchErrorState: Bool {
        !normalizedQuery.isEmpty
            && !isSearchingTwitch
            && allSuggestions.isEmpty
            && hasAccounts
            && twitchSearchErrorMessage != nil
    }

    /// Twitch returned matches, but they are already present in the user's selected list.
    private var shouldShowAlreadyAddedMatchesState: Bool {
        !normalizedQuery.isEmpty
            && !isSearchingTwitch
            && allSuggestions.isEmpty
            && filteredGames.isEmpty
            && !twitchSearchResults.isEmpty
            && hasAccounts
    }

    /// Show a discovery hint when local campaign games don't match, so users understand
    /// they can still search the full Twitch category catalog.
    private var shouldShowDiscoveryHint: Bool {
        !normalizedQuery.isEmpty && filteredGames.isEmpty && hasAccounts
    }

    /// Show contextual message when Twitch found games but none currently have active drops.
    private var shouldShowNoActiveDropsMessage: Bool {
        !normalizedQuery.isEmpty
            && filteredGames.isEmpty
            && !twitchSearchResults.isEmpty
            && hasAccounts
    }

    /// Show a "Search Twitch for X" row when local results exist but Twitch hasn't returned anything yet.
    private var shouldShowTwitchFallbackRow: Bool {
        !normalizedQuery.isEmpty && hasAccounts && !isSearchingTwitch && twitchSearchResults.isEmpty
    }

    /// Game names that currently have active drop campaigns.
    private var activeDropGameNameSet: Set<String> {
        Set(availableGames.map { $0.name.lowercased() })
    }

    /// Combined results: local campaign games first, then Twitch search results
    /// (de-duplicated against already-selected preferences).
    private var allSuggestions: [Game] {
        let existingNames = Set(settings.gamePreferences.map {
            $0.gameName.lowercased()
        })
        let twitchDeduped = twitchSearchResults.filter { game in
            !existingNames.contains(game.name.lowercased())
            && !filteredGames.contains(where: { $0.name.lowercased() == game.name.lowercased() })
        }
        return filteredGames + twitchDeduped
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search games\u{2026}", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .focused($isSearchFocused)
                .onChange(of: searchText) { _, newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                    showSuggestions = !trimmed.isEmpty
                    triggerTwitchSearch(query: trimmed)
                }
                .onChange(of: isSearchFocused) { _, focused in
                    if !focused {
                        // Delay to allow click on suggestion to register
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            showSuggestions = false
                        }
                    }
                }
                .task(id: campaignRefreshToken) {
                    await refreshAvailableGames()
                }

            if showSuggestions {
                if allSuggestions.isEmpty {
                    if shouldShowLoadingState || isSearchingTwitch {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(isSearchingTwitch ? "Searching Twitch…" : "Loading games…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    } else if shouldShowAddAccountState {
                        Text("Add an account to search games.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    } else if shouldShowSearchErrorState, let errorMessage = twitchSearchErrorMessage {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !twitchSearchRequiresReauth {
                                Button("Retry search") {
                                    triggerImmediateTwitchSearch(query: searchQuery)
                                }
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                                .buttonStyle(.plain)
                            } else {
                                Text("Reconnect Twitch in Settings > Accounts, then search again.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    } else if shouldShowAlreadyAddedMatchesState {
                        Text("Matching Twitch games are already in your list.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    } else if shouldShowNoMatchesState {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("No games found on Twitch for \"\(searchQuery)\".")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Search again") {
                                triggerImmediateTwitchSearch(query: searchQuery)
                            }
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if shouldShowDiscoveryHint {
                                Text("Can't find your game? Search all of Twitch.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                            }

                            if shouldShowNoActiveDropsMessage {
                                Text("No drops currently running for \"\(searchQuery)\". You'll be first in queue when drops go live.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.bottom, 4)
                            }

                            ForEach(allSuggestions.prefix(10)) { game in
                                GameSuggestionRow(game: game, hasActiveDrops: hasActiveDrops(for: game)) {
                                    settings.addGamePreference(game, state: .preferred)
                                    searchText = ""
                                    showSuggestions = false
                                    twitchSearchResults = []
                                }
                            }

                            if shouldShowTwitchFallbackRow {
                                Button {
                                    triggerImmediateTwitchSearch(query: searchQuery)
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "magnifyingglass")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                        Text("Search Twitch for \"\(searchQuery)\"")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 240)
                    .background(.background)
                    .clipShape(RoundedRectangle(cornerRadius: GlassRadius.small, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                }
            }
        }
    }

    @MainActor
    private func refreshAvailableGames() async {
        isLoadingGames = true
        let campaigns = await minerManager.dataCoordinator.currentCampaigns(
            preferSteamArtwork: Settings.shared.preferSteamArtwork
        )
        availableGames = uniqueGames(from: campaigns)
        hasLoadedGames = true
        isLoadingGames = false
    }

    /// Triggers a debounced Twitch category search.
    /// Cancels any in-flight search before starting a new one.
    /// Sets `isSearchingTwitch = true` immediately to prevent "No results" flash during the debounce window.
    private func triggerTwitchSearch(query: String) {
        twitchSearchTask?.cancel()
        guard !query.isEmpty, hasAccounts else {
            twitchSearchResults = []
            twitchSearchErrorMessage = nil
            twitchSearchRequiresReauth = false
            isSearchingTwitch = false
            return
        }
        twitchSearchTask = Task {
            isSearchingTwitch = true
            twitchSearchErrorMessage = nil
            twitchSearchRequiresReauth = false
            // 500 ms debounce
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            do {
                let results = try await minerManager.dataCoordinator.searchCategories(query: query)
                guard !Task.isCancelled else { return }
                twitchSearchResults = results
                twitchSearchErrorMessage = nil
                twitchSearchRequiresReauth = false
            } catch {
                guard !Task.isCancelled else { return }
                if isCancellationError(error) { return }
                let mappedError = mapSearchError(error)
                twitchSearchResults = []
                twitchSearchErrorMessage = mappedError.message
                twitchSearchRequiresReauth = mappedError.requiresReauth
                print("[GameSearchField] Twitch search failed for '\(query)': \(error)")
            }
            guard !Task.isCancelled else { return }
            isSearchingTwitch = false
        }
    }

    /// Fires an immediate Twitch search without debounce (used by the fallback row tap).
    private func triggerImmediateTwitchSearch(query: String) {
        twitchSearchTask?.cancel()
        guard !query.isEmpty, hasAccounts else { return }
        twitchSearchTask = Task {
            isSearchingTwitch = true
            twitchSearchErrorMessage = nil
            twitchSearchRequiresReauth = false
            do {
                let results = try await minerManager.dataCoordinator.searchCategories(query: query)
                guard !Task.isCancelled else { return }
                twitchSearchResults = results
                twitchSearchErrorMessage = nil
                twitchSearchRequiresReauth = false
            } catch {
                guard !Task.isCancelled else { return }
                if isCancellationError(error) { return }
                let mappedError = mapSearchError(error)
                twitchSearchResults = []
                twitchSearchErrorMessage = mappedError.message
                twitchSearchRequiresReauth = mappedError.requiresReauth
                print("[GameSearchField] Twitch search failed for '\(query)': \(error)")
            }
            guard !Task.isCancelled else { return }
            isSearchingTwitch = false
        }
    }

    private func mapSearchError(_ error: Error) -> (message: String, requiresReauth: Bool) {
        if let twitchError = error as? TwitchMinerError {
            switch twitchError {
            case .tokenExpired:
                return ("Twitch session expired. Reconnect your account in Settings > Accounts.", true)
            case .authenticationFailed:
                return ("Twitch authentication failed. Reconnect your account in Settings > Accounts.", true)
            default:
                break
            }
        }
        return ("Couldn’t search Twitch right now. Please retry.", false)
    }

    private func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        return false
    }

    private func uniqueGames(from campaigns: [CampaignViewData]) -> [Game] {
        var uniqueGamesByName: [String: Game] = [:]

        for campaign in campaigns {
            let gameName = campaign.gameName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !gameName.isEmpty else { continue }

            let key = normalizedKey(for: gameName)
            let candidate = Game(
                id: key,
                name: gameName,
                boxArtURL: campaign.artworkURL
            )

            if let existing = uniqueGamesByName[key] {
                if existing.boxArtURL == nil, candidate.boxArtURL != nil {
                    uniqueGamesByName[key] = candidate
                }
            } else {
                uniqueGamesByName[key] = candidate
            }
        }

        return uniqueGamesByName.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func normalizedKey(for name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func hasActiveDrops(for game: Game) -> Bool {
        activeDropGameNameSet.contains(game.name.lowercased())
    }
}

// MARK: - Suggestion Row

/// A single game suggestion in the search dropdown.
struct GameSuggestionRow: View {
    let game: Game
    let hasActiveDrops: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                AsyncImage(url: game.boxArtURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: GlassRadius.subtle, style: .continuous)
                        .fill(.quaternary)
                }
                .frame(width: 24, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: GlassRadius.subtle, style: .continuous))

                Text(game.name)
                    .lineLimit(1)

                AvailabilityBadge(hasActiveDrops: hasActiveDrops)

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tokens Container

/// Displays selected games as tokens in a wrapping flow layout.
struct GameTokensContainer: View {
    @ObservedObject var settings: Settings
    let minerManager: MinerManager

    private var orderedPreferences: [GamePreference] {
        settings.gamePreferences.sorted { lhs, rhs in
            stateOrder(lhs.state) < stateOrder(rhs.state)
        }
    }

    private var activeDropGameNameSet: Set<String> {
        let names = minerManager.campaignStore.campaigns
            .filter { $0.isMiningEligible }
            .map { $0.game.name.lowercased() }
        return Set(names)
    }

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(orderedPreferences) { pref in
                GameTokenView(
                    preference: pref,
                    settings: settings,
                    hasActiveDrops: activeDropGameNameSet.contains(pref.gameName.lowercased())
                )
            }
        }
    }

    private func stateOrder(_ state: PreferenceState) -> Int {
        switch state {
        case .preferred:
            return 0
        case .excluded:
            return 1
        case .neutral:
            return 2
        }
    }
}

// MARK: - Token View

/// A single game token with state indicator, name, and remove button.
/// Supports context menu for toggling state or removing.
struct GameTokenView: View {
    let preference: GamePreference
    @ObservedObject var settings: Settings
    let hasActiveDrops: Bool

    private var stateColor: Color {
        switch preference.state {
        case .preferred:
            return .green
        case .excluded:
            return .red
        case .neutral:
            return .secondary
        }
    }

    private var stateIcon: String? {
        switch preference.state {
        case .preferred:
            return "star.fill"
        case .excluded:
            return "minus.circle.fill"
        case .neutral:
            return nil
        }
    }

    private var stateLabel: String {
        switch preference.state {
        case .preferred:
            return "Preferred"
        case .excluded:
            return "Excluded"
        case .neutral:
            return "Neutral"
        }
    }

    private var chipBackground: some ShapeStyle {
        switch preference.state {
        case .preferred:
            return AnyShapeStyle(.green.opacity(0.14))
        case .excluded:
            return AnyShapeStyle(.red.opacity(0.14))
        case .neutral:
            return AnyShapeStyle(.quaternary)
        }
    }

    private var chipStroke: Color {
        switch preference.state {
        case .preferred:
            return .green.opacity(0.35)
        case .excluded:
            return .red.opacity(0.35)
        case .neutral:
            return .black.opacity(0.08)
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            if let stateIcon {
                Image(systemName: stateIcon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(stateColor)
            }

            Text(preference.gameName)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(preference.state == .neutral ? .primary : stateColor)

            AvailabilityBadge(hasActiveDrops: hasActiveDrops)

            Button {
                settings.removeGamePreference(preference)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(chipBackground, in: Capsule())
        .overlay {
            Capsule()
                .stroke(chipStroke, lineWidth: 1)
        }
        .contentShape(Capsule())
        .onTapGesture {
            settings.togglePreferenceState(for: preference)
        }
        .help("\(preference.gameName) — \(stateLabel). Click to cycle preference state.")
        .contextMenu {
            Button {
                settings.setPreferenceState(.preferred, for: preference)
            } label: {
                Label("Set Preferred", systemImage: "star.fill")
            }
            .disabled(preference.state == .preferred)

            Button {
                settings.setPreferenceState(.excluded, for: preference)
            } label: {
                Label("Set Excluded", systemImage: "minus.circle.fill")
            }
            .disabled(preference.state == .excluded)

            Button {
                settings.setPreferenceState(.neutral, for: preference)
            } label: {
                Label("Set Neutral", systemImage: "circle")
            }
            .disabled(preference.state == .neutral)

            Divider()

            Button(role: .destructive) {
                settings.removeGamePreference(preference)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }
}

private struct AvailabilityBadge: View {
    let hasActiveDrops: Bool

    var body: some View {
        Text(hasActiveDrops ? "Drops available" : "No active drops")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(hasActiveDrops ? Color.green : Color.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                (hasActiveDrops ? Color.green.opacity(0.16) : Color.secondary.opacity(0.16)),
                in: Capsule()
            )
    }
}

// MARK: - Flow Layout

/// A custom Layout that wraps children into rows, like a tag cloud.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), positions)
    }
}
