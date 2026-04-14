import SwiftUI
import SwiftMinerCore

/// A unified hero card that represents the resolved PrimaryState of a miner.
/// Replaces legacy status badges and scattered state labels with a single story.
struct MinerStateCard: View {
    let state: PrimaryState
    var onAction: (() -> Void)? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            headerSection
            
            if case .mining(let progress) = state {
                miningProgressSection(progress)
            } else if case .blocked(let reasons) = state, reasons.contains(.accountNotLinked) {
                actionSection(
                    title: "Link your account",
                    subtitle: "Connect your game account to earn drops automatically.",
                    buttonTitle: "Open Link Page"
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
                
                Text(config.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
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
    
    private func actionSection(title: String, subtitle: String, buttonTitle: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
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
        switch state {
        case .blocked(let reasons):
            if reasons.contains(.accountNotLinked) {
                return StateConfig(
                    headline: "Link Required",
                    subtitle: "Authentication or account link missing. Action required to resume.",
                    icon: "link.badge.plus",
                    color: .orange
                )
            } else if reasons.contains(.noEligibleCampaign) {
                return StateConfig(
                    headline: "Nothing to earn",
                    subtitle: "No active drop campaigns for your preferred games right now.",
                    icon: "archivebox",
                    color: .secondary
                )
            } else {
                return StateConfig(
                    headline: "Waiting for stream",
                    subtitle: "The selected campaign is active, but no participating channels are live.",
                    icon: "antenna.radiowaves.left.and.right",
                    color: .cyan
                )
            }
            
        case .ready:
            return StateConfig(
                headline: "Ready to mine",
                subtitle: "System is healthy and scanning for available drops.",
                icon: "waveform.path.ecg",
                color: .blue
            )
            
        case .mining(let progress):
            return StateConfig(
                headline: "Mining \(progress.gameName)",
                subtitle: "Actively earning progress on an eligible stream.",
                icon: "play.fill",
                color: .green
            )
            
        case .completed:
            return StateConfig(
                headline: "All caught up",
                subtitle: "You've earned all available drops for now. Great work!",
                icon: "checkmark.seal.fill",
                color: .purple
            )
        }
    }
    
    private struct StateConfig {
        let headline: String
        let subtitle: String
        let icon: String
        let color: Color
    }
}
