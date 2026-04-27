import SwiftUI
import SwiftMinerCore
import SwiftMinerService

/// Admin overview for managing unlinked accounts and identity assignment.
struct AdminOverviewView: View {
    @Environment(NavigationModel.self) private var navigation
    @Environment(\.openSettings) private var openSettings
    @State private var isRefreshing = false
    @State private var selectedAccount: Account?
    @State private var showAssignSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                swiftBotStatusBanner
                
                headerSection
                
                if navigation.unownedAccounts.isEmpty {
                    emptyState
                } else {
                    unownedAccountsList
                }
            }
            .padding(24)
        }
        .task {
            await refresh()
        }
        .sheet(item: $selectedAccount) { account in
            AssignUserSheet(account: account) {
                Task { await refresh() }
            }
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Unlinked Twitch Accounts")
                .font(.title2.weight(.bold))
            
            Text("These accounts are currently running in the engine but have not been assigned to a Discord user. Assign them to enable bot-side commands and notifications.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var swiftBotStatusBanner: some View {
        HStack {
            let state = navigation.swiftBotState
            let config = statusConfig(for: state)
            
            Image(systemName: config.icon)
                .foregroundStyle(config.color)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(config.title)
                    .font(.subheadline.weight(.bold))
                Text(config.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            if state == .notConfigured {
                Button("Configure") {
                    openSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button {
                    Task { await navigation.checkSwiftBotConnection() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Re-check connectivity")
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private struct StatusConfig {
        let title: String
        let message: String
        let icon: String
        let color: Color
    }

    private func statusConfig(for state: SwiftBotConnectionState) -> StatusConfig {
        switch state {
        case .connected:
            return StatusConfig(
                title: "SwiftBot Connected",
                message: "Integration active. Commands and notifications are live.",
                icon: "bolt.fill",
                color: .green
            )
        case .notConfigured:
            return StatusConfig(
                title: "SwiftBot Not Configured",
                message: "No endpoint set. Account linking works, but bot commands and notifications are unavailable.",
                icon: "exclamationmark.triangle.fill",
                color: .orange
            )
        case .disconnected:
            return StatusConfig(
                title: "SwiftBot Disconnected",
                message: "Could not reach bot. Check endpoint and bot status.",
                icon: "bolt.slash.fill",
                color: .red
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            let isConnected = navigation.swiftBotState == .connected
            
            Image(systemName: isConnected ? "checkmark.seal.fill" : "exclamationmark.shield.fill")
                .font(.system(size: 44))
                .foregroundStyle(isConnected ? .green : .orange)
            
            Text(isConnected ? "All accounts are linked" : "Integration required")
                .font(.headline)
            
            Text(isConnected 
                 ? "Every Twitch account currently managed by the service is owned by a Discord user."
                 : "Connect SwiftBot to view and manage account assignments.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .glassCard()
    }

    private var unownedAccountsList: some View {
        VStack(spacing: 12) {
            ForEach(navigation.unownedAccounts) { account in
                UnlinkedAccountRow(account: account) {
                    selectedAccount = account
                }
            }
        }
    }

    private func refresh() async {
        isRefreshing = true
        await navigation.refreshUnownedAccounts()
        isRefreshing = false
    }
}

private struct UnlinkedAccountRow: View {
    let account: Account
    let onAssign: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(.secondary.opacity(0.2))
                
                Image(systemName: "person.fill.questionmark")
                    .foregroundStyle(.secondary)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text(account.username)
                    .font(.headline)
                
                Text("Twitch ID: \(account.id)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button("Assign to User") {
                onAssign()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(16)
        .glassCard()
    }
}

private struct AssignUserSheet: View {
    let account: Account
    let onComplete: () -> Void

    @Environment(NavigationModel.self) private var navigation
    @Environment(\.dismiss) private var dismiss
    @State private var discordId = ""
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var showReassignConfirmation = false
    @State private var conflictingOwner = ""

    private var cleanId: String { discordId.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isValidDiscordId: Bool { cleanId.count >= 17 && cleanId.count <= 19 && cleanId.allSatisfy(\.isNumber) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Assign Twitch Account")
                .font(.title3.weight(.bold))

            Text("Assign @\(account.username) to a Discord user. This will grant them control of this miner via SwiftBot.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Discord User ID")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)

                TextField("e.g. 123456789012345678", text: $discordId)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isProcessing)

                if !cleanId.isEmpty && !isValidDiscordId {
                    Text("Discord ID must be 17–19 digits")
                        .font(.caption)
                        .foregroundStyle(.red)
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

                Button("Assign Account") {
                    Task { await performAssignment(policy: .rejectIfOwned) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValidDiscordId || isProcessing)
            }
        }
        .padding(24)
        .frame(width: 380)
        .glassCard()
        .confirmationDialog(
            "Reassign Account?",
            isPresented: $showReassignConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reassign", role: .destructive) {
                Task { await performAssignment(policy: .allowConfirmed(expectedCurrentOwner: conflictingOwner)) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("\(account.username) is currently linked to \(conflictingOwner).\n\nReassign to \(cleanId)?")
        }
    }

    private func performAssignment(policy: ReassignmentPolicy) async {
        guard isValidDiscordId else { return }
        isProcessing = true
        errorMessage = nil

        let assignment = AdminAccountAssignment(
            twitchAccountId: account.id,
            discordId: cleanId,
            operatorIdentity: .localAdmin
        )
        let result = await navigation.adminLinkingService.assignAccount(assignment, policy: policy)

        switch result {
        case .linked(_, _, let userWasCreated, let wasReassignment):
            isProcessing = false
            dismiss()
            onComplete()
            _ = (userWasCreated, wasReassignment) // consumed by onComplete refresh

        case .alreadyLinked(let currentDiscordId):
            isProcessing = false
            conflictingOwner = currentDiscordId
            showReassignConfirmation = true

        case .notFound:
            isProcessing = false
            errorMessage = "Twitch account not found in the database."

        case .invalidDiscordId:
            isProcessing = false
            errorMessage = "Invalid Discord ID — must be 17–19 digits."

        case .internalError(let message):
            isProcessing = false
            errorMessage = "Assignment failed: \(message)"
        }
    }
}

#Preview {
    AdminOverviewView()
        .environment(NavigationModel(clientId: "preview"))
}
