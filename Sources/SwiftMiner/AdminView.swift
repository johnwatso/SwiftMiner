import SwiftUI
import SwiftMinerCore
import SwiftMinerService

/// Discord oversight panel — one row per miner with link/unlink/test-DM controls.
struct AdminView: View {
    @Environment(NavigationModel.self) private var navigation
    @State private var expandedMinerId: String?
    @State private var linkIntent: LinkIntent?
    @State private var discordNamesById: [String: String] = [:]

    struct LinkIntent: Identifiable {
        let id = UUID()
        let miner: MinerManager.ManagedMiner
        let isRelink: Bool
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(navigation.minerManager.miners) { miner in
                    MinerRow(
                        miner: miner,
                        isExpanded: expandedMinerId == miner.id,
                        discordNamesById: discordNamesById,
                        onTap: { toggleExpanded(miner.id) },
                        onLink: { linkIntent = LinkIntent(miner: miner, isRelink: false) },
                        onRelink: { linkIntent = LinkIntent(miner: miner, isRelink: true) },
                        onFix: { Task { await emitReauth(for: miner) } }
                    )
                    Divider()
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .navigationTitle("Discord")
        .sheet(item: $linkIntent) { intent in
            LinkMinerSheet(miner: intent.miner, isRelink: intent.isRelink)
        }
        .task { await loadDiscordNames() }
    }

