import SwiftUI
import SwiftMinerCore
import SwiftMinerService

/// Minimal Discord oversight panel.
///
/// Shows one row per miner: name, link status, optional action.
/// Actions emit outbox events; SwiftBot handles all user-facing messaging.
struct AdminView: View {
    @Environment(NavigationModel.self) private var navigation
    @State private var expandedMinerId: String?
    @State private var linkSheetMiner: MinerManager.ManagedMiner?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(navigation.minerManager.miners) { miner in
                    MinerRow(
                        miner: miner,
                        isExpanded: expandedMinerId == miner.id,
                        onTap: { toggleExpanded(miner.id) },
                        onLink: { linkSheetMiner = miner },
                        onFix: { Task { await emitReauth(for: miner) } }
                    )
                    Divider()
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .navigationTitle("Discord")
        .sheet(item: $linkSheetMiner) { miner in
            LinkMinerSheet(miner: miner)
        }
    }

    private func toggleExpanded(_ id: String) {
        expandedMinerId = (expandedMinerId == id) ? nil : id
    }

    private func emitReauth(for miner: MinerManager.ManagedMiner) async {
        guard let discordId = miner.ownerDiscordId else { return }
        await navigation.eventEmitter.emitUserReauthRequested(
            discordUserId: discordId,
            twitchAccountId: miner.accountId
        )
    }
}

// MARK: - Status

private enum LinkStatus {
    case linked
    case notLinked
    case needsAttention

    var label: String {
        switch self {
        case .linked: return "Linked"
        case .notLinked: return "Not Linked"
        case .needsAttention: return "Needs Attention"
        }
    }

    var color: Color {
        switch self {
        case .linked: return .green
        case .notLinked: return .secondary
        case .needsAttention: return .orange
        }
    }

    static func resolve(_ miner: MinerManager.ManagedMiner) -> LinkStatus {
        guard miner.ownerDiscordId != nil else { return .notLinked }
        if miner.needsAuth { return .needsAttention }
        return .linked
    }

    func issueDescription(for miner: MinerManager.ManagedMiner) -> String? {
        switch self {
        case .linked: return nil
        case .notLinked: return "This Twitch account has no Discord owner."
        case .needsAttention: return "Twitch authentication has expired or been revoked."
        }
    }
}

// MARK: - Row

private struct MinerRow: View {
    let miner: MinerManager.ManagedMiner
    let isExpanded: Bool
    let onTap: () -> Void
    let onLink: () -> Void
    let onFix: () -> Void

    var body: some View {
        let status = LinkStatus.resolve(miner)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(miner.displayName)
                    .font(.body.weight(.medium))

                Spacer()

                Text(status.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(status.color)

                actionButton(for: status)
            }
            .contentShape(Rectangle())
            .onTapGesture { onTap() }

            if isExpanded {
                expandedDetails(status: status)
                    .padding(.top, 4)
                    .padding(.leading, 4)
            }
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func actionButton(for status: LinkStatus) -> some View {
        switch status {
        case .notLinked:
            Button("Link", action: onLink)
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .needsAttention:
            Button("Fix", action: onFix)
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .linked:
            EmptyView()
        }
    }

    @ViewBuilder
    private func expandedDetails(status: LinkStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            detailRow("Twitch", miner.username)
            if let discordId = miner.ownerDiscordId {
                detailRow("Discord ID", discordId)
            }
            if let issue = status.issueDescription(for: miner) {
                Text(issue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Link sheet

private struct LinkMinerSheet: View {
    let miner: MinerManager.ManagedMiner

    @Environment(NavigationModel.self) private var navigation
    @Environment(\.dismiss) private var dismiss
    @State private var discordId = ""
    @State private var isProcessing = false
    @State private var errorMessage: String?

    private var cleanId: String { discordId.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isValid: Bool { cleanId.count >= 17 && cleanId.count <= 19 && cleanId.allSatisfy(\.isNumber) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Link \(miner.displayName)")
                .font(.title3.weight(.bold))

            Text("Assign a Discord ID to this Twitch account.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("Discord User ID", text: $discordId)
                .textFieldStyle(.roundedBorder)
                .disabled(isProcessing)

            if !cleanId.isEmpty && !isValid {
                Text("Discord ID must be 17–19 digits.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .disabled(isProcessing)
                Spacer()
                Button("Link") { Task { await performLink() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid || isProcessing)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func performLink() async {
        isProcessing = true
        errorMessage = nil

        let assignment = AdminAccountAssignment(
            twitchAccountId: miner.accountId,
            discordId: cleanId,
            operatorIdentity: .localAdmin
        )
        let result = await navigation.adminLinkingService.assignAccount(assignment, policy: .rejectIfOwned)

        await MainActor.run {
            isProcessing = false
            switch result {
            case .linked:
                dismiss()
            case .alreadyLinked(let currentDiscordId):
                errorMessage = "Twitch account already linked to \(currentDiscordId)."
            case .notFound:
                errorMessage = "Twitch account not found."
            case .invalidDiscordId:
                errorMessage = "Invalid Discord ID."
            case .internalError(let message):
                errorMessage = message
            }
        }
    }
}

#Preview {
    AdminView()
        .environment(NavigationModel(clientId: "preview"))
}
