import SwiftUI
import SwiftMinerCore

/// Dense, flat event log focused on chronological scanning.
struct EventLogView: View {
    @Environment(NavigationModel.self) private var navigation
    @ObservedObject private var settings = Settings.shared
    @State private var searchText = ""
    @State private var selectedMinerFilterId = Self.allMinersFilterId
    @State private var isFilterHelpPresented = false
    @State private var seenEventIds: Set<UUID> = []

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
                eventList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Activity Log")
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

    private var eventList: some View {
        List(visibleEvents) { event in
            let isNew = !seenEventIds.contains(event.id)
            EventLogRow(event: event, isNew: isNew)
                .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
                .listRowSeparator(.visible, edges: .bottom)
                .listRowSeparatorTint(.secondary.opacity(0.14))
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .onAppear {
            seenEventIds = Set(visibleEvents.map(\.id))
        }
        .onChange(of: visibleEvents.map(\.id)) { _, ids in
            seenEventIds.formUnion(ids)
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

            TextField("Search activity", text: $searchText)
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
                Text(miner.displayName).tag(miner.id)
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
                    .help("Toggle \(option.title) activity")
                    .accessibilityLabel(option.title)
                    .accessibilityValue(isSelected ? "Selected" : "Not selected")
                }

                filterHelpButton
            }
            .padding(.horizontal, 1)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Activity filters")
    }

