import SwiftUI
import SwiftMinerCore
import SwiftMinerService

/// Root view for administrative tasks and system management.
struct AdminView: View {
    @Environment(NavigationModel.self) private var navigation
    @State private var showAddUserSheet = false
    @State private var selectedTab = AdminTab.accounts

    enum AdminTab: String, CaseIterable, Identifiable {
        case accounts = "Unlinked Accounts"
        case users = "Registered Users"
        case integration = "Bot Integration"
        var id: String { self.rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Admin View", selection: $selectedTab) {
                ForEach(AdminTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 8)

            Divider()

            switch selectedTab {
            case .accounts:
                AdminOverviewView()
            case .users:
                UserListView()
            case .integration:
                IntegrationSettingsView()
            }
        }
        .navigationTitle("Admin")
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

private struct IntegrationSettingsView: View {
    @ObservedObject private var settings = Settings.shared
    @Environment(NavigationModel.self) private var navigation
    @State private var showKey = false
    @State private var isTestingConnection = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("SwiftBot Integration")
                        .font(.title2.weight(.bold))
                    
                    Text("Configure the connection between this SwiftMiner instance and your Discord bot.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Service API Key", systemImage: "key.fill")
                            .font(.headline)
                        
                        Text("This key must be entered into the SwiftBot 'Advanced' settings for the bot to fetch your miner status.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        HStack {
                            Group {
                                if showKey {
                                    Text(settings.swiftMinerAPIKey)
                                } else {
                                    Text(String(repeating: "•", count: settings.swiftMinerAPIKey.count))
                                }
                            }
                            .font(.system(.body, design: .monospaced))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.black.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                            Button {
                                showKey.toggle()
                            } label: {
                                Image(systemName: showKey ? "eye.slash" : "eye")
                                    .frame(width: 20)
                            }
                            .buttonStyle(.bordered)

                            Button {
                                let pasteboard = NSPasteboard.general
                                pasteboard.clearContents()
                                pasteboard.setString(settings.swiftMinerAPIKey, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .frame(width: 20)
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 12) {
                        Label("Webhook Events", systemImage: "bell.badge.fill")
                            .font(.headline)
                        
                        Text("SwiftMiner sends real-time notifications to SwiftBot when drops are claimed or status changes.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 16) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Bot Webhook URL")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.secondary)
                                
                                TextField("e.g. http://127.0.0.1:38787/api/v1/webhooks/swiftminer", text: $settings.swiftBotWebhookURL)
                                    .textFieldStyle(.roundedBorder)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Text("HMAC Secret")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.secondary)
                                
                                SecureField("Shared secret for signing", text: $settings.swiftBotHmacSecret)
                                    .textFieldStyle(.roundedBorder)
                            }

                            Button {
                                Task {
                                    _ = await navigation.swiftBotConnectionService.sendTestEvent()
                                }
                            } label: {
                                Label("Send Test Webhook", systemImage: "paperplane.fill")
                            }
                            .buttonStyle(.bordered)
                            .disabled(!settings.swiftBotEnabled || settings.swiftBotWebhookURL.isEmpty)
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 12) {
                        Label("Connection Status", systemImage: "network")
                            .font(.headline)

                        HStack {
                            let state = navigation.swiftBotState
                            Image(systemName: state == .connected ? "checkmark.circle.fill" : (state == .disconnected ? "xmark.circle.fill" : "exclamationmark.triangle.fill"))
                                .foregroundStyle(state == .connected ? .green : (state == .disconnected ? .red : .orange))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(state == .connected ? "Connected" : (state == .disconnected ? "Disconnected" : "Not Configured"))
                                    .font(.subheadline.weight(.medium))
                                Text(state == .connected ? "SwiftBot is reachable" : (state == .disconnected ? "SwiftBot endpoint is unreachable" : "Enable SwiftBot and set endpoint"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button {
                                Task {
                                    isTestingConnection = true
                                    await navigation.checkSwiftBotConnection()
                                    isTestingConnection = false
                                }
                            } label: {
                                if isTestingConnection {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Label("Test", systemImage: "arrow.clockwise")
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isTestingConnection)
                        }
                    }
                }
                .padding(24)
                .glassCard()
            }
            .padding(24)
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
            let result = await navigation.adminLinkingService.registerUser(discordId: cleanId, operatorIdentity: .localAdmin)
            
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
