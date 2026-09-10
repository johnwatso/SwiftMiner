import SwiftUI
import SwiftMinerCore
import SwiftMinerService

enum SwiftBotInvitationEligibility {
    static func eligibleMembers(
        from members: [SwiftBotDiscordUser],
        excluding linkedDiscordIDs: Set<String>
    ) -> [SwiftBotDiscordUser] {
        members.filter { !linkedDiscordIDs.contains($0.id) }
    }
}

/// Chooses a member of the connected Discord server for SwiftBot to DM the
/// invitation to.
///
/// Selecting a person never sends anything — the DM only goes out when the user
/// presses Send Invitation.
struct SwiftBotInvitationSheet: View {
    let invitation: SwiftMinerInvitation
    let onCancel: () -> Void
    let onSent: () -> Void

    @Environment(NavigationModel.self) private var navigation

    @State private var members: [SwiftBotDiscordUser] = []
    @State private var searchText = ""
    @State private var selectedMemberId: String?
    @State private var isLoading = true
    @State private var isSending = false
    @State private var errorMessage: String?

    private var eligibleMembers: [SwiftBotDiscordUser] {
        SwiftBotInvitationEligibility.eligibleMembers(
            from: members,
            excluding: Set(navigation.minerManager.miners.compactMap(\.ownerDiscordId))
        )
    }

    private var filteredMembers: [SwiftBotDiscordUser] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return eligibleMembers }
        return eligibleMembers.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || ($0.username?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var selectedMember: SwiftBotDiscordUser? {
        members.first { $0.id == selectedMemberId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 42, height: 42)
                    .background(.tint.opacity(0.10), in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Send with SwiftBot")
                        .font(.title2.weight(.semibold))
                    Text("Choose someone for SwiftBot to send the invitation to in a Discord direct message.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            memberList

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button {
                    onCancel()
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
                .keyboardShortcut(.cancelAction)
                    .disabled(isSending)
                Spacer()
                if isSending {
                    ProgressView().controlSize(.small)
                }
                Button("Send Invitation") {
                    Task { await sendInvitation() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedMember == nil || isSending)
            }
            .controlSize(.regular)
        }
        .padding(24)
        .frame(height: 480)
        .task { await loadMembers() }
    }

    @ViewBuilder
    private var memberList: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search members", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .disabled(isLoading || eligibleMembers.isEmpty)

            if isLoading {
                centeredNotice {
                    ProgressView().controlSize(.small)
                    Text("Loading members from your Discord server…")
                }
            } else if members.isEmpty {
                centeredNotice {
                    Image(systemName: "person.slash")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("SwiftBot did not return any server members. Check that SwiftBot is connected in Settings, then reopen this window.")
                }
            } else if eligibleMembers.isEmpty {
                centeredNotice {
                    Image(systemName: "person.2.badge.checkmark")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("Everyone on this Discord server is already connected to SwiftMiner.")
                }
            } else if filteredMembers.isEmpty {
                centeredNotice {
                    Text("No members match “\(searchText)”.")
                }
            } else {
                List(filteredMembers, selection: $selectedMemberId) { member in
                    memberRow(member)
                        .tag(member.id)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .clipShape(RoundedRectangle(cornerRadius: TahoeMetrics.card, style: .continuous))
                .tahoeCard()
            }

            if !eligibleMembers.isEmpty {
                Text("Only people who aren't already connected to SwiftMiner are shown.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func memberRow(_ member: SwiftBotDiscordUser) -> some View {
        HStack(spacing: 10) {
            MinerDiscordAvatar(url: member.avatarURL)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(member.displayName)
                    .font(.callout)
                if let username = member.username?.nilIfBlank, username != member.displayName {
                    Text("@\(username)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func centeredNotice<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 8) {
            content()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
    }

    private func loadMembers() async {
        isLoading = true
        members = await navigation.swiftBotConnectionService.fetchDiscordUsers()
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        isLoading = false
    }

    private func sendInvitation() async {
        guard let member = selectedMember else { return }
        isSending = true
        errorMessage = nil

        let minutes = max(1, Int(ceil(invitation.expiresAt.timeIntervalSinceNow / 60)))
        let sent = await navigation.swiftBotConnectionService.sendFriendInvitationDM(
            to: member.id,
            invitationURL: invitation.invitationURL.absoluteString,
            inviterDisplayName: invitation.inviterDisplayName,
            expiresInMinutes: minutes
        )

        isSending = false
        if sent {
            onSent()
        } else {
            errorMessage = "SwiftBot could not deliver the invitation to \(member.displayName). Check the SwiftBot connection in Settings and try again."
        }
    }
}
