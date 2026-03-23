import SwiftUI
import SwiftTwitchMiner

/// Sheet for adding a new Twitch account via device-code OAuth.
///
/// Presented from `ContentView` at the `NavigationSplitView` level so that
/// macOS List selection never interferes with sheet presentation.
struct AuthRequiredSheet: View {
    @Binding var isPresented: Bool
    @Environment(NavigationModel.self) private var navigation

    @State private var loginService = MinerLoginService()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            headerSection
            contentArea
            footerBar
        }
        .frame(width: 480, height: 430)
        .padding(28)
        .glassContentSurface()
        .onAppear {
            loginService.startDeviceAuth()
        }
        .onChange(of: loginService.state) { _, newState in
            if case .succeeded(let account) = newState {
                handleSuccess(account: account)
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Add Twitch Account", systemImage: "tv.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)

            Text("Authorize a Twitch account to join your miner dashboard. SwiftMiner will open Twitch in your browser and keep watching for confirmation here.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentArea: some View {
        switch loginService.state {
        case .idle, .starting:
            startingView

        case .waitingForUser(let code, let url, let expiresIn):
            waitingView(code: code, url: url, expiresIn: expiresIn)

        case .polling:
            pollingView

        case .succeeded:
            successView

        case .failed(let message):
            failureView(message: message)
        }
    }

    // MARK: - Starting

    private var startingView: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProgressView()
                .controlSize(.large)

            Text("Connecting to Twitch…")
                .font(.headline)

            Text("Requesting a device code from Twitch.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Waiting for user

    private func waitingView(code: String, url: URL, expiresIn: Int) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("1. Open Twitch")
                    .font(.headline)
                Text("Open the activation page in your browser, then enter the code shown below.")
                    .foregroundStyle(.secondary)
            }

            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Label("Open Twitch Activation Page", systemImage: "safari")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            VStack(alignment: .leading, spacing: 10) {
                Text("2. Enter this code")
                    .font(.headline)

                HStack(spacing: 12) {
                    Text(code)
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .tracking(6)
                        .textSelection(.enabled)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .help("Copy code")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                Text("Code expires in \(expiresIn / 60) minutes")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Waiting for confirmation")
                        .font(.callout.weight(.medium))
                    Text("This window will finish automatically after Twitch approves the login.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Polling

    private var pollingView: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProgressView()
                .controlSize(.large)

            Text("Waiting for confirmation…")
                .font(.headline)

            Text("Complete the authorization in your browser.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Success

    private var successView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Account Added!")
                .font(.title3.weight(.semibold))
            Text("Your Twitch account has been connected.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Failure

    private func failureView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)

            Text("Authentication Failed")
                .font(.headline)

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)

            Button("Try Again") {
                loginService.cancel()
                loginService.startDeviceAuth()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack {
            Button("Cancel") {
                loginService.cancel()
                isPresented = false
            }
            .keyboardShortcut(.cancelAction)

            Spacer()
        }
    }

    // MARK: - Handlers

    private func handleSuccess(account: Account) {
        // Ensure MinerManager uses the correct client ID when creating the engine.
        // This matters when the client ID was supplied via Settings rather than env var.
        navigation.minerManager.updateClientId(Settings.shared.resolvedClientId)

        let minerId = navigation.minerManager.addAccount(account)
        Task {
            let settings = Settings.shared
            try? await navigation.minerManager.startMiner(
                minerId: minerId,
                priorityGames: settings.priorityGames,
                excludedGames: settings.excludedGames,
                strategy: settings.miningStrategy,
                enableBadgesEmotes: settings.enableBadgesEmotes,
                showClaimNotifications: settings.showClaimNotifications
            )
            // Brief pause so the user sees the success state
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            isPresented = false
        }
    }
}

// MARK: - Preview

#Preview {
    AuthRequiredSheet(isPresented: .constant(true))
        .environment(NavigationModel(clientId: "preview"))
}