    private func loadDiscordNames() async {
        let users = await navigation.swiftBotConnectionService.fetchDiscordUsers()
        var map: [String: String] = [:]
        for user in users { map[user.id] = user.displayName }
        discordNamesById = map
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
    let discordNamesById: [String: String]
    let onTap: () -> Void
    let onLink: () -> Void
    let onRelink: () -> Void
    let onFix: () -> Void

    @Environment(NavigationModel.self) private var navigation
    @State private var showUnlinkConfirmation = false
    @State private var isDMSending = false
    @State private var dmResult: Bool? = nil

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
        .confirmationDialog(
            "Unlink \(miner.displayName)?",
            isPresented: $showUnlinkConfirmation,
            titleVisibility: .visible
        ) {
            Button("Unlink", role: .destructive) {
                Task { await performUnlink() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The Discord account will no longer be linked to this Twitch account.")
        }
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
            Menu {
                Button {
                    Task { await sendTestDM() }
                } label: {
                    Label("Send Test DM", systemImage: "message")
                }
                Button("Re-link", action: onRelink)
                Divider()
                Button("Unlink", role: .destructive) {
                    showUnlinkConfirmation = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func expandedDetails(status: LinkStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            detailRow("Twitch", miner.username)
            if let discordId = miner.ownerDiscordId {
                if let name = discordNamesById[discordId] {
                    detailRow("Discord", name)
                } else {
                    detailRow("Discord", discordId)
                }
            }
            if let issue = status.issueDescription(for: miner) {
                Text(issue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            if let sent = dmResult {
                Text(sent ? "Test DM sent." : "Failed to send DM — check SwiftBot connection.")
                    .font(.caption)
                    .foregroundStyle(sent ? .green : .red)
                    .padding(.top, 2)
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

    private func sendTestDM() async {
        guard let discordId = miner.ownerDiscordId else { return }
        isDMSending = true
        dmResult = nil
        // Pull live app-level priorities so the test DM mirrors what real
        // activation DMs send. Using the no-arg overload would hard-code [].
        let priorityGames = await MainActor.run { Settings.shared.priorityGames }
        let ok = await navigation.swiftBotConnectionService.sendTestDM(
            to: discordId,
            twitchUsername: miner.username,
            priorityGames: priorityGames
        )
        dmResult = ok
        isDMSending = false
        if !isExpanded {
            // auto-open so the user sees the result
        }
    }

    private func performUnlink() async {
        let result = await navigation.adminLinkingService.unlinkAccount(
            twitchAccountId: miner.accountId,
            operatorIdentity: .localAdmin
        )
        if case .unlinked = result {
            navigation.minerManager.setOwnerDiscordId(forAccountId: miner.accountId, to: nil)
        }
    }
}

// MARK: - Link sheet

private struct LinkMinerSheet: View {
    let miner: MinerManager.ManagedMiner
    let isRelink: Bool

    @Environment(NavigationModel.self) private var navigation
    @Environment(\.dismiss) private var dismiss
    @State private var discordUsers: [SwiftBotDiscordUser] = []
    @State private var selectedUserId: String?
    @State private var fallbackId = ""
    @State private var isLoading = true
    @State private var isProcessing = false
    @State private var errorMessage: String?

    private var useFallback: Bool { discordUsers.isEmpty && !isLoading }
    private var cleanFallbackId: String { fallbackId.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isFallbackValid: Bool {
        cleanFallbackId.count >= 17 && cleanFallbackId.count <= 19 && cleanFallbackId.allSatisfy(\.isNumber)
    }
    private var canSubmit: Bool {
        if useFallback { return isFallbackValid && !isProcessing }
        return selectedUserId != nil && !isProcessing
    }
    private var resolvedDiscordId: String? {
        useFallback ? (isFallbackValid ? cleanFallbackId : nil) : selectedUserId
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isRelink ? "Re-link \(miner.displayName)" : "Link \(miner.displayName)")
                .font(.title3.weight(.bold))

            Text(isRelink
                 ? "Choose a different Discord account to own this Twitch account."
                 : "Assign a Discord account to this Twitch account.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if isLoading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading Discord users…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if !discordUsers.isEmpty {
                Picker("Discord account", selection: $selectedUserId) {
                    Text("Select a user…").tag(String?.none)
                    ForEach(discordUsers) { user in
                        Text(user.displayName)
                            .tag(Optional(user.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            } else {
                // SwiftBot not connected — fall back to manual entry
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Discord User ID", text: $fallbackId)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isProcessing)
                    if !cleanFallbackId.isEmpty && !isFallbackValid {
                        Text("Discord ID must be 17–19 digits.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Text("SwiftBot is not connected — enter a Discord ID manually.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                Button(isRelink ? "Re-link" : "Link") {
                    Task { await performLink() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 380)
        .task { await loadUsers() }
    }

    private func loadUsers() async {
        isLoading = true
        // SwiftBot already filters out bots and webhooks before returning.
        discordUsers = await navigation.swiftBotConnectionService.fetchDiscordUsers()
        isLoading = false
    }

    private func performLink() async {
        guard let discordId = resolvedDiscordId else { return }
        isProcessing = true
        errorMessage = nil

        let policy: ReassignmentPolicy = isRelink
            ? .allowConfirmed(expectedCurrentOwner: miner.ownerDiscordId ?? "")
            : .rejectIfOwned

        let assignment = AdminAccountAssignment(
            twitchAccountId: miner.accountId,
            discordId: discordId,
            operatorIdentity: .localAdmin
        )
        let result = await navigation.adminLinkingService.assignAccount(assignment, policy: policy)

        await MainActor.run {
            isProcessing = false
            switch result {
            case .linked:
                navigation.minerManager.setOwnerDiscordId(forAccountId: miner.accountId, to: discordId)
                dismiss()
            case .alreadyLinked(let currentDiscordId):
                if currentDiscordId == discordId {
                    // Server already considers this link valid — sync local state and dismiss.
                    navigation.minerManager.setOwnerDiscordId(forAccountId: miner.accountId, to: discordId)
                    dismiss()
                } else {
                    let label = displayName(forDiscordId: currentDiscordId)
                    errorMessage = "Twitch account already linked to \(label). Use Re-link to reassign."
                }
            case .notFound:
                errorMessage = "Twitch account not found."
            case .invalidDiscordId:
                errorMessage = "Invalid Discord ID."
            case .internalError(let message):
                errorMessage = message
            }
        }
    }

    private func displayName(forDiscordId id: String) -> String {
        discordUsers.first(where: { $0.id == id })?.displayName ?? id
    }
}

#Preview {
    AdminView()
        .environment(NavigationModel(clientId: "preview"))
}
