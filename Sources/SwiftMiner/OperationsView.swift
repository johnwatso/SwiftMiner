import SwiftUI
import SwiftMinerCore

struct OperationsView: View {
    @Environment(NavigationModel.self) private var navigation
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var rewardsLedger = RewardsLedgerStore.shared
    @State private var selectedMinerId: String?
    @State private var activitySummaries: [String: MinerManager.MinerActivitySummary] = [:]

    private var miners: [MinerManager.ManagedMiner] {
        navigation.minerManager.miners
    }

    private var selectedMiner: MinerManager.ManagedMiner? {
        if let selectedMinerId,
           let miner = miners.first(where: { $0.id == selectedMinerId }) {
            return miner
        }
        return miners.first
    }

    private var healthSnapshots: [MinerHealthSnapshot] {
        miners.map { MinerHealthSnapshot.make(miner: $0) }
    }

    private var forecasts: [CampaignDeadlineForecast] {
        miners.flatMap { miner in
            miner.allCampaigns
                .filter { !$0.isFullyComplete && ($0.isTimeActive || $0.endDate > Date()) }
                .map { CampaignDeadlineForecast.make(minerId: miner.id, campaign: $0) }
        }
        .sorted {
            if $0.outcome.sortRank != $1.outcome.sortRank {
                return $0.outcome.sortRank < $1.outcome.sortRank
            }
            return $0.minutesUntilDeadline < $1.minutesUntilDeadline
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                healthSection
                forecastSection
                timelineSection
                rewardsSection
            }
            .padding(24)
        }
        .navigationTitle("Operations")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .task { await refresh() }
        .onChange(of: miners.map(\.id)) { _, ids in
            if selectedMinerId == nil || !ids.contains(selectedMinerId ?? "") {
                selectedMinerId = ids.first
            }
            Task { await refresh() }
        }
    }

    private var healthSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Global Health")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                healthMetric("Mining", count: count(.mining), systemImage: "play.circle.fill", tint: .green)
                healthMetric("Blocked", count: count(.blocked), systemImage: "exclamationmark.triangle.fill", tint: .orange)
                healthMetric("Needs Auth", count: count(.needsAuth), systemImage: "person.crop.circle.badge.exclamationmark", tint: .red)
                healthMetric("Stalled", count: count(.stalled), systemImage: "waveform.path.ecg.rectangle", tint: .red)
                healthMetric("Recovering", count: count(.recovering), systemImage: "arrow.triangle.2.circlepath", tint: .blue)
                healthMetric("Idle", count: count(.idle), systemImage: "pause.circle", tint: .secondary)
            }
        }
    }

    private var forecastSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Deadline Forecast")
            if forecasts.isEmpty {
                emptyLine("No active campaign forecasts yet.")
            } else {
                VStack(spacing: 8) {
                    ForEach(forecasts.prefix(8)) { forecast in
                        forecastRow(forecast)
                    }
                }
            }
        }
    }

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeader("Miner Diagnostics")
                Spacer()
                if miners.count > 1 {
                    Picker("Miner", selection: minerSelectionBinding) {
                        ForEach(miners) { miner in
                            Text(miner.displayName).tag(Optional(miner.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 180)
                }
            }

            if let miner = selectedMiner {
                let snapshot = MinerHealthSnapshot.make(miner: miner)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(snapshot.statusLabel, systemImage: snapshot.health.systemImage)
                            .font(.headline)
                            .foregroundStyle(snapshot.health.tint)
                        Spacer()
                        Text("Stall confidence \(snapshot.stallConfidencePercent)%")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(snapshot.stallConfidencePercent), total: 100)
                        .tint(snapshot.health.tint)

                    if snapshot.stallSignals.isEmpty {
                        Text("Recent poll, event and worker signals look normal.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(snapshot.stallSignals, id: \.self) { signal in
                            Label(signal, systemImage: "smallcircle.filled.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    diagnosticTimeline(for: miner)
                }
                .operationPanel()
            } else {
                emptyLine("Add an account to see miner diagnostics.")
            }
        }
    }

    private var rewardsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeader("Rewards Ledger")
                Spacer()
                if !rewardsLedger.entries.isEmpty {
                    Button("Clear", role: .destructive) {
                        rewardsLedger.clear()
                    }
                    .buttonStyle(.borderless)
                }
            }

            if rewardsLedger.entries.isEmpty {
                emptyLine("Claimed drops will appear here with account and campaign context.")
            } else {
                VStack(spacing: 8) {
                    ForEach(rewardsLedger.entries.prefix(10)) { entry in
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.dropName)
                                    .font(.subheadline.weight(.semibold))
                                Text(rewardSubtitle(entry))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(entry.claimedAt, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .operationPanel()
                    }
                }
            }
        }
    }

    private func diagnosticTimeline(for miner: MinerManager.ManagedMiner) -> some View {
        let summary = activitySummaries[miner.id]
        let engineEvents = summary?.recentEvents ?? []
        let logEvents = navigation.events.filter { $0.minerId == miner.id }.prefix(5)

        return VStack(alignment: .leading, spacing: 8) {
            Text("Recovery Timeline")
                .font(.subheadline.weight(.semibold))

            if engineEvents.isEmpty && logEvents.isEmpty {
                Text("No recent diagnostic events for this miner.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(engineEvents.indices, id: \.self) { index in
                    let event = engineEvents[index]
                    timelineRow(title: event.summary, detail: event.type.rawValue, date: event.timestamp)
                }
                ForEach(Array(logEvents)) { event in
                    timelineRow(title: event.message, detail: event.level.rawValue.capitalized, date: event.timestamp)
                }
            }
        }
        .padding(.top, 4)
    }

    private func forecastRow(_ forecast: CampaignDeadlineForecast) -> some View {
        HStack(spacing: 10) {
            Image(systemName: forecast.outcome.systemImage)
                .foregroundStyle(forecast.outcome.tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text("\(forecast.gameName) · \(forecast.campaignName)")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(forecast.minutesRemainingToEarn)m left to earn · \(forecast.minutesUntilDeadline)m until deadline · \(forecast.reason)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Text("\(Int(forecast.progressPercent.rounded()))%")
                .font(.caption.weight(.bold))
                .foregroundStyle(forecast.outcome.tint)
        }
        .operationPanel()
    }

    private func healthMetric(_ title: String, count: Int, systemImage: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text("\(count)")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .operationPanel()
    }

    private func timelineRow(title: String, detail: String, date: Date) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 6, height: 6)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.medium))
                Text("\(detail) · \(date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .operationPanel()
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.title3.weight(.semibold))
    }

    private func rewardSubtitle(_ entry: RewardsLedgerStore.Entry) -> String {
        [entry.campaignName, entry.gameName, entry.accountName]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " · ")
    }

    private func count(_ health: MinerHealthSnapshot.Health) -> Int {
        healthSnapshots.filter { $0.health == health }.count
    }

    private var minerSelectionBinding: Binding<String?> {
        Binding {
            selectedMiner?.id
        } set: { selectedMinerId = $0 }
    }

    private func refresh() async {
        if selectedMinerId == nil {
            selectedMinerId = miners.first?.id
        }
        var next: [String: MinerManager.MinerActivitySummary] = [:]
        for miner in miners {
            if let summary = await navigation.minerManager.getMinerActivitySummary(minerId: miner.id) {
                next[miner.id] = summary
            }
        }
        activitySummaries = next
    }
}

