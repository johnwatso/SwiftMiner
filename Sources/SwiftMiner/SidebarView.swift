import SwiftUI
import SwiftMinerCore

/// Sidebar navigation for the multi-miner dashboard (Phase 6).
///
/// Sections:
///   Overview
///   Miners
///   Drops
///   Activity Log
struct SidebarView: View {
    @Environment(NavigationModel.self) private var navigation
    @ObservedObject private var settings = Settings.shared

    private var minerAttentionCount: Int {
        let blockedMinerIds = Set(
            navigation.minerManager.miners
                .filter { $0.status == .blockedAccountNotLinked || $0.status == .error || $0.needsAuth }
                .map(\.id)
        )
        let linkIssueMinerIds = Set(
            navigation.minerManager.miners
                .filter(hasVisiblePrioritisedLinkIssue)
                .map(\.id)
        )

        return blockedMinerIds.union(linkIssueMinerIds).count
    }

    private func hasVisiblePrioritisedLinkIssue(for miner: MinerManager.ManagedMiner) -> Bool {
        let priorityKeys = Set(
            settings.priorityGames
                .map(normalizedGameKey)
                .filter { !$0.isEmpty }
        )
        guard !priorityKeys.isEmpty else { return false }

        return miner.allCampaigns.contains { campaign in
            let gameId = warningGameId(for: campaign)
            guard campaign.isTimeActive,
                  campaign.status != .disabled,
                  campaign.activityStatus(for: miner) == .requiresLink,
                  campaign.drops.contains(where: { !$0.isClaimed }),
                  priorityKeys.contains(normalizedGameKey(campaign.game.name))
                    || priorityKeys.contains(normalizedGameKey(campaign.game.id)) else {
                return false
            }

            return !settings.isIgnoringAccountLinkWarnings(for: miner.accountId, gameId: gameId)
        }
    }

    private func warningGameId(for campaign: Campaign) -> String {
        let id = campaign.game.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty { return id }
        return normalizedGameKey(campaign.game.name)
    }

    private func normalizedGameKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var sidebarItems: [GlassSelectionItem<NavigationModel.SidebarItem>] {
        var items: [GlassSelectionItem<NavigationModel.SidebarItem>] = [
            GlassSelectionItem(id: .overview, title: "Overview", systemImage: "waveform.path.ecg"),
            GlassSelectionItem(id: .miners, title: "Miners", systemImage: "cpu"),
            GlassSelectionItem(id: .drops, title: "Drops", systemImage: "gamecontroller.fill"),
            GlassSelectionItem(id: .events, title: "Activity Log", systemImage: "list.bullet.rectangle.fill"),
        ]
        if settings.swiftBotEnabled {
            items.append(GlassSelectionItem(id: .admin, title: "Admin Beta", systemImage: "lock.shield.fill"))
        }
        return items
    }

    private var selectionBinding: Binding<NavigationModel.SidebarItem> {
        Binding(
            get: { navigation.selectedItem ?? .overview },
            set: { navigation.selectedItem = $0 }
        )
    }

    var body: some View {
        ZStack {
            SidebarMaterialBackground()

            VStack(alignment: .leading, spacing: 0) {
                GlassSelectionControl(
                    items: sidebarItems,
                    selection: selectionBinding,
                    axis: .vertical,
                    itemSpacing: 2,
                    padding: 0,
                    contentInsets: EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10),
                    selectedCornerRadius: 11,
                    fillsAvailableSpace: true,
                    showsContainer: false
                ) { item, isSelected in
                    HStack(spacing: 12) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 18)

                        Text(item.title)
                            .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        if item.id == .miners && minerAttentionCount > 0 {
                            Text("\(minerAttentionCount)")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange, in: Capsule())
                        }
                    }
                    .foregroundStyle(.primary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
        }
        .navigationTitle("SwiftMiner")
        .onChange(of: settings.swiftBotEnabled) { _, enabled in
            if !enabled && navigation.selectedItem == .admin {
                navigation.selectedItem = .overview
            }
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationSplitView {
        SidebarView()
    } content: {
        Text("Content")
    } detail: {
        Text("Detail")
    }
    .environment(NavigationModel(clientId: "preview"))
}
