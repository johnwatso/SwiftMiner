import SwiftUI
import SwiftMinerCore

/// Unified management surface for game rules — prioritised and excluded games in one
/// sheet, with the legacy per-game fallback streamer tucked behind row expansion.
///
/// Replaces the old scoped sheets ("Prioritised Games…" / "Excluded Games…"), which
/// showed the same controls twice and let the user move a game between the lists anyway.
struct GamePreferenceManagementView: View {
    @Environment(\.dismiss) private var dismiss
    var settings: Settings
    let minerManager: MinerManager

    @State private var expandedPreferenceID: String?
    @State private var isPrioritisedExpanded = true
    @State private var isExcludedExpanded = true

    private var prioritisedGames: [GamePreference] {
        settings.gamePreferences.filter { $0.state == .preferred }
    }

    private var excludedGames: [GamePreference] {
        settings.gamePreferences.filter { $0.state == .excluded }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ruleList

            Divider()

            footer
        }
        .frame(width: 540, height: 560)
        // `.task(id:)` rather than `.onChange` + `Task {}`: SwiftUI cancels the in-flight push
        // when the rules change again, so a rapid series of edits cannot land out of order.
        .task(id: settings.gameFailoverStreamersData) {
            await minerManager.updateFailoverStreamers(settings.gameFailoverStreamers)
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Game Rules")
                        .font(.headline)

                    Link(destination: URL(string: "https://swiftminer.app/help/game-rules/")!) {
                        Image(systemName: "questionmark.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Learn about priorities, exclusions, and fallback streamers")
                    .accessibilityLabel("Game Rules Help")
                }

                Text("Control which games SwiftMiner prioritises or avoids.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
        .background(.ultraThinMaterial)
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "lightbulb")
            VStack(alignment: .leading, spacing: 1) {
                Text("Prioritised games are mined before other eligible campaigns.")
                Text("Excluded games are never mined.")
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - List

    /// Decoding the failover rules is not free, so it happens once per render here and every
    /// row is handed the login it needs rather than looking itself up.
    private var ruleList: some View {
        let fallbacks = fallbackLogins

        return List {
            Section {
                GameSearchField(
                    settings: settings,
                    minerManager: minerManager,
                    placeholder: "Search games to add\u{2026}",
                    offersBothStates: true
                )
                .padding(.vertical, 4)
            } footer: {
                Text("Search and add games to prioritise or exclude.")
            }

            if !prioritisedGames.isEmpty {
                Section {
                    if isPrioritisedExpanded {
                        ForEach(prioritisedGames) { preference in
                            row(for: preference, fallbacks: fallbacks)
                        }
                        .onMove { from, to in
                            settings.moveGamePreferences(fromOffsets: from, toOffset: to, inState: .preferred)
                        }
                    }
                } header: {
                    sectionHeader(
                        "Prioritised",
                        symbol: "star",
                        tint: .accentColor,
                        count: prioritisedGames.count,
                        isExpanded: $isPrioritisedExpanded
                    )
                }
            }

            if !excludedGames.isEmpty {
                Section {
                    if isExcludedExpanded {
                        ForEach(excludedGames) { preference in
                            row(for: preference, fallbacks: fallbacks)
                        }
                        .onMove { from, to in
                            settings.moveGamePreferences(fromOffsets: from, toOffset: to, inState: .excluded)
                        }
                    }
                } header: {
                    sectionHeader(
                        "Excluded",
                        symbol: "minus.circle",
                        tint: .red,
                        count: excludedGames.count,
                        isExpanded: $isExcludedExpanded
                    )
                }
            }

            if prioritisedGames.isEmpty && excludedGames.isEmpty {
                emptyState
            }
        }
        .listStyle(.inset)
    }

    private func row(for preference: GamePreference, fallbacks: [String: String]) -> some View {
        GameRuleRow(
            preference: preference,
            settings: settings,
            storedFallbackLogin: fallbacks[preference.id] ?? fallbacks[Self.nameKey(for: preference.gameName)],
            isExpanded: expandedBinding(for: preference)
        )
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: SystemSymbolCompatibility.resolvedName(for: "list.bullet.rectangle.stack"))
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text("No game rules configured.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .listRowBackground(Color.clear)
    }

    /// A tappable header rather than `Section(isExpanded:)` so the disclosure triangle is
    /// guaranteed to render under `.inset` list style, and the whole header is the hit target.
    private func sectionHeader(
        _ title: String,
        symbol: String,
        tint: Color,
        count: Int,
        isExpanded: Binding<Bool>
    ) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)

                Text("\(title) \u{00B7} \(count)")

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded.wrappedValue ? "Collapse \(title)" : "Expand \(title)")
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Support

    /// Failover logins keyed by both rule id and game name, mirroring the id-or-name matching
    /// `Settings.failoverStreamer(for:)` does — a rule stored without a game id still resolves.
    private var fallbackLogins: [String: String] {
        settings.gameFailoverStreamers.reduce(into: [String: String]()) { map, rule in
            if !rule.id.isEmpty {
                map[rule.id] = rule.streamerLogin
            }
            let key = Self.nameKey(for: rule.gameName)
            if !key.isEmpty {
                map[key] = rule.streamerLogin
            }
        }
    }

