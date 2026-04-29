import SwiftUI
import SwiftMinerCore

/// Dense, flat event log focused on chronological scanning.
struct EventLogView: View {
    @Environment(NavigationModel.self) private var navigation
    @ObservedObject private var settings = Settings.shared
    @State private var searchText = ""
    @State private var selectedMinerFilterId = Self.allMinersFilterId

    private static let allMinersFilterId = "__all_miners__"

    private var selectedFilters: Set<EventFilter> {
        get { settings.selectedEventFilters }
        nonmutating set { settings.selectedEventFilters = newValue }
    }

    private var miners: [MinerManager.ManagedMiner] {
        navigation.minerManager.miners
    }

    private var visibleEvents: [EventEntry] {
        navigation.events.filter { event in
            guard !eventFilters(for: event).intersection(selectedFilters).isEmpty else { return false }
            guard selectedMinerFilterId == Self.allMinersFilterId || event.minerId == selectedMinerFilterId else { return false }
            return matchesSearch(event)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            controlsHeader

            if visibleEvents.isEmpty {
                emptyState
            } else {
                List(visibleEvents) { event in
                    EventLogRow(event: event)
                        .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
                        .listRowSeparator(.visible, edges: .bottom)
                        .listRowSeparatorTint(.secondary.opacity(0.14))
                        .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Events")
        .onChange(of: miners.map(\.id)) { _, minerIds in
            guard selectedMinerFilterId != Self.allMinersFilterId,
                  !minerIds.contains(selectedMinerFilterId)
            else { return }
            selectedMinerFilterId = Self.allMinersFilterId
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    navigation.clearEvents()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Clear logs")
                .disabled(navigation.events.isEmpty)
            }
        }
    }

    private var controlsHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                searchField

                if miners.count > 1 {
                    minerFilterMenu
                }
            }

            filterChipsRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.secondary.opacity(0.12))
                .frame(height: 1)
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)

            TextField("Search events", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .frame(maxWidth: 320)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        )
    }

    private var minerFilterMenu: some View {
        Picker("Miner", selection: $selectedMinerFilterId) {
            Text("All miners").tag(Self.allMinersFilterId)
            ForEach(miners) { miner in
                Text(miner.username).tag(miner.id)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 160)
        .help("Filter events by miner")
    }

    private var filterChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(EventFilter.allCases) { option in
                    let isSelected = selectedFilters.contains(option)
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            var current = selectedFilters
                            if isSelected {
                                current.remove(option)
                            } else {
                                current.insert(option)
                            }
                            selectedFilters = current
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: option.symbol)
                                .font(.caption.weight(.semibold))
                            Text(option.title)
                                .font(.subheadline.weight(.medium))
                        }
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Group {
                                if isSelected {
                                    Capsule().fill(.thinMaterial.opacity(0.95))
                                } else {
                                    Capsule().fill(Color.clear)
                                }
                            }
                        )
                        .overlay(
                            Capsule()
                                .stroke(isSelected ? Color.primary.opacity(0.20) : Color.secondary.opacity(0.18), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Toggle \(option.title) events")
                    .accessibilityLabel(option.title)
                    .accessibilityValue(isSelected ? "Selected" : "Not selected")
                }
            }
            .padding(.horizontal, 1)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Event filters")
    }

    private var emptyState: some View {
        HStack {
            Text(emptyStateMessage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    private var emptyStateMessage: String {
        if selectedFilters.isEmpty {
            return "Select at least one filter"
        }
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No events match your search"
        }
        return "No matching events"
    }

    private func matchesSearch(_ event: EventEntry) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }

        let minerName = event.minerId.flatMap { minerId in
            miners.first(where: { $0.id == minerId })?.username
        } ?? ""
        let searchableText = [
            event.message,
            event.rawMessage ?? "",
            minerName
        ].joined(separator: " ")

        return searchableText.localizedCaseInsensitiveContains(query)
    }
}

private struct EventLogRow: View {
    let event: EventEntry
    @Environment(NavigationModel.self) private var navigation

