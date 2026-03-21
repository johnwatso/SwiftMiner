import SwiftUI
import SwiftTwitchMiner

/// At-a-glance health summary card for all miners.
/// Shows "All miners healthy" when everything is fine, or a concise list of issues.
/// Designed to sit at the top of the Overview dashboard.
struct MinerHealthCard: View {
    let miners: [MinerManager.ManagedMiner]
    var onSelectMiner: ((String) -> Void)?

    /// Refreshes time-dependent verdicts (e.g. "stuck for X min") every 30 seconds.
    @State private var now = Date()

    // MARK: - Health Verdict

    enum Severity { case ok, warning, error }

    struct HealthVerdict {
        let severity: Severity
        let message: String
    }

    private func verdict(for miner: MinerManager.ManagedMiner) -> HealthVerdict {
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
        return HealthVerdict(severity: .ok, message: miner.status.displayName)
    }

    private var issueMiners: [(miner: MinerManager.ManagedMiner, verdict: HealthVerdict)] {
        miners.compactMap { miner in
            let v = verdict(for: miner)
            return v.severity == .ok ? nil : (miner, v)
        }
    }

    private var allHealthy: Bool { issueMiners.isEmpty }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if allHealthy {
                healthyRow
            } else {
                issuesContent
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    // MARK: - Healthy State

    private var healthyRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.body.weight(.semibold))
            Text(miners.count == 1 ? "Miner is running normally" : "All \(miners.count) miners are running normally")
                .font(.subheadline.weight(.medium))
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

                Text(miner.username)
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
