import SwiftUI
import SwiftMinerCore

/// Sheet for adding a new Twitch account via device-code OAuth.
///
/// Presented from `ContentView` at the `NavigationSplitView` level so that
/// macOS List selection never interferes with sheet presentation.
struct AuthRequiredSheet: View {
    @Binding var isPresented: Bool
    @Environment(NavigationModel.self) private var navigation

    @State private var loginService = MinerLoginService()
    @State private var successDismissTask: Task<Void, Never>?

    private let sheetCornerRadius: CGFloat = 18

    private var sheetShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: sheetCornerRadius, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            headerSection
            contentArea
            footerBar
        }
        .frame(width: 480, height: 430)
        .padding(28)
        .background {
            sheetShape
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.97))
                .overlay {
                    sheetShape
                        .fill(.ultraThinMaterial.opacity(0.35))
                }
                .shadow(color: .black.opacity(0.14), radius: 16, y: 10)
        }
        .overlay {
            sheetShape
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        }
        .clipShape(sheetShape)
        .compositingGroup()
        .onAppear {
            loginService.startDeviceAuth()
        }
        .onChange(of: loginService.state) { _, newState in
            if case .succeeded(let account) = newState {
                handleSuccess(account: account)
            }
        }
        .onDisappear {
            successDismissTask?.cancel()
            successDismissTask = nil
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
        statusView(
            title: "Connecting to Twitch…",
            description: "Requesting a device code from Twitch."
        )
    }

    private func statusView(title: String, description: String) -> some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)

            VStack(spacing: 6) {
                Text(title)
                    .font(.headline)

                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous))

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
        statusView(
            title: "Waiting for confirmation…",
            description: "Complete the authorization in your browser."
        )
    }

    // MARK: - Success

    private var successView: some View {
        VStack(alignment: .leading, spacing: 14) {
            AnimatedStatusIcon(symbol: "checkmark.circle.fill", color: .green, size: 48)
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

            Text(failureTitle(for: message))
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
            if isSuccessState {
                Spacer()

                Button(successActionTitle) {
                    dismissSuccessState()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") {
                    loginService.cancel()
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()
            }
        }
    }

    private var isSuccessState: Bool {
        if case .succeeded = loginService.state {
            return true
        }
        return false
    }

    private var successActionTitle: String {
        "Done"
    }

    private func dismissSuccessState() {
        successDismissTask?.cancel()
        successDismissTask = nil
        isPresented = false
    }

    private func failureTitle(for message: String) -> String {
        message.localizedCaseInsensitiveContains("already added")
            ? "Account Not Added"
            : "Authentication Failed"
    }

    // MARK: - Handlers

    private func handleSuccess(account: Account) {
        successDismissTask?.cancel()

        // Ensure MinerManager uses the correct client ID when creating the engine.
        // This matters when the client ID was supplied via Settings rather than env var.
        navigation.minerManager.updateClientId(Settings.shared.resolvedClientId)

        let minerId: String
        do {
            minerId = try navigation.minerManager.addAccount(account)
        } catch {
            loginService.fail(message: error.localizedDescription)
            return
        }

        Task {
            let settings = Settings.shared
            try? await navigation.minerManager.startMiner(
                minerId: minerId,
                priorityGames: settings.priorityGames,
                excludedGames: settings.excludedGames,
                strategy: settings.miningStrategy,
                enableBadgesEmotes: settings.enableBadgesEmotes,
                showClaimNotifications: settings.showClaimNotifications && settings.allowsOperatorNotifications(),
                avoidDuplicateStreams: settings.avoidDuplicateStreams,
                antiStallRecoveryEnabled: settings.antiStallRecoveryEnabled,
                prioritiseFollowedStreamers: settings.prioritiseFollowedStreamers
            )
        }

        successDismissTask = Task {
            // Brief pause so the user sees the success state.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                dismissSuccessState()
            }
        }
    }
}

// MARK: - Preview

#Preview {
    AuthRequiredSheet(isPresented: .constant(true))
        .environment(NavigationModel(clientId: "preview"))
}
