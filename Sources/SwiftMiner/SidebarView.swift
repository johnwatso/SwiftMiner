import SwiftUI
import SwiftTwitchMiner

/// Sidebar navigation for the multi-miner dashboard (Phase 6).
///
/// Sections:
///   Overview
///   Activity
///   Drops
///   Events
struct SidebarView: View {
    @Environment(NavigationModel.self) private var navigation

    private var sidebarItems: [GlassSelectionItem<NavigationModel.SidebarItem>] {
        [
            GlassSelectionItem(id: .overview, title: "Overview", systemImage: "house.fill"),
            GlassSelectionItem(id: .activity, title: "Activity", systemImage: "chart.bar.fill"),
            GlassSelectionItem(id: .drops, title: "Drops", systemImage: "gamecontroller.fill"),
            GlassSelectionItem(id: .events, title: "Events", systemImage: "bell.fill")
        ]
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
                    showsContainer: false,
                    selectionOpacity: 0.20
                ) { item, isSelected in
                    HStack(spacing: 12) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 18)

                        Text(item.title)
                            .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                    }
                    .foregroundStyle(.primary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
        }
        .navigationTitle("SwiftMiner")
        .toolbar {
            ToolbarItemGroup {
                let hasStopped = navigation.minerManager.miners.contains { !$0.isRunning }
                if hasStopped {
                    Button {
                        Task {
                            let settings = Settings.shared
                            await navigation.minerManager.startAll(
                                priorityGames: settings.priorityGames,
                                excludedGames: settings.excludedGames,
                                strategy: settings.miningStrategy,
                                enableBadgesEmotes: settings.enableBadgesEmotes,
                                showClaimNotifications: settings.showClaimNotifications
                            )                        }
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .help("Start All Miners")
                }
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
