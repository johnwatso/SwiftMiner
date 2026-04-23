import SwiftUI
import SwiftMinerCore

/// Refactored event log view for monitoring system and miner activity (Phase 7).
///
/// Features:
/// - Top-level System Status card
/// - Grouped sections for Expired, Active, and Blocked campaigns
/// - Collapsible Detailed Events log (hidden by default)
/// - Simplified row design with relative timestamps
struct EventLogView: View {
    @Environment(NavigationModel.self) private var navigation
    @State private var detailedEventsExpanded = false
    @State private var searchText = ""
    @State private var levelFilter: EventLevel? = nil

    private var filteredEvents: [EventEntry] {
        navigation.events.filter { event in
            let matchesSearch = searchText.isEmpty || event.message.localizedCaseInsensitiveContains(searchText) || (event.rawMessage?.localizedCaseInsensitiveContains(searchText) ?? false)
            let matchesLevel = levelFilter == nil || event.level == levelFilter
            return matchesSearch && matchesLevel
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SystemStatusCard()
                CampaignGroupedSections()
                detailedEventsSection
            }
            .padding(24)
        }
        .navigationTitle("Events")
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

    private var detailedEventsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(duration: 0.3)) {
                    detailedEventsExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("Detailed Logs")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .rotationEffect(.degrees(detailedEventsExpanded ? 90 : 0))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if detailedEventsExpanded {
                VStack(spacing: 8) {
                    // Search + filter only visible when the section is open
                    HStack(spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            TextField("Search logs…", text: $searchText)
                                .textFieldStyle(.plain)
                                .font(.subheadline)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .glassControlSurface()

                        Picker("Level", selection: $levelFilter) {
                            Text("All").tag(nil as EventLevel?)
                            Text("Info").tag(EventLevel.info as EventLevel?)
                            Text("Warn").tag(EventLevel.warning as EventLevel?)
                            Text("Error").tag(EventLevel.error as EventLevel?)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    .padding(.horizontal, 14)

                    if filteredEvents.isEmpty {
                        Text(navigation.events.isEmpty ? "No events recorded this session." : "No results for '\(searchText)'.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 10)
                    } else {
                        VStack(spacing: 4) {
                            ForEach(filteredEvents) { event in
                                SimplifiedEventRow(event: event)
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .padding(.bottom, 8)
                    }
                }
            }
        }
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - System Status Card

private struct SystemStatusCard: View {
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        let status = deriveOverallStatus()
        
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("System Status")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    
                    Text(status.title)
                        .font(.title2.weight(.bold))
                }
                
                Spacer()
                
                statusIcon(for: status)
            }
            
            if !status.reasons.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(status.reasons, id: \.self) { reason in
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle")
                                .font(.caption)
                            Text(reason)
                                .font(.subheadline)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(20)
        .glassCard()
    }

    @ViewBuilder
    private func statusIcon(for status: SystemStatus) -> some View {
        ZStack {
            Circle()
                .fill(status.color.opacity(0.15))
                .frame(width: 48, height: 48)
            
            Image(systemName: status.icon)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(status.color)
        }
    }

    private struct SystemStatus {
        let title: String
        let reasons: [String]
        let icon: String
        let color: Color
    }

    private func deriveOverallStatus() -> SystemStatus {
        let miners = navigation.minerManager.miners
        if miners.isEmpty {
            return SystemStatus(title: "Idle", reasons: ["No accounts connected"], icon: "zzz", color: .gray)
        }

        let primaryStates = miners.map { $0.primaryState }
        
        // Priority 1: Blocked
        if let blockedState = primaryStates.compactMap({ if case .blocked(let reasons) = $0 { return reasons } else { return nil } }).first {
            let reasons = blockedState.map { r -> String in
                switch r {
                case .accountNotLinked: return "Account not linked"
                case .noEligibleCampaign: return "No eligible campaigns"
                case .noLiveStreams: return "No live streams"
                }
            }
            return SystemStatus(title: "Blocked", reasons: reasons, icon: "exclamationmark.octagon.fill", color: .red)
        }

        // Priority 2: Mining
        if let miningProgress = primaryStates.compactMap({ if case .mining(let progress) = $0 { return progress } else { return nil } }).first {
            return SystemStatus(title: "Mining", reasons: ["Watching \(miningProgress.gameName)"], icon: "hammer.fill", color: .green)
        }

        // Priority 3: Completed
        if primaryStates.allSatisfy({ $0 == .completed }) {
            return SystemStatus(title: "Completed", reasons: ["All drops earned"], icon: "checkmark.circle.fill", color: .blue)
        }

        return SystemStatus(title: "Idle", reasons: ["No active mining tasks"], icon: "zzz", color: .gray)
    }
}

// MARK: - Campaign Grouped Sections

private struct CampaignGroupedSections: View {
    @Environment(NavigationModel.self) private var navigation
    @State private var expandedSections: Set<SectionType> = [.active, .blocked]

    enum SectionType: String, Hashable {
        case active = "Active Campaigns"
        case blocked = "Blocked Campaigns"
        case expired = "Expired Campaigns"
    }

    var body: some View {
        let miners = navigation.minerManager.miners
        let allCampaigns = miners.flatMap { $0.allCampaigns }
        
        // Grouping logic
        let expired = allCampaigns.filter { !$0.isTimeActive && $0.drops.contains { !$0.isClaimed } }
        let active = allCampaigns.filter { $0.isTimeActive && $0.isAccountConnected && $0.drops.contains { !$0.isClaimed } }
        let blocked = allCampaigns.filter { $0.isTimeActive && !$0.isAccountConnected && $0.drops.contains { !$0.isClaimed } }

        VStack(spacing: 12) {
            if !active.isEmpty {
                groupSection(type: .active, campaigns: active)
            }
            
            if !blocked.isEmpty {
                groupSection(type: .blocked, campaigns: blocked)
            }
            
            if !expired.isEmpty {
                groupSection(type: .expired, campaigns: expired)
            }
            
            if active.isEmpty && blocked.isEmpty && expired.isEmpty {
                emptyState
            }
        }
    }

    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                Text("No recent activity")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 32)
    }

    private func groupSection(type: SectionType, campaigns: [Campaign]) -> some View {
        let uniqueCampaigns = Array(Dictionary(grouping: campaigns, by: { $0.id }).values.compactMap { $0.first })
            .sorted(by: { $0.gameName < $1.gameName })

        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.spring(duration: 0.3)) {
                    if expandedSections.contains(type) {
                        expandedSections.remove(type)
                    } else {
                        expandedSections.insert(type)
                    }
                }
            } label: {
                HStack {
                    Text(type == .expired ? "\(type.rawValue) (\(uniqueCampaigns.count))" : type.rawValue)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .rotationEffect(.degrees(expandedSections.contains(type) ? 90 : 0))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .glassCard()
            }
            .buttonStyle(.plain)

            if expandedSections.contains(type) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(uniqueCampaigns) { campaign in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(typeColor(for: type))
                                .frame(width: 6, height: 6)
                            
                            Text(campaign.gameName)
                                .font(.subheadline.weight(.medium))
                            
                            Text("—")
                                .foregroundStyle(.tertiary)
                            
                            Text(campaign.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.leading, 24)
                        .padding(.vertical, 4)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func typeColor(for type: SectionType) -> Color {
        switch type {
        case .active: return .green
        case .blocked: return .red
        case .expired: return .gray
        }
    }
}

// MARK: - Simplified Event Row

private struct SimplifiedEventRow: View {
    let event: EventEntry
    
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            severityIcon
            
            Text(simplifiedMessage(event.message))
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            
            Spacer()
            
            Text(relativeTimeString(for: event.timestamp))
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
    }

    private func simplifiedMessage(_ message: String) -> String {
        // Remove common prefixes/brackets
        var msg = message
        let patterns = ["\\[.*?\\]", "Miner\\s[a-f0-9]{4}:", "⚠️", "❌", "✅"]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                msg = regex.stringByReplacingMatches(in: msg, range: NSRange(msg.startIndex..., in: msg), withTemplate: "")
            }
        }
        return msg.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func relativeTimeString(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    @ViewBuilder
    private var severityIcon: some View {
        let color: Color = {
            switch event.level {
            case .info: return .blue
            case .warning: return .orange
            case .error: return .red
            }
        }()
        
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }
}

// MARK: - Legacy Row (used by other views)

struct MinerEventRow: View {
    let event: EventEntry
    let showRaw: Bool
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                severityIcon
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(event.timestamp.formatted(.dateTime.hour().minute().second()))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        
                        if let minerId = event.minerId {
                            Text("•")
                                .foregroundStyle(.tertiary)
                            Text(minerName(for: minerId))
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(showRaw ? (event.rawMessage ?? event.message) : event.message)
                        .font(.body)
                        .foregroundStyle(.primary)

                    if showRaw, let raw = event.rawMessage {
                        Text(raw)
                            .font(.caption.monospaced())
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                            .padding(.top, 4)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassCard()
        .padding(.vertical, 4)
    }

    private func minerName(for minerId: String) -> String {
        if let miner = navigation.minerManager.miners.first(where: { $0.id == minerId }) {
            return miner.username
        }
        return "Miner \(minerId.prefix(4))"
    }

    @ViewBuilder
    private var severityIcon: some View {
        let color: Color = {
            switch event.level {
            case .info: return .blue
            case .warning: return .orange
            case .error: return .red
            }
        }()
        
        let icon: String = {
            switch event.level {
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.circle.fill"
            }
        }()

        Image(systemName: icon)
            .foregroundStyle(color)
            .font(.system(size: 16))
            .frame(width: 24, height: 24)
    }
}

#Preview {
    EventLogView()
        .environment(NavigationModel(clientId: "preview"))
}
