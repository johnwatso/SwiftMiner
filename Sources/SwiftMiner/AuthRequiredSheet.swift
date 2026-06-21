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
    @State private var copiedCode = false
    @Environment(\.colorScheme) private var colorScheme

    private let sheetCornerRadius: CGFloat = 18

    private var sheetShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: sheetCornerRadius, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            headerSection
            contentArea
            footerBar
        }
        .frame(width: 540, height: 500)
        .padding(30)
        .background {
            sheetShape
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.96))
                .overlay {
                    LinearGradient(
                        colors: [
                            Color.purple.opacity(colorScheme == .dark ? 0.16 : 0.10),
                            Color.indigo.opacity(colorScheme == .dark ? 0.10 : 0.06),
                            Color(nsColor: .windowBackgroundColor).opacity(0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(sheetShape)
                }
                .overlay {
                    sheetShape
                        .fill(.ultraThinMaterial.opacity(0.28))
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
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: GlassRadius.large, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.57, green: 0.28, blue: 1.0),
                                Color(red: 0.36, green: 0.18, blue: 0.88)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Image(systemName: "tv.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)
            .shadow(color: Color.purple.opacity(0.24), radius: 10, y: 5)

            VStack(alignment: .leading, spacing: 7) {
                Text("Add Twitch Account")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)

                Text("SwiftMiner opens Twitch in your browser, then finishes here as soon as the account is approved.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            ZStack {
                RoundedRectangle(cornerRadius: GlassRadius.large, style: .continuous)
                    .fill(Color.purple.opacity(0.12))
                    .frame(width: 72, height: 72)

                ProgressView()
                    .controlSize(.large)
            }

            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))

                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Waiting for user

    private func waitingView(code: String, url: URL, expiresIn: Int) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            stepRow(
                number: "1",
                title: "Open Twitch",
                detail: "Use the activation page in your browser."
            ) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open Activation Page", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            stepRow(
                number: "2",
                title: "Enter the code",
                detail: "Paste this code on Twitch to approve SwiftMiner."
            ) {
                codePanel(code: code, expiresIn: expiresIn)
            }

            waitingStatusPanel
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func stepRow<Content: View>(
        number: String,
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number)
                .font(.callout.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.purple, in: Circle())

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)

                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                content()
            }
        }
        .padding(14)
        .background(.thinMaterial.opacity(0.72), in: RoundedRectangle(cornerRadius: GlassRadius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GlassRadius.large, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
    }

    private func codePanel(code: String, expiresIn: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Text(code)
                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                    .tracking(5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .textSelection(.enabled)

                Spacer(minLength: 12)

                Button {
                    copyCode(code)
                } label: {
                    Label(copiedCode ? "Copied" : "Copy", systemImage: copiedCode ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("Copy code")
            }

            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .foregroundStyle(.tertiary)
                Text("Expires in \(max(expiresIn / 60, 1)) minutes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.34), in: RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous)
                .strokeBorder(Color.purple.opacity(0.20), lineWidth: 1)
        }
    }

    private var waitingStatusPanel: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)

            VStack(alignment: .leading, spacing: 2) {
                Text("Waiting for confirmation")
                    .font(.callout.weight(.medium))
                Text("This sheet closes automatically after Twitch approves the login.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous)
                .strokeBorder(Color.green.opacity(0.16), lineWidth: 1)
        }
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
        VStack(spacing: 16) {
            AnimatedStatusIcon(symbol: "checkmark.circle.fill", color: .green, size: 48)
            Text("Account Added!")
                .font(.title3.weight(.semibold))
            Text("Your Twitch account has been connected.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Failure

    private func failureView(message: String) -> some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: GlassRadius.large, style: .continuous)
                    .fill(Color.orange.opacity(0.14))
                    .frame(width: 72, height: 72)

                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.orange)
            }

            Text(failureTitle(for: message))
                .font(.title3.weight(.semibold))

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("Try Again") {
                loginService.cancel()
                loginService.startDeviceAuth()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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

    private func copyCode(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)

        copiedCode = true
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                copiedCode = false
            }
        }
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
                priorityGames: settings.priorityGames(forAccountId: account.id),
                excludedGames: settings.excludedGames,
                strategy: settings.miningStrategy,
                enableBadgesEmotes: settings.enableBadgesEmotes,
                showClaimNotifications: settings.showClaimNotifications && settings.allowsOperatorNotifications(),
                avoidDuplicateStreams: settings.avoidDuplicateStreams,
                antiStallRecoveryEnabled: settings.antiStallRecoveryEnabled,
                prioritiseFollowedStreamers: settings.prioritiseFollowedStreamers,
                failoverStreamers: settings.gameFailoverStreamers
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
