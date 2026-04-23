import SwiftUI
import SwiftMinerCore

/// Dense, flat event log focused on chronological scanning.
struct EventLogView: View {
    @Environment(NavigationModel.self) private var navigation
    @State private var filter: LogFilter = .all

    private var visibleEvents: [EventEntry] {
        switch filter {
        case .all:
            return navigation.events
        case .info:
            return navigation.events.filter { $0.level == .info }
        case .warnings:
            return navigation.events.filter { $0.level == .warning }
        case .errors:
            return navigation.events.filter { $0.level == .error }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if visibleEvents.isEmpty {
                emptyState
            } else {
                List(visibleEvents) { event in
                    EventLogRow(event: event)
                        .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
                        .listRowSeparator(.visible, edges: .bottom)
                        .listRowSeparatorTint(.secondary.opacity(0.14))
                        .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Events")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 16) {
                    Picker("Filter", selection: $filter) {
                        ForEach(LogFilter.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()

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
    }

    private var emptyState: some View {
        HStack {
            Text("No \(filter.emptyLabel)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }
}

private enum LogFilter: String, CaseIterable, Identifiable {
    case all
    case info
    case warnings
    case errors

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .info: return "Info"
        case .warnings: return "Warnings"
        case .errors: return "Errors"
        }
    }

    var emptyLabel: String {
        switch self {
        case .all: return "events"
        case .info: return "info events"
        case .warnings: return "warnings"
        case .errors: return "errors"
        }
    }
}

private struct EventLogRow: View {
    let event: EventEntry
    @Environment(NavigationModel.self) private var navigation

    private var levelColor: Color {
        switch event.level {
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }

    private var messageText: String {
        if let raw = event.rawMessage,
           let campaignSummary = campaignStatusSummary(from: raw) {
            return campaignSummary
        }
        return simplifyMessage(event.message)
    }

    private var metadataText: String? {
        guard let minerId = event.minerId else { return nil }
        if let miner = navigation.minerManager.miners.first(where: { $0.id == minerId }) {
            return miner.username
        }
        return "Miner \(minerId.prefix(4))"
    }

    private var relativeTime: String {
        relativeDateFormatter.localizedString(for: event.timestamp, relativeTo: Date())
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(levelColor)
                .frame(width: 7, height: 7)

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
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, metadataText == nil ? 1 : 2)
    }
}

// MARK: - Message Formatting

private func simplifyMessage(_ message: String) -> String {
    var text = message
        .replacingOccurrences(of: #"\[[^\]]+\]\s*"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"^Miner\s+[A-Za-z0-9_-]+:\s*"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"^\s*[•·]\s*"#, with: "", options: .regularExpression)

    for marker in ["⚠️", "❌", "✅", "🔄"] {
        text = text.replacingOccurrences(of: marker, with: "")
    }

    if let campaignSummary = campaignStatusSummary(from: text) {
        return campaignSummary
    }

    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func campaignStatusSummary(from text: String) -> String? {
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
    return "\(gameName) — \(humanStatus(status))"
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

@MainActor private let relativeDateFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
}()

// MARK: - Legacy row (used by MinerDetailView)

struct MinerEventRow: View {
    let event: EventEntry
    let showRaw: Bool
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 10) {
                Circle()
                    .fill(levelColor)
                    .frame(width: 7, height: 7)

                Text(showRaw ? (event.rawMessage ?? event.message) : event.message)
                    .font(.system(size: 12))
                    .lineLimit(1)

                Spacer(minLength: 12)

                Text(event.timestamp.formatted(.dateTime.hour().minute().second()))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            if let minerId = event.minerId {
                Text(minerName(for: minerId))
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
        switch event.level {
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func minerName(for minerId: String) -> String {
        navigation.minerManager.miners.first(where: { $0.id == minerId }).map(\.username)
            ?? "Miner \(minerId.prefix(4))"
    }
}

#Preview {
    EventLogView()
        .environment(NavigationModel(clientId: "preview"))
}
