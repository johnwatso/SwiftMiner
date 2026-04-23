import SwiftUI
import SwiftMinerCore

/// Detailed event log view for monitoring system and miner activity.
struct EventLogView: View {
    @Environment(NavigationModel.self) private var navigation
    @State private var showRawLogs = false
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
        VStack(spacing: 0) {
            headerSection
            
            if filteredEvents.isEmpty {
                emptyState
            } else {
                eventList
            }
        }
        .navigationTitle("Events")
        .toolbar {
            ToolbarItemGroup {
                Picker("Level", selection: $levelFilter) {
                    Text("All Levels").tag(nil as EventLevel?)
                    Text("Info").tag(EventLevel.info as EventLevel?)
                    Text("Warning").tag(EventLevel.warning as EventLevel?)
                    Text("Error").tag(EventLevel.error as EventLevel?)
                }
                .pickerStyle(.menu)

                Toggle(isOn: $showRawLogs) {
                    Label("Raw Logs", systemImage: "text.alignleft")
                }
            }

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

    private var headerSection: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search events...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassControlSurface()

            Spacer()
        }
        .padding(24)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "list.bullet.rectangle.portrait")
                .font(.system(size: 44))
                .foregroundStyle(.secondary.opacity(0.5))
            
            Text(searchText.isEmpty ? "No events recorded" : "No results for '\(searchText)'")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var eventList: some View {
        List(filteredEvents) { event in
            MinerEventRow(event: event, showRaw: showRawLogs)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

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

    /// Looks up the miner username from the minerId, fallback to shortened ID
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
