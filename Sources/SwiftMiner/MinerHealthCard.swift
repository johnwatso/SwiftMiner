import SwiftUI
import SwiftMinerCore

/// At-a-glance health summary card for all miners.
/// Shows "All miners healthy" when everything is fine, or a concise list of issues.
/// Designed to sit at the top of the Overview dashboard.
struct MinerHealthCard: View {
    let miners: [MinerManager.ManagedMiner]
    var onSelectMiner: ((String) -> Void)?
    private var settings: Settings { .shared }
    @EnvironmentObject private var unattendedHealth: UnattendedHealthModel

    /// Refreshes time-dependent verdicts (e.g. "stuck for X min") every 30 seconds.
    @State private var now = Date()

    // MARK: - Health Verdict

    enum Severity { case ok, warning, error }

    struct HealthVerdict {
        let severity: Severity
        let message: String
    }

    private func verdict(for miner: MinerManager.ManagedMiner) -> HealthVerdict {
        if let blockedGame = blockedPriorityGameRequiringLink(for: miner) {
            return HealthVerdict(severity: .warning, message: "Link required for \(blockedGame) drops")
        }
        if miner.workerState.isRecovering {
            return HealthVerdict(severity: .warning, message: "Recovering...")
        }
        if miner.isStalled {
            return HealthVerdict(severity: .error, message: "Miner unresponsive")
        }
        if miner.showsNoRecentActivityAttention {
            return HealthVerdict(severity: .warning, message: "No recent activity")
        }
        if miner.needsAuth {
            return HealthVerdict(severity: .error, message: "Re-authentication required")
        }
        if miner.status == .error {
            return HealthVerdict(severity: .error, message: "Error — check activity log")
        }
        if miner.status == .fetchingCampaigns {
            let elapsed = now.timeIntervalSince(miner.statusChangedAt)
            if elapsed > 60 {
                let mins = max(1, Int(elapsed / 60))
                return HealthVerdict(severity: .warning, message: "Campaign fetch is taking \(mins) min")
            }
        }
        return HealthVerdict(severity: .ok, message: miner.statusLabel)
    }

    private func blockedPriorityGameRequiringLink(for miner: MinerManager.ManagedMiner) -> String? {
        guard miner.isRunning else { return nil }

        let priorityGames = Set(
            settings.priorityGames
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        guard !priorityGames.isEmpty else { return nil }

        return miner.allCampaigns.first { campaign in
            guard campaign.isTimeActive
                && !campaign.isAccountConnected
                && priorityGames.contains(campaign.gameName.lowercased())
                && campaign.drops.contains(where: { !$0.isClaimed }) else {
                return false
            }

            // Respect game-scoped suppression
            return !settings.isIgnoringAccountLinkWarnings(for: miner.accountId, gameId: campaign.game.id)
        }?.gameName
    }

    private var issueMiners: [(miner: MinerManager.ManagedMiner, verdict: HealthVerdict)] {
        miners.compactMap { miner in
            let v = verdict(for: miner)
            return v.severity == .ok ? nil : (miner, v)
        }
    }

    private var allHealthy: Bool { issueMiners.isEmpty }

    private var anyRunning: Bool { miners.contains { $0.isRunning } }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if allHealthy {
                if anyRunning {
                    healthyRow
                } else {
                    standbyRow
                }
            } else {
                issuesContent
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous))
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    // MARK: - Healthy State

    private var healthyRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AnimatedStatusIcon(symbol: "checkmark.circle.fill", color: .green, size: 17, weight: .semibold)
                Text(healthyStatusText)
                    .font(.subheadline.weight(.medium))
                Spacer()
            }

            if hasPersistedHealthDetails {
                Divider()
                    .opacity(0.55)

                HStack(spacing: 16) {
                    if let progressAt = unattendedHealth.summary.lastMiningProgressAt {
                        healthDetail("Progress", date: progressAt, symbol: "chart.line.uptrend.xyaxis")
                    }
                    if let responseAt = unattendedHealth.summary.lastTwitchResponseAt {
                        healthDetail("Twitch", date: responseAt, symbol: "network")
                    }
                    if let recovery = unattendedHealth.summary.lastRecovery {
                        healthDetail(
                            recovery.succeeded == true ? "Recovery succeeded" : "Last recovery",
                            date: recovery.finishedAt ?? recovery.startedAt,
                            symbol: SystemSymbolCompatibility.resolvedName(
                                for: recovery.succeeded == true
                                    ? "checkmark.arrow.trianglehead.counterclockwise"
                                    : "arrow.trianglehead.2.clockwise"
                            )
                        )
                    }
                    Spacer()
                }
            }
        }
    }

    private var healthyStatusText: String {
        let base = miners.count == 1
            ? "Miner is running normally"
            : "All \(miners.count) miners are running normally"
        guard let since = unattendedHealth.summary.operatingNormallySince else {
            return base
        }
        return "\(base) for \(durationDescription(since: since))"
    }

    private var hasPersistedHealthDetails: Bool {
        unattendedHealth.summary.lastMiningProgressAt != nil
            || unattendedHealth.summary.lastTwitchResponseAt != nil
            || unattendedHealth.summary.lastRecovery != nil
    }

    private func healthDetail(_ title: String, date: Date, symbol: String) -> some View {
        Label {
            Text("\(title) \(date.formatted(.relative(presentation: .numeric)))")
        } icon: {
            Image(systemName: symbol)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func durationDescription(since date: Date) -> String {
        let duration = max(0, now.timeIntervalSince(date))
        if duration < 60 {
            return "less than a minute"
        }
        if duration < 3600 {
            let minutes = Int(duration / 60)
            return "\(minutes) min"
        }
        if duration < 86_400 {
            let hours = Int(duration / 3600)
            return "\(hours) hr"
        }
        let days = Int(duration / 86_400)
        return "\(days) day\(days == 1 ? "" : "s")"
    }

    private var standbyRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.badge.checkmark")
                .foregroundStyle(.secondary)
                .font(.body.weight(.semibold))
            Text(miners.count == 1 ? "Miner is standing by" : "All miners are standing by")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Issues State

    private var issuesContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Summary header
            HStack(spacing: 10) {
                Image(systemName: issueMiners.contains(where: { $0.verdict.severity == .error }) ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(issueMiners.contains(where: { $0.verdict.severity == .error }) ? .red : .orange)
                    .font(.body.weight(.semibold))
                Text(issueMiners.count == 1 ? "1 miner needs attention" : "\(issueMiners.count) miners need attention")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }

            Divider()

            // Per-miner issue rows
            ForEach(issueMiners, id: \.miner.id) { item in
                issueRow(miner: item.miner, verdict: item.verdict)
            }
        }
    }

    private func issueRow(miner: MinerManager.ManagedMiner, verdict: HealthVerdict) -> some View {
        Button {
            onSelectMiner?(miner.id)
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(verdict.severity == .error ? Color.red : Color.orange)
                    .frame(width: 7, height: 7)

                Text(miner.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)

                Text("·")
                    .foregroundStyle(.tertiary)

                Text(verdict.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