    private var filterHelpButton: some View {
        Button {
            isFilterHelpPresented.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .help("Explain event filters")
        .accessibilityLabel("Explain event filters")
        .popover(isPresented: $isFilterHelpPresented, arrowEdge: .top) {
            EventFilterHelpPopover()
        }
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
            return "No activity matches your search"
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

private struct EventFilterHelpPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Activity Filters")
                .font(.headline)

            VStack(alignment: .leading, spacing: 11) {
                ForEach(EventFilter.allCases) { filter in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: filter.symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(filter.eventColor)
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(filter.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)

                            Text(filter.description)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineSpacing(1.5)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
    }
}

private struct EventLogRow: View {
    let event: EventEntry
    let isNew: Bool
    @Environment(NavigationModel.self) private var navigation
    @ObservedObject private var settings = Settings.shared
    @State private var appeared = false

    private var eventFilter: EventFilter {
        primaryEventFilter(for: event)
    }

    private var displayText: EventDisplayText {
        eventDisplayText(for: event)
    }

    private var eventColor: Color {
        eventFilter.eventColor
    }

    private var messageText: String {
        displayText.title
    }

    private var metadataText: String? {
        var parts: [String] = []
        if let detail = displayText.detail {
            parts.append(detail)
        }

        guard let minerId = event.minerId else {
            return parts.isEmpty ? nil : parts.joined(separator: " • ")
        }

        if let miner = navigation.minerManager.miners.first(where: { $0.id == minerId }) {
            parts.append(miner.username)
        } else {
            parts.append("Miner \(minerId.prefix(4))")
        }

        return parts.joined(separator: " • ")
    }

    private var relativeTime: String {
        event.timestamp.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second())
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if settings.showActivityLogIcons {
                Image(systemName: eventFilter.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(eventColor)
                    .frame(width: 16, alignment: .center)
            } else {
                Circle()
                    .fill(eventColor)
                    .frame(width: 7, height: 7)
            }

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
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, metadataText == nil ? 1 : 2)
        .opacity(settings.animateActivityLogRows && isNew ? (appeared ? 1 : 0) : 1)
        .offset(y: settings.animateActivityLogRows && isNew ? (appeared ? 0 : 6) : 0)
        .onAppear {
            guard settings.animateActivityLogRows, isNew else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                appeared = true
            }
        }
    }
}

// MARK: - Message Formatting

private struct EventDisplayText {
    let title: String
    let detail: String?
}

private func eventDisplayText(for event: EventEntry) -> EventDisplayText {
    let source = event.rawMessage ?? event.message
    let cleaned = cleanedEventText(source)
    let lowercased = cleaned.lowercased()

    if let campaignSummary = campaignStatusSummary(from: cleaned) {
        return campaignSummary
    }

    if let channel = value(after: "Selected channel:", in: cleaned) {
        return EventDisplayText(title: "Selected channel \(channel)", detail: nil)
    }

    if let channel = watchHeartbeatChannel(from: cleaned) {
        return EventDisplayText(title: "Watch signal sent", detail: channel)
    }

    if lowercased.contains("pubsub watching started") {
        return EventDisplayText(title: "Drop notifications started", detail: nil)
    }

    if let channel = value(after: "Started watching", in: cleaned) {
        return EventDisplayText(title: "Started watching", detail: trimmedSentence(channel))
    }

    if let game = checkingGameName(from: cleaned) {
        return EventDisplayText(title: "Checking \(game)", detail: nil)
    }

    if let channel = verifyingChannel(from: cleaned) {
        return channel
    }

    if let channelSearch = noEligibleChannels(from: cleaned) {
        return channelSearch
    }

    if lowercased.contains("none of our candidates active here")
        || lowercased.contains("campaign mismatch")
        || lowercased.contains("acl blocked match") {
        return EventDisplayText(title: "Channel does not have this drop", detail: "Trying another channel")
    }

    if lowercased.contains("no candidate channels matched campaign requirements") {
        return EventDisplayText(title: "No matching channels found", detail: nil)
    }

    if lowercased.contains("no live channels found") {
        return EventDisplayText(title: "No live channels found", detail: gameFromQuotedText(cleaned))
    }

    if lowercased.contains("found") && lowercased.contains("live candidate channel") {
        return EventDisplayText(title: "Live channels found", detail: liveChannelCount(from: cleaned))
    }

    if lowercased.contains("fetching active campaigns") {
        return EventDisplayText(title: "Refreshing campaigns", detail: nil)
    }

    if let counts = campaignCounts(from: cleaned) {
        return EventDisplayText(title: "Campaign scan completed", detail: counts)
    }

    if lowercased.contains("no claimable drops found") {
        return EventDisplayText(title: "No drops ready to claim", detail: nil)
    }

    if let drops = foundClaimableDrops(from: cleaned) {
        return EventDisplayText(title: "Drops ready to claim", detail: drops)
    }

    if let drop = value(after: "Claimed drop:", in: cleaned) {
        return EventDisplayText(title: "Drop claimed", detail: trimmedSentence(drop))
    }

    if lowercased.contains("auto-claimed drop") || lowercased.contains("drop claimed successfully") {
        return EventDisplayText(title: "Drop claimed", detail: nil)
    }

    if lowercased.contains("drop claim event received") {
        return EventDisplayText(title: "Drop claim received", detail: nil)
    }

    if let drop = dropClaimIssue(from: cleaned) {
        return EventDisplayText(title: "Drop could not be claimed", detail: drop)
    }

    if let progress = progressUpdate(from: cleaned) {
        return EventDisplayText(title: "Drop progress updated", detail: progress)
    }

    if lowercased.contains("account linking is required")
        || lowercased.contains("account not linked")
        || lowercased.contains("link required")
        || lowercased.contains("not connected")
        || lowercased.contains("unlinked") {
        return EventDisplayText(title: "Account link required", detail: accountLinkDetail(from: cleaned))
    }

    if lowercased.contains("progress stalled") {
        return EventDisplayText(title: "Progress stalled", detail: "Switching channels")
    }

    if lowercased.contains("switching channel") {
        return EventDisplayText(title: "Switching channel", detail: nil)
    }

    if lowercased.contains("inventory refreshed") {
        return EventDisplayText(title: "Inventory refreshed", detail: inventoryCounts(from: cleaned))
    }

    if lowercased.contains("maintenance") && lowercased.contains("token") {
        return EventDisplayText(title: "Authentication checked", detail: nil)
    }

    if lowercased.hasPrefix("error:") {
        return EventDisplayText(title: "Something went wrong", detail: trimmedSentence(cleaned.replacingOccurrences(of: "Error:", with: "")))
    }

    if lowercased.contains("failed to") || lowercased.contains("could not") {
        return EventDisplayText(title: failureTitle(from: cleaned), detail: failureDetail(from: cleaned))
    }

    if lowercased.contains("warning:") || lowercased.contains("watch session warning") || lowercased.contains("maintenance task warning") {
        return EventDisplayText(title: "Attention needed", detail: warningDetail(from: cleaned))
    }

    return EventDisplayText(title: humanReadableFallback(cleaned), detail: nil)
}

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

private func primaryEventFilter(for event: EventEntry) -> EventFilter {
    let filters = eventFilters(for: event)
    let displayOrder: [EventFilter] = [
        .errors,
        .warnings,
        .accountLink,
        .drops,
        .heartbeats,
        .mining,
        .scan,
        .system
    ]

    return displayOrder.first { filters.contains($0) } ?? .system
}

private extension EventFilter {
    var eventColor: Color {
        switch self {
        case .mining: return .blue
        case .heartbeats: return .pink
        case .drops: return .green
        case .warnings: return .orange
        case .errors: return .red
        case .accountLink: return .purple
        case .scan: return .teal
        case .system: return .gray
        }
    }
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

private func cleanedEventText(_ message: String) -> String {
    var text = message
        .replacingOccurrences(of: #"\[[^\]]+\]\s*"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"^Miner\s+[A-Za-z0-9_-]+:\s*"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"^\s*[•·]\s*"#, with: "", options: .regularExpression)

    for marker in ["⚠️", "❌", "✅", "🔄", "📋", "🧪", "✓", "✗"] {
        text = text.replacingOccurrences(of: marker, with: "")
    }

    return text
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func value(after prefix: String, in text: String) -> String? {
    guard let range = text.range(of: prefix, options: .caseInsensitive) else { return nil }
    let value = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
}

private func matchGroups(_ pattern: String, in text: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
        return nil
    }

    let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: nsRange) else { return nil }

    return (1..<match.numberOfRanges).compactMap { index in
        let range = match.range(at: index)
        guard let swiftRange = Range(range, in: text) else { return nil }
        return String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private func watchHeartbeatChannel(from text: String) -> String? {
    matchGroups(#"Watch heartbeat sent for\s+(.+?)(?:\s+via\s+.+)?$"#, in: text)?.first
}

private func checkingGameName(from text: String) -> String? {
    matchGroups(#"Checking game:\s+(.+?)(?:\s+\(\d+\s+candidate campaign\(s\)\))?$"#, in: text)?.first
}

private func verifyingChannel(from text: String) -> EventDisplayText? {
    guard let groups = matchGroups(#"Verifying\s+(.+?)\s+\(viewers:\s+(\d+),\s+id:\s+\d+\)"#, in: text),
          groups.count == 2
    else { return nil }

    let viewerText = groups[1] == "1" ? "1 viewer" : "\(groups[1]) viewers"
    return EventDisplayText(title: "Checking channel \(groups[0])", detail: viewerText)
}

private func noEligibleChannels(from text: String) -> EventDisplayText? {
    guard let target = matchGroups(#"No eligible channels available for\s+(.+?)(?:; trying next game\.)?$"#, in: text)?.first else {
        return nil
    }

    let detail = text.localizedCaseInsensitiveContains("trying next game")
        ? "Trying the next game"
        : nil

    if let count = matchGroups(#"^(\d+)\s+account-eligible campaign\(s\)$"#, in: target)?.first {
        let campaignText = count == "1" ? "1 available campaign" : "\(count) available campaigns"
        return EventDisplayText(title: "No channels found", detail: [campaignText, detail].compactMap(\.self).joined(separator: " • "))
    }

    return EventDisplayText(title: "No channels found for \(target)", detail: detail)
}

private func gameFromQuotedText(_ text: String) -> String? {
    matchGroups(#"'([^']+)'"#, in: text)?.first
}

private func liveChannelCount(from text: String) -> String? {
    guard let count = matchGroups(#"Found\s+(\d+)\s+live candidate channel"#, in: text)?.first else {
        return nil
    }
    return count == "1" ? "1 channel" : "\(count) channels"
}

private func campaignCounts(from text: String) -> String? {
    guard let groups = matchGroups(#"Campaigns:\s+(\d+)\s+total,\s+(\d+)\s+account-eligible"#, in: text),
          groups.count == 2
    else { return nil }
    return "\(groups[0]) total, \(groups[1]) available"
}

private func foundClaimableDrops(from text: String) -> String? {
    matchGroups(#"Found\s+\d+\s+claimable drop\(s\):\s+(.+)$"#, in: text)?.first
}

private func dropClaimIssue(from text: String) -> String? {
    matchGroups(#"Drop claim returned not-success for\s+(.+)$"#, in: text)?.first
        ?? matchGroups(#"Failed to auto-claim drop:\s+(.+)$"#, in: text)?.first
}

private func progressUpdate(from text: String) -> String? {
    if let progress = matchGroups(#"(.+?)\s+from Twitch inventory$"#, in: text)?.first {
        return progress
    }
    if text.localizedCaseInsensitiveContains("progress +") || text.localizedCaseInsensitiveContains("drop-progress") {
        return humanReadableFallback(text)
    }
    return nil
}

private func accountLinkDetail(from text: String) -> String? {
    if let groups = matchGroups(#"Priority game blocked:\s+(.+?)\s+is prioritised"#, in: text),
       let game = groups.first {
        return game
    }
    return nil
}

private func inventoryCounts(from text: String) -> String? {
    guard let groups = matchGroups(#"Inventory refreshed:\s+(\d+)\s+claimed benefits,\s+(\d+)\s+in-progress drops"#, in: text),
          groups.count == 2
    else { return nil }
    return "\(groups[0]) claimed, \(groups[1]) in progress"
}

private func failureTitle(from text: String) -> String {
    let lowercased = text.lowercased()
    if lowercased.contains("pubsub") {
        return "Drop notifications failed"
    }
    if lowercased.contains("fetch live channels") {
        return "Could not load live channels"
    }
    if lowercased.contains("verify") || lowercased.contains("verification") {
        return "Could not verify channel"
    }
    if lowercased.contains("inventory") {
        return "Could not refresh inventory"
    }
    if lowercased.contains("claim") {
        return "Could not claim drop"
    }
    return "Action failed"
}

private func failureDetail(from text: String) -> String? {
    if let detail = matchGroups(#"(?:failed to|could not)\s+.+?:\s+(.+)$"#, in: text)?.first {
        return trimmedSentence(detail)
    }
    return nil
}

private func warningDetail(from text: String) -> String? {
    let detail = text
        .replacingOccurrences(of: #"(?i)^warning:\s*"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"(?i)^watch session warning:\s*"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"(?i)^maintenance task warning:\s*"#, with: "", options: .regularExpression)
    let trimmed = trimmedSentence(detail)
    return trimmed.isEmpty ? nil : trimmed
}

private func campaignStatusSummary(from text: String) -> EventDisplayText? {
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
    return EventDisplayText(title: gameName, detail: humanStatus(status))
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

private func trimmedSentence(_ text: String) -> String {
    text
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: " .").union(.whitespacesAndNewlines))
}

private func humanReadableFallback(_ text: String) -> String {
    var readable = text
        .replacingOccurrences(of: #"(?i)^debug:\s*"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"(?i)^warning:\s*"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"(?i)^error:\s*"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"\bPubSub\b"#, with: "Drop notifications", options: .regularExpression)
        .replacingOccurrences(of: #"\bSpade\b"#, with: "watch signal", options: .regularExpression)
        .replacingOccurrences(of: #"dropInstanceId=[A-Za-z0-9_-]+"#, with: "drop", options: .regularExpression)
        .replacingOccurrences(of: #"user:[A-Za-z0-9_-]+\s+channel:[A-Za-z0-9_-]+"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)

    guard !readable.isEmpty else { return "Event recorded" }

    let first = readable.prefix(1).uppercased()
    readable = first + readable.dropFirst()
    return readable
}

// MARK: - Legacy row (used by MinerDetailView)

struct MinerEventRow: View {
    let event: EventEntry
    let showRaw: Bool
    @Environment(NavigationModel.self) private var navigation

    private var displayText: EventDisplayText {
        eventDisplayText(for: event)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 10) {
                Circle()
                    .fill(levelColor)
                    .frame(width: 7, height: 7)

                Text(showRaw ? (event.rawMessage ?? event.message) : displayText.title)
                    .font(.system(size: 12))
                    .lineLimit(1)

                Spacer(minLength: 12)

                Text(event.timestamp.formatted(.dateTime.hour().minute().second()))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            if let metadataText {
                Text(metadataText)
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
        primaryEventFilter(for: event).eventColor
    }

    private var metadataText: String? {
        var parts: [String] = []
        if !showRaw, let detail = displayText.detail {
            parts.append(detail)
        }
        if let minerId = event.minerId {
            parts.append(minerName(for: minerId))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private func minerName(for minerId: String) -> String {
        navigation.minerManager.miners.first(where: { $0.id == minerId }).map(\.displayName)
            ?? "Miner \(minerId.prefix(4))"
    }
}

#Preview {
    EventLogView()
        .environment(NavigationModel(clientId: "preview"))
}