private extension View {
    func operationPanel() -> some View {
        self
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
            )
    }
}

private extension CampaignDeadlineForecast.Outcome {
    var sortRank: Int {
        switch self {
        case .missed: return 0
        case .blocked: return 1
        case .atRisk: return 2
        case .unknown: return 3
        case .onTrack: return 4
        case .complete: return 5
        }
    }

    var systemImage: String {
        switch self {
        case .onTrack: return "checkmark.circle.fill"
        case .atRisk: return "clock.badge.exclamationmark.fill"
        case .missed: return "xmark.octagon.fill"
        case .complete: return "checkmark.seal.fill"
        case .blocked: return "lock.trianglebadge.exclamationmark.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .onTrack, .complete: return .green
        case .atRisk, .unknown: return .orange
        case .missed, .blocked: return .red
        }
    }
}

private extension MinerHealthSnapshot.Health {
    var systemImage: String {
        switch self {
        case .mining: return "play.circle.fill"
        case .blocked: return "exclamationmark.triangle.fill"
        case .needsAuth: return "person.crop.circle.badge.exclamationmark"
        case .stalled: return "waveform.path.ecg.rectangle"
        case .recovering: return "arrow.triangle.2.circlepath"
        case .idle: return "pause.circle"
        case .attention: return "exclamationmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .mining: return .green
        case .recovering: return .blue
        case .blocked, .needsAuth, .stalled, .attention: return .orange
        case .idle: return .secondary
        }
    }
}
