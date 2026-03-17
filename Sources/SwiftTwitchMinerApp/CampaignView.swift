import SwiftUI
import SwiftTwitchMiner

// MARK: - Campaigns List (Content Panel)

/// Aggregated view of active campaigns across all miners.
///
/// Since MinerManager tracks current campaign names (not full Campaign objects),
/// this view groups miners by their current campaign and shows a per-campaign breakdown.
// MARK: - Game-Centric Models

/// Progress of a specific drop for a specific miner
struct MinerDropProgress: Identifiable, Sendable {
    var id: String { minerId }
    let minerId: String
    let username: String
    let watchedMinutes: Int
    let isClaimed: Bool
}

/// Represents a group of campaigns/drops for a single game
struct GameGroup: Identifiable {
    let id: String // game ID
    let gameName: String
    let boxArtURL: URL?
    var drops: [GameDrop]
    
    var isClaimable: Bool { drops.contains { $0.isClaimable } }
    var isAvailable: Bool { !isClaimable && drops.contains { !$0.isClaimed && !$0.isLocked } }
}

/// A flattened drop model for the UI supporting multiple miners
struct GameDrop: Identifiable {
    let id: String
    let name: String
    let imageURL: URL?
    let requiredMinutes: Int
    let progresses: [MinerDropProgress]
    
    // Aggregation Logic
    var displayMinutesWatched: Int { progresses.map(\.watchedMinutes).max() ?? 0 }
    
    var minerCountActive: Int {
        progresses.filter { $0.watchedMinutes > 0 }.count
    }
    
    var minerCountComplete: Int {
        progresses.filter { $0.isClaimed || $0.watchedMinutes >= requiredMinutes }.count
    }
    
    var isClaimed: Bool {
        !progresses.isEmpty && progresses.allSatisfy { $0.isClaimed }
    }
    
    var isClaimable: Bool {
        progresses.contains { $0.watchedMinutes >= requiredMinutes && !$0.isClaimed }
    }
    
    var isLocked: Bool {
        // A drop is locked if ALL miners find it locked (no miner can progress it)
        // In practice, since miners share the same campaign sequence, we'll check our derived logic
        // but for aggregation we'll consider it locked if no progress has been made and it's not the current one.
        // The detailed isLocked check is handled during aggregation in allGroups.
        _isLocked
    }
    
    private let _isLocked: Bool
    
    init(id: String, name: String, imageURL: URL?, requiredMinutes: Int, progresses: [MinerDropProgress], isLocked: Bool) {
        self.id = id
        self.name = name
        self.imageURL = imageURL
        self.requiredMinutes = requiredMinutes
        self.progresses = progresses.sorted { $0.watchedMinutes > $1.watchedMinutes }
        self._isLocked = isLocked
    }
}
struct DropsListView: View {
    @Environment(NavigationModel.self) private var navigation
    @State private var filter: CampaignFilter = .claimable

    enum CampaignFilter: String, CaseIterable, Identifiable {
        case claimable = "Claimable"
        case available = "Available"
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
                            GameGroupCard(group: group)
                        }
                    }
                    .padding()
                }
            }
        }
...
    private var emptyDropsView: some View {
...

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
                    ForEach(CampaignFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }
        }
    }

    /// Aggregated game groups from all miners
    private var allGroups: [GameGroup] {
        let miners = navigation.minerManager.miners
        
        // 1. Map games to their metadata
        var gameMetadata: [String: (name: String, art: URL?)] = [:]
        for miner in miners {
            for campaign in miner.allCampaigns {
                gameMetadata[campaign.game.id] = (campaign.game.name, campaign.game.boxArtURL)
            }
        }
        
        // 2. Build GameGroups
        var groups: [GameGroup] = []
        for (gameId, meta) in gameMetadata {
            // dropId -> aggregated data
            var dropCollection: [String: (name: String, image: URL?, req: Int, progresses: [MinerDropProgress], isLocked: Bool)] = [:]
            
            for miner in miners {
                let campaigns = miner.allCampaigns.filter { $0.game.id == gameId }
                for campaign in campaigns {
                    for (idx, drop) in campaign.drops.enumerated() {
                        var entry = dropCollection[drop.id] ?? (drop.name, drop.imageURL, drop.requiredMinutes, [], true)
                        
                        let progress = MinerDropProgress(
                            minerId: miner.id,
                            username: miner.username,
                            watchedMinutes: drop.progress?.currentMinutes ?? 0,
                            isClaimed: drop.isClaimed
                        )
                        entry.progresses.append(progress)
                        
                        // A drop is globally locked ONLY if every miner finds it locked
                        let minerLocked = idx > 0 && !campaign.drops[..<idx].allSatisfy { $0.isClaimed }
                        entry.isLocked = entry.isLocked && minerLocked
                        
                        dropCollection[drop.id] = entry
                    }
                }
            }
            
            let gameDrops = dropCollection.map { id, data in
                GameDrop(
                    id: id,
                    name: data.name,
                    imageURL: data.image,
                    requiredMinutes: data.req,
                    progresses: data.progresses,
                    isLocked: data.isLocked
                )
            }.sorted { a, b in
                // Sort Priority: 1. Claimable, 2. In Progress, 3. Not Started
                if a.isClaimable != b.isClaimable { return a.isClaimable }
                if a.isClaimed != b.isClaimed { return !a.isClaimed }
                
                let aInProgress = a.displayMinutesWatched > 0 && a.displayMinutesWatched < a.requiredMinutes
                let bInProgress = b.displayMinutesWatched > 0 && b.displayMinutesWatched < b.requiredMinutes
                if aInProgress != bInProgress { return aInProgress }
                
                return a.displayMinutesWatched > b.displayMinutesWatched
            }
            
            groups.append(GameGroup(
                id: gameId,
                gameName: meta.name,
                boxArtURL: meta.art,
                drops: gameDrops
            ))
        }
        
        return groups.sorted { $0.gameName < $1.gameName }
    }

    /// Filtered groups
    private var displayGroups: [GameGroup] {
        switch filter {
        case .claimable:
            return allGroups.filter { $0.isClaimable || $0.drops.contains { $0.watchedMinutes > 0 && !$0.isClaimed } }
        case .available:
            return allGroups.filter { $0.isAvailable }
        case .all:
            return allGroups
        }
    }

    private var emptyCampaignsView: some View {
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
        case .claimable: return "No Claimable Drops"
        case .available: return "No Available Campaigns"
        case .all: return "No Campaigns Found"
        }
    }

    private var emptySubtitle: String {
        if navigation.minerManager.miners.isEmpty {
            return "Add an account and start mining to see campaigns here."
        }
        switch filter {
        case .claimable: return "Drops you've started earning will appear here."
        case .available: return "Connect your game accounts on Twitch to see eligible campaigns."
        case .all: return "Start a miner to begin fetching campaigns from Twitch."
        }
    }
}

