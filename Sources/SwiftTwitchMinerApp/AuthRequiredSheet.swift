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
        VStack(spacing: 0) {
            headerBar
            Divider()
            contentArea
            Divider()
            footerBar
        }
        .frame(width: 460, height: 420)
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

    private var headerBar: some View {
        HStack {
            Image(systemName: "tv.fill")
                .foregroundStyle(.purple)
            Text("Add Twitch Account")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
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
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Connecting to Twitch…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Waiting for user

    private func waitingView(code: String, url: URL, expiresIn: Int) -> some View {
        VStack(spacing: 20) {
            // Instructions
            Text("Visit the Twitch activation page and enter your code.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            // Activation code
            VStack(spacing: 6) {
                Text("Activation Code")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                HStack(spacing: 12) {
                    Text(code)
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .tracking(6)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy code")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

                Text("Expires in \(expiresIn / 60) min")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Open URL button
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Label("Open Twitch Activation Page", systemImage: "safari")
                    .font(.callout.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            // Status
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Waiting for confirmation…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Polling

    private var pollingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Waiting for confirmation…")
                .foregroundStyle(.secondary)
            Text("Complete the authorization in your browser.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Success

    private var successView: some View {
        VStack(spacing: 14) {
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
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)

            Text("Authentication Failed")
                .font(.headline)

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Try Again") {
                loginService.cancel()
                loginService.startDeviceAuth()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
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
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Handlers

    private func handleSuccess(account: Account) {
        // Ensure MinerManager uses the correct client ID when creating the engine.
        // This matters when the client ID was supplied via Settings rather than env var.
        navigation.minerManager.updateClientId(Settings.shared.resolvedClientId)

        let minerId = navigation.minerManager.addAccount(account)
        Task {
            try? await navigation.minerManager.startMiner(minerId: minerId)
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