    private static func nameKey(for gameName: String) -> String {
        gameName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Only one row is expanded at a time — the fallback editor is an occasional detour, not
    /// something worth leaving open on every prioritised game.
    private func expandedBinding(for preference: GamePreference) -> Binding<Bool> {
        Binding(
            get: { expandedPreferenceID == preference.id },
            set: { expandedPreferenceID = $0 ? preference.id : nil }
        )
    }
}

// MARK: - Rule Row

/// One game rule: artwork, name, current state, and — for prioritised games only — an
/// expandable legacy fallback streamer editor.
private struct GameRuleRow: View {
    let preference: GamePreference
    var settings: Settings
    /// Resolved by the sheet so each row does not re-decode the failover rules.
    let storedFallbackLogin: String?
    @Binding var isExpanded: Bool

    @State private var resolvedArtworkURL: URL?
    @State private var fallbackLogin: String = ""
    @State private var isRemoveHovered = false

    private var isPrioritised: Bool {
        preference.state == .preferred
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryRow

            if isPrioritised && isExpanded {
                fallbackEditor
                    .padding(.leading, 34)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
            }
        }
        .padding(.vertical, 3)
        .task(id: storedFallbackLogin) {
            syncFallback()
        }
        .onChange(of: preference.state) { _, newState in
            // Fallback rules only apply to prioritised games. The stored rule survives the move,
            // so switching back restores it — only the editor goes away.
            if newState != .preferred {
                isExpanded = false
            }
        }
    }

    /// Two interaction areas: game identity (and its details disclosure) on the left,
    /// rule and list management on the right.
    private var summaryRow: some View {
        HStack(spacing: 10) {
            artwork

            gameIdentity

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                statePicker

                // Excluded games have no meaningful order, so they get no reorder affordance.
                if isPrioritised {
                    Image(systemName: "line.3.horizontal")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help("Drag to reorder")
                        .accessibilityHidden(true)
                }

                removeButton
            }
        }
    }

    /// The disclosure belongs to the game, not to the list controls, so it sits with the
    /// title — and only a prioritised game has anything behind it to disclose.
    @ViewBuilder
    private var gameIdentity: some View {
        if isPrioritised {
            Button(action: toggleExpansion) {
                identityLabel
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide fallback streamer options" : "Show fallback streamer options")
            .accessibilityHint(isExpanded ? "Hides fallback streamer options" : "Shows fallback streamer options")
        } else {
            identityLabel
        }
    }

    private var identityLabel: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(preference.gameName)
                    .font(.body)
                    .lineLimit(1)

                if isPrioritised {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }

            // The absence of a fallback stays quiet; only a configured one earns a line.
            if isPrioritised, let storedFallbackLogin {
                Text("@\(storedFallbackLogin) fallback configured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }

    private var removeButton: some View {
        Button {
            settings.removeGamePreference(preference)
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(isRemoveHovered ? AnyShapeStyle(Color.red) : AnyShapeStyle(.tertiary))
        }
        .buttonStyle(.plain)
        .onHover { isRemoveHovered = $0 }
        .help("Remove rule")
        .accessibilityLabel("Remove \(preference.gameName)")
    }

    private var artwork: some View {
        AsyncImage(url: resolvedArtworkURL) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            RoundedRectangle(cornerRadius: GlassRadius.subtle, style: .continuous)
                .fill(.quaternary)
        }
        .frame(width: 24, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: GlassRadius.subtle, style: .continuous))
        .task(id: artworkRefreshID) {
            resolvedArtworkURL = preference.customArtworkURL ?? preference.resolvedBoxArtURL
        }
    }

    private var statePicker: some View {
        Picker("", selection: Binding(
            get: { preference.state },
            set: { settings.setPreferenceState($0, for: preference) }
        )) {
            Text("Prioritised").tag(PreferenceState.preferred)
            Text("Excluded").tag(PreferenceState.excluded)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 104)
        .accessibilityLabel("Rule for \(preference.gameName)")
    }

    // MARK: Fallback streamer

    private var fallbackEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Fallback streamer")
                    .font(.subheadline.weight(.semibold))

                Text("LEGACY")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Legacy feature")
            }

            Text("Use a specific streamer if normal campaign progress stalls.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("Twitch username\u{2026}", text: $fallbackLogin)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commitFallback)

                fallbackActionButton
            }
            .controlSize(.small)
        }
    }

    /// One action, never a dead one: "Clear" appears only once something is stored and the
    /// field still matches it, otherwise "Set" — enabled as soon as the field parses.
    @ViewBuilder
    private var fallbackActionButton: some View {
        if storedFallbackLogin != nil, !hasPendingEdit {
            Button("Clear", action: clearFallback)
        } else {
            Button("Set", action: commitFallback)
                .disabled(candidateLogin == nil)
        }
    }

    private var candidateLogin: String? {
        GameFailoverStreamer.normalizedStreamerLogin(fallbackLogin)
    }

    /// The field holds a usable login that differs from the stored one — the only case where
    /// "Set" would change anything.
    private var hasPendingEdit: Bool {
        guard let candidateLogin else { return false }
        return candidateLogin != storedFallbackLogin
    }

    private var artworkRefreshID: String {
        preference.customArtworkURL?.absoluteString ?? ""
    }

    private func toggleExpansion() {
        withAnimation(.easeInOut(duration: 0.15)) {
            isExpanded.toggle()
        }
    }

    private func syncFallback() {
        fallbackLogin = storedFallbackLogin.map { "@\($0)" } ?? ""
    }

    private func commitFallback() {
        settings.setFailoverStreamer(fallbackLogin, for: preference)
        syncFallback()
    }

    private func clearFallback() {
        settings.clearFailoverStreamer(for: preference)
        syncFallback()
    }
}
