import SwiftUI
import SwiftMinerCore
import SwiftMinerService

/// Root view for administrative tasks and system management.
struct AdminView: View {
    @Environment(NavigationModel.self) private var navigation
    @State private var showAddUserSheet = false

    var body: some View {
        VStack(spacing: 0) {
            AdminOverviewView()
        }
        .toolbar {
            ToolbarItem {
                Button {
                    showAddUserSheet = true
                } label: {
                    Label("Add User", systemImage: "person.badge.plus")
                }
                .help("Manually register a Discord user")
            }
        }
        .sheet(isPresented: $showAddUserSheet) {
            AddUserSheet()
        }
    }
}

#Preview {
    AdminView()
        .environment(NavigationModel(clientId: "preview"))
}

private struct AddUserSheet: View {
    @Environment(NavigationModel.self) private var navigation
    @Environment(\.dismiss) private var dismiss
    @State private var discordId = ""
    @State private var isProcessing = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Register Discord User")
                .font(.title3.weight(.bold))
            
            Text("Manually register a Discord ID in the system. This allows the user to log in to the dashboard even before a Twitch account is assigned to them.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Discord User ID")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                
                TextField("e.g. 123456789012345678", text: $discordId)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isProcessing)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .disabled(isProcessing)

                Spacer()

                Button("Register User") {
                    performRegistration()
                }
                .buttonStyle(.borderedProminent)
                .disabled(discordId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isProcessing)
            }
        }
        .padding(24)
        .frame(width: 380)
        .glassCard()
    }

    private func performRegistration() {
        let cleanId = discordId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty else { return }

        isProcessing = true
        errorMessage = nil

        Task {
            let result = await navigation.adminLinkingService.registerUser(discordId: cleanId, operatorId: "local_admin")
            
            await MainActor.run {
                isProcessing = false
                switch result {
                case .registered(let id):
                    print("[AdminView] Registered user: \(id)")
                    dismiss()
                case .alreadyRegistered(let id):
                    errorMessage = "User \(id) is already registered."
                case .invalidDiscordId:
                    errorMessage = "Invalid Discord ID. Must be 17-19 digits."
                case .internalError(let error):
                    errorMessage = "System error: \(error)"
                }
            }
        }
    }
}
