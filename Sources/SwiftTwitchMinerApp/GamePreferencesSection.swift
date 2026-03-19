import SwiftUI
import SwiftTwitchMiner

// MARK: - Game Preferences Section

/// Top-level container for the game preferences UI.
/// Replaces the old "Rules" section with search-driven token selection.
struct GamePreferencesSection: View {
    @ObservedObject var settings: Settings
    let campaignStore: CampaignStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GameSearchField(settings: settings, campaignStore: campaignStore)

            if !settings.gamePreferences.isEmpty {
                GameTokensContainer(settings: settings)
            }
        }
    }
}

// MARK: - Search Field

/// Autocomplete search field that suggests games from active campaigns.
struct GameSearchField: View {
    @ObservedObject var settings: Settings
    let campaignStore: CampaignStore
    @State private var searchText = ""
    @State private var showSuggestions = false
    @FocusState private var isSearchFocused: Bool

    /// Unique games extracted from campaigns, sorted alphabetically
    private var availableGames: [Game] {
        var seen = Set<String>()
        return campaignStore.campaigns
            .map { $0.game }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Games matching search query, excluding already-selected ones
    private var filteredGames: [Game] {
        let existingIds = Set(settings.gamePreferences.map { $0.gameId })
        let query = searchText.lowercased().trimmingCharacters(in: .whitespaces)
        return availableGames
            .filter { !existingIds.contains($0.id) }
            .filter { query.isEmpty || $0.name.lowercased().contains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search games\u{2026}", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .focused($isSearchFocused)
                .onChange(of: searchText) { _, newValue in
                    showSuggestions = !newValue.trimmingCharacters(in: .whitespaces).isEmpty
                }
                .onChange(of: isSearchFocused) { _, focused in
                    if !focused {
                        // Delay to allow click on suggestion to register
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            showSuggestions = false
                        }
                    }
                }

            if showSuggestions {
                if filteredGames.isEmpty {
                    if availableGames.isEmpty {
                        Text("Add an account to see available games.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    } else {
                        Text("No matching games found.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(filteredGames.prefix(8)) { game in
                                GameSuggestionRow(game: game) {
                                    settings.addGamePreference(game, state: .preferred)
                                    searchText = ""
                                    showSuggestions = false
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                    .background(.background)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                }
            }
        }
    }
}

// MARK: - Suggestion Row

/// A single game suggestion in the search dropdown.
struct GameSuggestionRow: View {
    let game: Game
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                AsyncImage(url: game.boxArtURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(.quaternary)
                }
                .frame(width: 24, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

                Text(game.name)
                    .lineLimit(1)

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

    private var orderedPreferences: [GamePreference] {
        settings.gamePreferences.sorted { lhs, rhs in
            if stateOrder(lhs.state) != stateOrder(rhs.state) {
                return stateOrder(lhs.state) < stateOrder(rhs.state)
            }
            return lhs.gameName.localizedCaseInsensitiveCompare(rhs.gameName) == .orderedAscending
        }
    }

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(orderedPreferences) { pref in
                GameTokenView(preference: pref, settings: settings)
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