// MARK: - Game Group Card (Liquid Glass)

private struct GameGroupCard: View {
    let group: GameGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
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
                    Text(group.gameName)
                        .font(.system(size: 16, weight: .bold))
                    
                    let activeCount = group.drops.filter { !$0.isClaimed && !$0.isLocked }.count
                    if activeCount > 0 {
                        Text("\(activeCount) active drops")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
                
                if group.isClaimable {
                    Image(systemName: "gift.fill")
                        .foregroundStyle(.green)
                        .font(.title3)
                }
            }
            .padding(16)
            
            Divider()
                .opacity(0.1)
            
            // Drop List
            VStack(alignment: .leading, spacing: 12) {
                ForEach(group.drops) { drop in
                    GameDropRow(drop: drop)
                }
            }
            .padding(16)
        }
        .background(.ultraThinMaterial)
        .background(tintColor.opacity(0.08)) // Subtle tint from game art
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.primary.opacity(0.05), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.03), radius: 5, x: 0, y: 2)
    }
    
    /// Maps game name to a fallback tint color (simplification of art-based tinting)
    private var tintColor: Color {
        let name = group.gameName.lowercased()
        if name.contains("finals") { return .pink }
        if name.contains("rust") { return .orange }
        if name.contains("raiders") { return .teal }
        if name.contains("genshin") { return .blue }
        if name.contains("halo") { return .indigo }
        return .purple
    }
}

// MARK: - Game Drop Row

private struct GameDropRow: View {
    let drop: GameDrop
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    // Drop Thumbnail
                    if let url = drop.imageURL {
                        AsyncImage(url: url) { image in
                            image.resizable().aspectRatio(contentMode: .fit)
                        } placeholder: {
                            Color.secondary.opacity(0.1)
                        }
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Color.secondary.opacity(0.1)
                            .frame(width: 32, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(drop.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        
                        HStack(spacing: 4) {
                            if drop.isClaimed {
                                Text("Claimed")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.green)
                            } else if drop.isLocked {
                                Text("Locked")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("\(drop.displayMinutesWatched) / \(drop.requiredMinutes) min")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                
                                if drop.isClaimable {
                                    Text("• Ready")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                    
                    Spacer()
                    
                    // Miner Indicators (subtle dots)
                    if drop.minerCountActive > 0 {
                        HStack(spacing: 3) {
                            ForEach(0..<drop.minerCountActive, id: \.self) { _ in
                                Circle()
                                    .fill(Color.secondary.opacity(0.4))
                                    .frame(width: 4, height: 4)
                            }
                        }
                        .padding(.trailing, 4)
                    }
                    
                    if !drop.isClaimed && !drop.isLocked {
                        ZStack {
                            Circle()
                                .stroke(Color.secondary.opacity(0.1), lineWidth: 2.5)
                            Circle()
                                .trim(from: 0, to: CGFloat(Double(drop.displayMinutesWatched) / Double(drop.requiredMinutes)))
                                .stroke(drop.isClaimable ? Color.orange : Color.blue, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        .frame(width: 16, height: 16)
                    } else if drop.isClaimed {
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
            
            if isExpanded {
                VStack(spacing: 8) {
                    ForEach(drop.progresses) { progress in
                        MinerProgressRow(progress: progress, requiredMinutes: drop.requiredMinutes)
                    }
                }
                .padding(.leading, 44)
                .padding(.bottom, 4)
                .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))
            }
        }
    }
}

// MARK: - Miner Progress Row (Detail)

private struct MinerProgressRow: View {
    let progress: MinerDropProgress
    let requiredMinutes: Int
    
    var body: some View {
        HStack(spacing: 10) {
            Text(progress.username)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            
            // Text-based progress bar representation
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.1))
                    
                    RoundedRectangle(cornerRadius: 2)
                        .fill(progress.isClaimed ? Color.green : Color.blue.opacity(0.8))
                        .frame(width: geo.size.width * CGFloat(Double(progress.watchedMinutes) / Double(requiredMinutes)))
                }
            }
            .frame(height: 6)
            
            HStack(spacing: 4) {
                Text("\(progress.watchedMinutes)/\(requiredMinutes)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                
                if progress.isClaimed {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.green)
                }
            }
            .frame(width: 60, alignment: .trailing)
        }
    }
}

// MARK: - Preview

#Preview("Drops List") {
    CampaignsListView()
        .environment(NavigationModel(clientId: "preview"))
        .frame(width: 600, height: 500)
}