    private var levelColor: Color {
        if isHeartbeatEvent(eventSearchText(for: event)) {
            return .pink
        }

        switch event.level {
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }

    private var messageText: String {
        if let raw = event.rawMessage,
           let campaignSummary = campaignStatusSummary(from: raw) {
            return campaignSummary
        }
        return simplifyMessage(event.message)
    }

    private var metadataText: String? {
        guard let minerId = event.minerId else { return nil }
        if let miner = navigation.minerManager.miners.first(where: { $0.id == minerId }) {
            return miner.username
        }
        return "Miner \(minerId.prefix(4))"
    }

    private var relativeTime: String {
        relativeDateFormatter.localizedString(for: event.timestamp, relativeTo: Date())
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(levelColor)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 1) {
                Text(messageText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let metadataText {
                    Text(metadataText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            Text(relativeTime)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, metadataText == nil ? 1 : 2)
    }
}

// MARK: - Message Formatting

private func eventFilters(for event: EventEntry) -> Set<EventFilter> {
    let text = eventSearchText(for: event)

    if isHeartbeatEvent(text) {
        return [.heartbeats]
    }

    if isAccountLinkEvent(text) {
        return [.accountLink]
    }

    if isScanNoiseEvent(text) {
        return [.scan]
    }

    if event.level == .error {
        return [.errors]
    }

    if isDropEvent(text) {
        return [.drops]
    }

    if isMiningEvent(text) {
        return event.level == .warning ? [.mining, .warnings] : [.mining]
    }

    if event.level == .warning {
        return [.warnings]
    }

    return [.system]
}

private func eventSearchText(for event: EventEntry) -> String {
    "\(event.rawMessage ?? "") \(event.message)".lowercased()
}

private func isHeartbeatEvent(_ text: String) -> Bool {
    text.contains("watch heartbeat sent")
        || text.contains("minute-watched")
        || text.contains("[spade]")
}

private func isAccountLinkEvent(_ text: String) -> Bool {
    text.contains("account not linked")
        || text.contains("account linking")
        || text.contains("link required")
        || text.contains("not_connected")
        || text.contains("not connected")
        || text.contains("unlinked")
        || text.contains("blockedaccountnotlinked")
}

private func isScanNoiseEvent(_ text: String) -> Bool {
    text.contains("relevance: irrelevant")
        || text.contains("→ irrelevant")
        || text.contains("filtered out")
        || text.contains("campaigns:")
        || text.contains("fetching active campaigns")
        || text.contains("no claimable drops found")
}

private func isDropEvent(_ text: String) -> Bool {
    text.contains("drop claimed")
        || text.contains("drop claimable")
        || text.contains("claimed drop")
        || text.contains("claimable drop")
        || text.contains("progress +")
        || text.contains("drop-progress")
}

private func isMiningEvent(_ text: String) -> Bool {
    text.contains("selected channel")
        || text.contains("started watching")
        || text.contains("pubsub watching started")
        || text.contains("minute-watched")
        || text.contains("watch session")
        || text.contains("checking game")
        || text.contains("progress stalled")
        || text.contains("switching channel")
}

private func simplifyMessage(_ message: String) -> String {
    var text = message
        .replacingOccurrences(of: #"\[[^\]]+\]\s*"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"^Miner\s+[A-Za-z0-9_-]+:\s*"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"^\s*[•·]\s*"#, with: "", options: .regularExpression)

    for marker in ["⚠️", "❌", "✅", "🔄"] {
        text = text.replacingOccurrences(of: marker, with: "")
    }

    if let campaignSummary = campaignStatusSummary(from: text) {
        return campaignSummary
    }

    if text.localizedCaseInsensitiveContains("Watch heartbeat sent for ") {
        return text.replacingOccurrences(
            of: #"(?i)^.*Watch heartbeat sent for\s+"#,
            with: "Heartbeat sent to ",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func campaignStatusSummary(from text: String) -> String? {
    let parts = text
        .components(separatedBy: "→")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

    guard let namePart = parts.first,
          let statusPart = parts.first(where: { $0.localizedCaseInsensitiveContains("Status:") })
    else { return nil }

    let gameName = campaignDisplayName(from: namePart)
    let status = statusPart
        .replacingOccurrences(of: "Status:", with: "", options: .caseInsensitive)
        .trimmingCharacters(in: .whitespacesAndNewlines)

    guard !gameName.isEmpty, !status.isEmpty else { return nil }
    return "\(gameName) — \(humanStatus(status))"
}

private func campaignDisplayName(from text: String) -> String {
    let trimmed = text
        .replacingOccurrences(of: #"^\s*V\d+(?:\.\d+)*\s+"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"^\s*[•·]\s*"#, with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)

    if let open = trimmed.lastIndex(of: "("),
       let close = trimmed.lastIndex(of: ")"),
       open < close {
        return String(trimmed[trimmed.index(after: open)..<close])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    return trimmed
}

private func humanStatus(_ status: String) -> String {
    status
        .split(separator: "_")
        .map { word in
            word.prefix(1).uppercased() + word.dropFirst().lowercased()
        }
        .joined(separator: " ")
}

@MainActor private let relativeDateFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
}()

// MARK: - Legacy row (used by MinerDetailView)

struct MinerEventRow: View {
    let event: EventEntry
    let showRaw: Bool
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 10) {
                Circle()
                    .fill(levelColor)
                    .frame(width: 7, height: 7)

                Text(showRaw ? (event.rawMessage ?? event.message) : event.message)
                    .font(.system(size: 12))
                    .lineLimit(1)

                Spacer(minLength: 12)

                Text(event.timestamp.formatted(.dateTime.hour().minute().second()))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            if let minerId = event.minerId {
                Text(minerName(for: minerId))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 17)
            }

            if showRaw, let raw = event.rawMessage, raw != event.message {
                Text(raw)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.leading, 17)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var levelColor: Color {
        switch event.level {
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func minerName(for minerId: String) -> String {
        navigation.minerManager.miners.first(where: { $0.id == minerId }).map(\.username)
            ?? "Miner \(minerId.prefix(4))"
    }
}

#Preview {
    EventLogView()
        .environment(NavigationModel(clientId: "preview"))
}
