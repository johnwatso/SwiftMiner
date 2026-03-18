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

    var body: some View {
        @Bindable var nav = navigation
        List(selection: $nav.selectedItem) {
            Label("Overview", systemImage: "house.fill")
                .tag(NavigationModel.SidebarItem.overview)

            Label("Activity", systemImage: "chart.bar.fill")
                .tag(NavigationModel.SidebarItem.activity)

            Label("Drops", systemImage: "gamecontroller.fill")
                .tag(NavigationModel.SidebarItem.drops)

            Label("Events", systemImage: "bell.fill")
                .tag(NavigationModel.SidebarItem.events)
        }
        .listStyle(.sidebar)
        .navigationTitle("Miner")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    nav.showAddAccountSheet = true
                } label: {
                    Image(systemName: "person.badge.plus")
                }
                .help("Add Account")

                let hasStopped = navigation.minerManager.miners.contains { !$0.isRunning }
                if hasStopped {
                    Button {
                        Task { await navigation.minerManager.startAll() }
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .help("Start All Miners")
                }

                let hasRunning = navigation.minerManager.miners.contains { $0.isRunning }
                if hasRunning {
                    Button {
                        Task { await navigation.minerManager.stopAll() }
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .help("Stop All Miners")
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
