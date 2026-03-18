import SwiftUI
import SwiftTwitchMiner

// MARK: - Drops List View

struct DropsListView: View {
    @Environment(NavigationModel.self) private var navigation
    @State private var filter: DropFilter = .active

    enum DropFilter: String, CaseIterable, Identifiable {
        case active = "Active"
        case claimed = "Claimed"
        case all = "All"
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            if displayGroups.isEmpty {
                emptyDropsView
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(displayGroups) { group in
                            GameGroupCard(group: group, filter: filter)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Drops")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    Task { await navigation.minerManager.startAll() }
                } label: {
                    Label("Start All", systemImage: "play.fill")
                }
                .help("Start all miners")

                Button {
                    Task { await navigation.minerManager.stopAll() }
                } label: {
                    Label("Stop All", systemImage: "stop.fill")
                }
                .help("Stop all miners")
            }

            ToolbarItem(placement: .primaryAction) {
                Picker("Filter", selection: $filter) {
                    ForEach(DropFilter.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }
        }
    }

    // MARK: - Empty State

    private var emptyDropsView: some View {
        VStack(spacing: 16) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(emptyTitle)
                .font(.headline)
            Text(emptySubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var emptyTitle: String {
        switch filter {
        case .active: return "No active drops available"
        case .claimed: return "No claimed drops yet"
        case .all: return "No campaigns found"
        }
    }

    private var emptySubtitle: String {
        if navigation.minerManager.miners.isEmpty {
            return "Add an account to start earning drops."
        }
        return "New campaigns will appear when active on Twitch."
    }

    // MARK: - Data Layer (Phase 5.2 Grouping)

    private var allDisplayCampaigns: [DisplayCampaign] {
        let campaigns = navigation.minerManager.campaignStore.campaigns
        let miners = navigation.minerManager.miners
        
        var accountStates: [String: [DropState]] = [:]
        for miner in miners {
            accountStates[miner.accountId] = miner.stateStore?.dropStates ?? []
        }
        
        return MergeService.merge(campaigns: campaigns, accountStates: accountStates)
    }

    private var displayGroups: [GameDisplayGroup] {
        // 1. Group all campaigns by Game ID or Name
        var groupsMap: [String: [DisplayCampaign]] = [:]
        for dc in allDisplayCampaigns {
            let key = dc.base.game.id.isEmpty ? dc.gameName.lowercased() : dc.base.game.id
            groupsMap[key, default: []].append(dc)
        }
        
        // 2. Build GameDisplayGroup objects
        let allGroups = groupsMap.map { (_, campaigns) -> GameDisplayGroup in
            let first = campaigns[0]
            let allDrops = campaigns.flatMap { $0.drops }
            
            return GameDisplayGroup(
                gameId: first.base.game.id,
                gameName: first.gameName,
                boxArtURL: first.base.game.boxArtURL,
                campaigns: campaigns,
                drops: allDrops
            )
        }
        
        // 3. Filter and Sort
        let result = allGroups.compactMap { group -> GameDisplayGroup? in
            var filteredDrops: [DisplayDrop] = []
            
            switch filter {
            case .active:
                // Rule: If ANY campaign in the group is eligible
                if !group.isEligibleByAnyAccount {
                    return nil
                }
                
                filteredDrops = group.drops.filter { drop in
                    drop.states.contains { $0.isEligible && !$0.isClaimed }
                }.sorted { a, b in
                    let aStatus = a.states.filter(\.isEligible).map(\.status).min() ?? .notStarted
                    let bStatus = b.states.filter(\.isEligible).map(\.status).min() ?? .notStarted
                    return aStatus < bStatus
                }
                
            case .claimed:
                filteredDrops = group.drops.filter { $0.isClaimedByAnyAccount }
                
            case .all:
                filteredDrops = group.drops.sorted { a, b in
                    let aStatus = a.states.map(\.status).min() ?? .notStarted
                    let bStatus = b.states.map(\.status).min() ?? .notStarted
                    return aStatus < bStatus
                }
            }
            
            if filteredDrops.isEmpty { return nil }
            
            return GameDisplayGroup(
                gameId: group.gameId,
                gameName: group.gameName,
                boxArtURL: group.boxArtURL,
                campaigns: group.campaigns,
                drops: filteredDrops
            )
        }.sorted { $0.gameName < $1.gameName }
        
        print("[Filter] \(filter.rawValue) → \(result.reduce(0) { $0 + $1.drops.count }) drops in \(result.count) games")
        return result
    }
}

// MARK: - Game Group Card

private struct GameGroupCard: View {
    let group: GameDisplayGroup
    let filter: DropsListView.DropFilter
    
    @State private var isExpanded: Bool

    init(group: GameDisplayGroup, filter: DropsListView.DropFilter) {
        self.group = group
        self.filter = filter
        // UNLINKED CAMPAIGN RULE: Collapse by default if not eligible
        self._isExpanded = State(initialValue: group.isEligibleByAnyAccount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header (Clickable to toggle)
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    if let url = group.boxArtURL {
                        AsyncImage(url: url) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Color.purple.opacity(0.1)
                        }
                        .frame(width: 40, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(group.gameName)
                                .font(.system(size: 16, weight: .bold))
                            
                            if !group.isEligibleByAnyAccount {
                                Text("Not linked")
                                    .font(.system(size: 10, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.red.opacity(0.1))
                                    .foregroundStyle(.red)
                                    .clipShape(Capsule())
                            }
                        }

                        // Show aggregate campaign info or just primary
                        let campaignNames = Array(Set(group.campaigns.map { $0.base.name })).sorted()
                        Text(campaignNames.joined(separator: ", "))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()
                    
                    if group.hasClaimableDrops {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                            .font(.system(size: 14))
                    }
                    
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider().opacity(0.1)

                // Flattened Drop List
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(group.drops) { drop in
                        GameDropRow(drop: drop)
                    }
                }
                .padding(16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(.ultraThinMaterial)
        .background(tintColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.primary.opacity(0.05), lineWidth: 0.5)
        )
    }

    private var tintColor: Color {
        let name = group.gameName.lowercased()
        if name.contains("finals") { return .pink }
        if name.contains("rust") { return .orange }
        if name.contains("raiders") { return .teal }
        return .purple
    }
}

// MARK: - Game Drop Row

private struct GameDropRow: View {
    let drop: DisplayDrop
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    // Thumbnail
                    Group {
                        if let url = drop.base.imageURL {
                            AsyncImage(url: url) { image in
                                image.resizable().aspectRatio(contentMode: .fit)
                            } placeholder: {
                                Color.secondary.opacity(0.1)
                            }
                        } else {
                            Color.secondary.opacity(0.1)
                        }
                    }
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    // Name + Status
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(drop.base.name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            
                            if !drop.states.isEmpty && drop.states.allSatisfy({ !$0.isEligible }) {
                                Text("Not linked")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.red.opacity(0.1))
                                    .foregroundStyle(.red)
                                    .clipShape(Capsule())
                            }
                        }

                        HStack(spacing: 4) {
                            if drop.isFullyClaimed {
                                Text("Claimed")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.green)
                            } else if drop.totalAccounts > 1 {
                                // Multi-account summary
                                Text("\(drop.claimedCount)/\(drop.totalAccounts) claimed • \(drop.totalAccounts - drop.claimedCount) active")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            } else if let state = drop.states.first {
                                // Single account detailed status
                                switch state.status {
                                case .claimed:
                                    Text("Claimed")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.green)
                                case .claimable:
                                    Text("Ready to claim")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.orange)
                                case .inProgress:
                                    Text("\(Int(state.percentComplete))% • \(state.minutesRemaining) min left")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.blue)
                                case .notStarted:
                                    Text("Not started • \(state.requiredMinutes) min")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Text("Not started • \(drop.base.requiredMinutes) min")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Spacer()

                    // Multi-Account Progress Bar (Best)
                    VStack(alignment: .trailing, spacing: 4) {
                        let percent = drop.bestProgressPercent
                        
                        ProgressView(value: percent, total: 100)
                            .progressViewStyle(.linear)
                            .frame(width: 80)
                            .tint(progressColor)
                        
                        Text("\(Int(percent))% • \(drop.base.requiredMinutes) min total")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            // Per-account detail
            if isExpanded && !drop.states.isEmpty {
                VStack(spacing: 8) {
                    ForEach(drop.states) { state in
                        AccountProgressRow(state: state)
                    }
                }
                .padding(.leading, 44)
                .padding(.bottom, 4)
                .transition(.opacity)
            }
        }
    }
    
    private var progressColor: Color {
        if drop.isFullyClaimed { return .green }
        if drop.isClaimableByAnyAccount { return .orange }
        return .blue
    }
}

// MARK: - Account Progress Row

private struct AccountProgressRow: View {
    let state: DropState

    var body: some View {
        HStack(spacing: 10) {
            Text(state.accountId.prefix(8))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.1))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(state.isClaimed ? Color.green : Color.blue.opacity(0.8))
                        .frame(width: geo.size.width * CGFloat(state.percentComplete / 100.0))
                }
            }
            .frame(height: 6)

            HStack(spacing: 4) {
                Text("\(state.progressMinutes)/\(state.requiredMinutes)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)

                if state.isClaimed {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.green)
                }
            }
            .frame(width: 60, alignment: .trailing)
        }
    }
}

// MARK: - Preview

#Preview("Drops List") {
    DropsListView()
        .environment(NavigationModel(clientId: "preview"))
        .frame(width: 600, height: 500)
}
