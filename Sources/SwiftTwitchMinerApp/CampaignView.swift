import SwiftUI
import SwiftTwitchMiner

// MARK: - Drops List View

struct DropsListView: View {
    @Environment(NavigationModel.self) private var navigation
    @State private var filter: DropFilter = .active

    enum DropFilter: String, CaseIterable, Identifiable {
        case active = "Active"
        case claimable = "Claimable"
        case all = "All"
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            if displayCampaigns.isEmpty {
                emptyDropsView
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(displayCampaigns) { displayCampaign in
                            GameGroupCard(displayCampaign: displayCampaign, filter: filter)
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
        case .active: return "No active drops"
        case .claimable: return "No claimable drops"
        case .all: return "No drops found"
        }
    }

    private var emptySubtitle: String {
        if navigation.minerManager.miners.isEmpty {
            return "Add an account to start earning drops."
        }
        return "Campaigns will appear here when active on Twitch."
    }

    // MARK: - Data Layer (Phase 3 Merge)

    /// Merged campaigns across all miners
    private var allDisplayCampaigns: [DisplayCampaign] {
        let campaigns = navigation.minerManager.campaignStore.campaigns
        let miners = navigation.minerManager.miners
        
        // accountId -> [DropState]
        var accountStates: [String: [DropState]] = [:]
        for miner in miners {
            accountStates[miner.accountId] = miner.stateStore?.dropStates ?? []
        }
        
        return MergeService.merge(campaigns: campaigns, accountStates: accountStates)
    }

    private var displayCampaigns: [DisplayCampaign] {
        allDisplayCampaigns.compactMap { displayCampaign in
            var filtered = displayCampaign
            
            switch filter {
            case .active:
                // Active: any state.progress < 100 AND !isClaimed
                // (Or if no accounts, show active campaigns)
                if navigation.minerManager.miners.isEmpty {
                    return displayCampaign.isTimeActive ? displayCampaign : nil
                }
                
                let activeDrops = displayCampaign.drops.filter { drop in
                    // If any account still needs this drop
                    let needsEarning = drop.states.isEmpty || drop.states.contains { !$0.isComplete && !$0.isClaimed }
                    return needsEarning && !drop.isFullyClaimed
                }
                if activeDrops.isEmpty { return nil }
                filtered = DisplayCampaign(base: displayCampaign.base, drops: activeDrops)
                
            case .claimable:
                // Claimable: any state.progress == 100 AND !isClaimed
                let claimableDrops = displayCampaign.drops.filter { $0.isClaimableByAnyAccount }
                if claimableDrops.isEmpty { return nil }
                filtered = DisplayCampaign(base: displayCampaign.base, drops: claimableDrops)
                
            case .all:
                return displayCampaign
            }
            
            return filtered
        }.sorted { $0.gameName < $1.gameName }
    }
}

// MARK: - Game Group Card

private struct GameGroupCard: View {
    let displayCampaign: DisplayCampaign
    let filter: DropsListView.DropFilter

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 12) {
                if let url = displayCampaign.base.game.boxArtURL {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color.purple.opacity(0.1)
                    }
                    .frame(width: 40, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayCampaign.gameName)
                        .font(.system(size: 16, weight: .bold))

                    Text(displayCampaign.base.name)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
                
                if displayCampaign.hasClaimableDrops {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 14))
                }
            }
            .padding(16)

            Divider().opacity(0.1)

            // Drop List
            VStack(alignment: .leading, spacing: 12) {
                ForEach(displayCampaign.drops) { drop in
                    GameDropRow(drop: drop)
                }
            }
            .padding(16)
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
        let name = displayCampaign.gameName.lowercased()
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
                        Text(drop.base.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        HStack(spacing: 4) {
                            if drop.isFullyClaimed {
                                Text("Claimed by all")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.green)
                            } else if drop.isClaimableByAnyAccount {
                                Text("Ready to claim")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.orange)
                            } else {
                                // Multi-account summary
                                let claimed = drop.claimedCount
                                let total = drop.totalAccounts
                                if total > 0 {
                                    Text("\(claimed)/\(total) accounts claimed")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("\(drop.base.requiredMinutes) min required")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    Spacer()

                    // Multi-Account Progress Bar (Best)
                    if !drop.isFullyClaimed && drop.totalAccounts > 0 {
                        VStack(alignment: .trailing, spacing: 4) {
                            let percent = drop.bestProgressPercent
                            let remaining = Int(Double(drop.base.requiredMinutes) * (1.0 - percent/100.0))
                            
                            ProgressView(value: percent, total: 100)
                                .progressViewStyle(.linear)
                                .frame(width: 80)
                                .tint(drop.isClaimableByAnyAccount ? .orange : .blue)
                            
                            Text("\(Int(percent))% • \(remaining) min left")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    } else if drop.isFullyClaimed {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 14))
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
}

// MARK: - Account Progress Row

private struct AccountProgressRow: View {
    let state: DropState

    var body: some View {
        HStack(spacing: 10) {
            Text(state.accountId.prefix(8)) // Simplification for demo
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
