import SwiftUI
import SwiftMinerCore

/// A unified hero card that represents the resolved PrimaryState of a miner.
/// Replaces legacy status badges and scattered state labels with a single story.
struct MinerStateCard: View {
    let miner: MinerManager.ManagedMiner
    var onAction: (() -> Void)? = nil
    var onDismiss: ((String) -> Void)? = nil

    private var state: PrimaryState { miner.primaryState }
    private var resolved: ResolvedPrimaryState? { miner.resolvedPrimaryState }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            headerSection

            if case .mining(let progress) = state {
                miningProgressSection(progress)
            } else if case .blocked(let reasons) = state, reasons.contains(.accountNotLinked) {
                let gameId = resolved?.resolved?.gameId ?? "all"
                actionSection(
                    title: "Action required",
                    subtitle: "Connect your game account to resume earning drops.",
                    buttonTitle: "Link Account",
                    secondaryButtonTitle: "Dismiss",
                    onSecondaryAction: {
                        onDismiss?(gameId)
                    }
                )
            }
        }
        .padding(22)
        .glassCard()
        .shadow(color: .black.opacity(0.07), radius: 6, y: 2)
    }

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle()
                    .fill(config.color.opacity(0.15))
                    .frame(width: 44, height: 44)

                Image(systemName: config.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(config.color)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(config.headline)
                    .font(.title3.weight(.bold))

                if let subtitle = config.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()
        }
    }

    private func miningProgressSection(_ progress: MiningProgress) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(progress.dropName)
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Text("\(Int(progress.progressFraction * 100))%")
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.green)
            }

            ProgressView(value: progress.progressFraction)
                .progressViewStyle(.linear)
                .tint(.green)

            HStack {
                Text("\(progress.campaignName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if progress.minutesRemaining > 0 {
                    Text("\(progress.minutesRemaining) min remaining")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Ready to claim!")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: GlassRadius.small, style: .continuous))
    }

    private func actionSection(
        title: String,
        subtitle: String,
        buttonTitle: String,
        secondaryButtonTitle: String? = nil,
        onSecondaryAction: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let secondaryTitle = secondaryButtonTitle {
                Button {
                    onSecondaryAction?()
                } label: {
                    Text(secondaryTitle)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button {
                onAction?()
            } label: {
                Text(buttonTitle)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.orange)
        }
        .padding(14)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: GlassRadius.small, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GlassRadius.small, style: .continuous)
                .strokeBorder(.orange.opacity(0.2), lineWidth: 1)
        }
    }

    // MARK: - View Config

    private var config: StateConfig {
        let gameName = resolved?.resolved?.gameName
        switch state {
        case .blocked(let reasons):
            if reasons.contains(.accountNotLinked) {
                return StateConfig(
                    headline: gameName ?? "Account",
                    subtitle: "Not linked",
                    icon: "link.badge.plus",
                    color: .orange
                )
            } else if reasons.contains(.noEligibleCampaign) {
                return StateConfig(
                    headline: "No active campaigns",
                    subtitle: "No drops available for prioritised games",
                    icon: "archivebox",
                    color: .secondary
                )
            } else {
                return StateConfig(
                    headline: gameName ?? "No live streams",
                    subtitle: "No participating channels are live right now.",
                    icon: "antenna.radiowaves.left.and.right",
                    color: .cyan
                )
            }

        case .ready:
            return StateConfig(
                headline: "No active campaigns",
                subtitle: "No drops available for prioritised games",
                icon: "waveform.path.ecg",
                color: .blue
            )

        case .mining(let progress):
            return StateConfig(
                headline: "Watching \(progress.gameName)",
                subtitle: nil,
                icon: "play.fill",
                color: .green
            )

        case .completed:
            return StateConfig(
                headline: "No active campaigns",
                subtitle: "All currently available drops are completed.",
                icon: "checkmark.seal.fill",
                color: .purple
            )
        }
    }

    private struct StateConfig {
        let headline: String
        let subtitle: String?
        let icon: String
        let color: Color
    }
}
