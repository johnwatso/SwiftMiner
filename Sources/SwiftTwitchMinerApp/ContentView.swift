import SwiftUI
import SwiftTwitchMiner

/// Root view — 2-column NavigationSplitView (Sidebar | Detail)
struct ContentView: View {
    @State private var navigation = NavigationModel(
        clientId: Settings.shared.resolvedClientId
    )

    var body: some View {
        @Bindable var nav = navigation
        NavigationSplitView {
            SidebarView()
        } detail: {
            detailView
        }
        .frame(minWidth: 800, minHeight: 600)
        .environment(navigation)
        .sheet(isPresented: $nav.showAddAccountSheet) {
            AuthRequiredSheet(isPresented: $nav.showAddAccountSheet)
                .environment(navigation)
        }
        .task {
            navigation.setup()
        }
    }

    // MARK: - Detail View

    @ViewBuilder
    private var detailView: some View {
        switch navigation.selectedItem {
        case .activity, .accounts, .none:
            ActivityOverviewView()

        case .account(let id):
            if let miner = navigation.minerManager.getMiner(id: id) {
                AccountDetailView(miner: miner)
            } else {
                ContentUnavailableView(
                    "Account Not Found",
                    systemImage: "person.slash",
                    description: Text("The selected account could not be found.")
                )
            }

        case .campaigns:
            DropsListView()

        case .campaign(let id):
            DropsListView()
                .onAppear { navigation.selectedCampaignId = id }

        case .logs:
            AggregatedLogConsoleView()

        case .settings:
            SettingsView()
        }
    }
}

// MARK: - Aggregated Log Console

/// System-wide log console aggregating messages from all miners.
struct AggregatedLogConsoleView: View {
    @Environment(NavigationModel.self) private var navigation
    @State private var autoScroll = true

    private var allEntries: [LogEntry] {
        navigation.minerLogs.values
            .flatMap { $0 }
            .sorted { $0.timestamp < $1.timestamp }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("System Logs")
                    .font(.headline)
                Spacer()
                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Button {
                    navigation.minerLogs.removeAll()
                } label: {
                    Text("Clear All")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            let entries = allEntries
            if entries.isEmpty {
                ContentUnavailableView(
                    "No Log Entries",
                    systemImage: "text.alignleft",
                    description: Text("Start miners to see activity here.")
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(entries) { entry in
                                MinerLogRow(entry: entry)
                                    .id(entry.id)
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: entries.count) { _, _ in
                        if autoScroll, let last = entries.last {
                            withAnimation(.easeOut(duration: 0.1)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Logs")
    }
}

// MARK: - Shared log row (used by AggregatedLogConsoleView + MinerLogConsole)

struct MinerLogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(entry.timestamp.formatted(.dateTime.hour().minute().second()))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .leading)

            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(textColor)
                .textSelection(.enabled)
        }
    }

    private var textColor: Color {
        switch entry.level {
        case .error:   return .red
        case .warning: return .orange
        case .info:    return .primary
        case .debug:   return .secondary
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}
