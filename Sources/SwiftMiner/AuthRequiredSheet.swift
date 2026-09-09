import SwiftUI
import SwiftMinerCore

enum AdditionalAccountSetup {
    static func shouldPresentChoice(existingAccountCount: Int, isReconnecting: Bool) -> Bool {
        existingAccountCount > 0 && !isReconnecting
    }

    static func inviterName(accounts: [(name: String, isOperator: Bool)]) -> String {
        let account = accounts.first(where: \.isOperator) ?? accounts.first
        let name = account?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "A friend" : name
    }

    static func remainingSeconds(expiresAt: Date, now: Date) -> Int {
        max(0, Int(ceil(expiresAt.timeIntervalSince(now))))
    }

    static func countdownText(remainingSeconds: Int) -> String {
        let seconds = max(0, remainingSeconds)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private enum AccountAddSheetStage: Equatable {
    case choice
    case localOverview
    case friendOverview
    case friendActivation
    case authentication
}

/// Sheet for adding a new Twitch account via device-code OAuth.
///
/// Presented from `ContentView` at the `NavigationSplitView` level so that
/// macOS List selection never interferes with sheet presentation.
struct AuthRequiredSheet: View {
    @Binding var isPresented: Bool
    let reconnectingMinerId: String?
    @Environment(NavigationModel.self) private var navigation

    @State private var stage: AccountAddSheetStage
    @State private var loginService = MinerLoginService()
    @State private var successDismissTask: Task<Void, Never>?
    @State private var copiedCode = false
    @Environment(\.colorScheme) private var colorScheme

    private let sheetCornerRadius: CGFloat = 18

    private var sheetShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: sheetCornerRadius, style: .continuous)
    }

    init(
        isPresented: Binding<Bool>,
        reconnectingMinerId: String?,
        existingAccountCount: Int
    ) {
        _isPresented = isPresented
        self.reconnectingMinerId = reconnectingMinerId
        _stage = State(initialValue: AdditionalAccountSetup.shouldPresentChoice(
            existingAccountCount: existingAccountCount,
            isReconnecting: reconnectingMinerId != nil
        ) ? .choice : .authentication)
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
            startDeviceAuthIfNeeded()
        }
        .onChange(of: loginService.state) { _, newState in
            if case .succeeded(let account) = newState {
                handleSuccess(account: account)
            }
        }
        .onDisappear {
            successDismissTask?.cancel()
            successDismissTask = nil
            loginService.cancel()
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

                Image(systemName: headerSymbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)
            .shadow(color: Color.purple.opacity(0.24), radius: 10, y: 5)

            VStack(alignment: .leading, spacing: 7) {
                Text(headerTitle)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(headerSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentArea: some View {
        switch stage {
        case .choice:
            accountPurposeChoice
        case .localOverview:
            localSetupOverview
        case .friendOverview:
            friendSetupOverview
        case .friendActivation:
            friendActivationContent
        case .authentication:
            authenticationContent
        }
    }

    @ViewBuilder
    private var authenticationContent: some View {
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
            failureView(message: message, opensBrowserOnRetry: true)
        }
    }

    private var headerTitle: String {
        switch stage {
        case .choice: return "Add Another Account"
        case .localOverview: return "Set Up on This Mac"
        case .friendOverview: return "Share With a Friend"
        case .friendActivation: return "Share Invitation"
        case .authentication:
            return reconnectingMinerId == nil ? "Add Twitch Account" : "Reconnect Twitch Account"
        }
    }

    private var headerSubtitle: String {
        switch stage {
        case .choice:
            return "Choose who will connect the next Twitch account."
        case .localOverview:
            return "You will approve the account in Twitch, and this Mac will run its miner."
        case .friendOverview:
            return "Create a temporary SwiftMiner invitation they can open on their own device."
        case .friendActivation:
            return "Share the invitation, then keep this window open while SwiftMiner waits for approval."
        case .authentication:
            return reconnectingMinerId == nil
                ? "SwiftMiner opens Twitch in your browser, then finishes here as soon as the account is approved."
                : "SwiftMiner opens Twitch in your browser, then resumes this miner as soon as the account is approved."
        }
    }

    private var headerSymbol: String {
        switch stage {
        case .choice: return "person.2.fill"
        case .localOverview: return "desktopcomputer"
        case .friendOverview: return "square.and.arrow.up"
        case .friendActivation: return "envelope.open.fill"
        case .authentication: return "tv.fill"
        }
    }

    // MARK: - Additional account setup

    private var accountPurposeChoice: some View {
        VStack(spacing: 14) {
            setupChoice(
                title: "Set up on this Mac",
                detail: "Sign in to another Twitch account here and start mining on this device.",
                symbol: "desktopcomputer"
            ) {
                stage = .localOverview
            }

            setupChoice(
                title: "Share with a friend",
                detail: "Send a temporary SwiftMiner invitation so they can connect their account from their own device.",
                symbol: "person.crop.circle.badge.plus"
            ) {
                stage = .friendOverview
            }

            Text("No Discord integration or Web Dashboard is required.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func setupChoice(
        title: String,
        detail: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color.purple)
                    .frame(width: 46, height: 46)
                    .background(Color.purple.opacity(0.11), in: RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial.opacity(0.72), in: RoundedRectangle(cornerRadius: GlassRadius.large, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: GlassRadius.large, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var localSetupOverview: some View {
        setupOverview(
            steps: [
                ("1", "Check the Twitch account", "Your browser may already be signed in. Switch accounts there before approving if needed."),
                ("2", "Approve SwiftMiner", "Twitch shows a short activation code and asks you to confirm access."),
                ("3", "Mining starts here", "The new account gets its own miner and can use its own priorities.")
            ],
            note: "This takes about a minute. SwiftMiner never asks you to type a Twitch password into the app."
        )
    }

    private var friendSetupOverview: some View {
        setupOverview(
            steps: [
                ("1", "SwiftMiner creates an invitation", "The private setup link is temporary and is only used to connect the next account."),
                ("2", "Share it with your friend", "Use the macOS share sheet to send it through Messages, Mail, AirDrop, or another app."),
                ("3", "They connect with Twitch", "The SwiftMiner page guides them while this Mac waits, then adds their account automatically.")
            ],
            note: "Send the invitation only to the intended person. Anyone with the temporary link can connect the next Twitch account until it expires."
        )
    }

    @ViewBuilder
    private var friendActivationContent: some View {
        switch loginService.state {
        case .idle, .starting:
            statusView(
                title: "Creating setup link…",
                description: "Requesting a temporary activation code from Twitch."
            )
        case .waitingForUser(let code, _, let expiresIn):
            sharedSetupReadyView(
                code: code,
                expiresAt: loginService.deviceAuthorization?.expiresAt
                    ?? Date().addingTimeInterval(TimeInterval(expiresIn))
            )
        case .polling:
            if let authorization = loginService.deviceAuthorization {
                sharedSetupReadyView(
                    code: authorization.code,
                    expiresAt: authorization.expiresAt
                )
            } else {
                statusView(title: "Creating setup link…", description: "Waiting for Twitch to return an activation code.")
            }
        case .succeeded:
            successView
        case .failed(let message):
            if message.localizedCaseInsensitiveContains("expired"),
               let authorization = loginService.deviceAuthorization {
                sharedSetupReadyView(
                    code: authorization.code,
                    expiresAt: authorization.expiresAt
                )
            } else {
                failureView(message: message, opensBrowserOnRetry: false)
            }
        }
    }

    private func sharedSetupReadyView(
        code: String,
        expiresAt: Date
    ) -> some View {
        let invitation = SwiftMinerInvitation(
            inviterName: setupInviterName,
            deviceCode: code,
            expiresAt: expiresAt
        )

        return TimelineView(.periodic(from: .now, by: 1)) { context in
            let remainingSeconds = AdditionalAccountSetup.remainingSeconds(
                expiresAt: expiresAt,
                now: context.date
            )
            let isExpired = remainingSeconds == 0

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(isExpired ? "Invitation expired" : "Invitation is ready")
                                .font(.headline)
                            Text(isExpired
                                ? "Code \(code) can no longer be used"
                                : "Code \(code) · \(AdditionalAccountSetup.countdownText(remainingSeconds: remainingSeconds)) remaining")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: isExpired ? "clock.badge.exclamationmark.fill" : "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(isExpired ? Color.orange : Color.green)
                    }

                    if isExpired {
                        Button(action: sendFriendSetupAgain) {
                            Label("Send Again", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    } else {
                        ShareLink(
                            item: invitation.invitationURL,
                            subject: Text(invitation.subject),
                            message: Text(invitation.plainText)
                        ) {
                            Label("Share Invitation…", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                }
                .padding(16)
                .background(.thinMaterial.opacity(0.72), in: RoundedRectangle(cornerRadius: GlassRadius.large, style: .continuous))

                HStack(spacing: 12) {
                    if isExpired {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.orange)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isExpired ? "Ready to try again" : "Waiting for your friend")
                            .font(.callout.weight(.medium))
                        Text(isExpired
                            ? "Send Again creates a fresh 30-minute invitation for your friend."
                            : "Keep this window open. Their miner appears automatically after they approve SwiftMiner in Twitch.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .background(
                    (isExpired ? Color.orange : Color.green).opacity(0.08),
                    in: RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous)
                )

                Text("The invitation shares no password, Twitch token, Discord account, or Web Dashboard access.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func sendFriendSetupAgain() {
        loginService.cancel()
        loginService.startDeviceAuth(opensBrowser: false)
    }

    private func setupOverview(
        steps: [(String, String, String)],
        note: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            ForEach(Array(steps.enumerated()), id: \.offset) { entry in
                let step = entry.element
                HStack(alignment: .top, spacing: 12) {
                    Text(step.0)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Color.purple, in: Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.1)
                            .font(.callout.weight(.semibold))
                        Text(step.2)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous))
        }
        .padding(16)
        .background(.thinMaterial.opacity(0.72), in: RoundedRectangle(cornerRadius: GlassRadius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GlassRadius.large, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
    }

    private var setupInviterName: String {
        AdditionalAccountSetup.inviterName(accounts: navigation.minerManager.miners.map {
            (name: $0.username, isOperator: $0.isOperator)
        })
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
            Text(reconnectingMinerId == nil ? "Account Added!" : "Twitch Reconnected!")
                .font(.title3.weight(.semibold))
            Text(reconnectingMinerId == nil
                ? "Your Twitch account has been connected."
                : "Your Twitch credentials have been refreshed and mining will resume.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Failure

    private func failureView(message: String, opensBrowserOnRetry: Bool) -> some View {
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
                loginService.startDeviceAuth(opensBrowser: opensBrowserOnRetry)
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
            } else if stage == .localOverview {
                Button("Back") {
                    stage = .choice
                }

                Spacer()

                Button("Continue") {
                    stage = .authentication
                    startDeviceAuthIfNeeded()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else if stage == .friendOverview {
                Button("Back") {
                    stage = .choice
                }

                Spacer()

                Button("Create Setup Link") {
                    stage = .friendActivation
                    loginService.startDeviceAuth(opensBrowser: false)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else if stage == .friendActivation {
                Button("Cancel Setup") {
                    loginService.cancel()
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()
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

    private func startDeviceAuthIfNeeded() {
        guard stage == .authentication else { return }
        guard case .idle = loginService.state else { return }
        loginService.startDeviceAuth()
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

        if let reconnectingMinerId {
            Task {
                do {
                    try await navigation.minerManager.replaceAuthentication(
                        for: reconnectingMinerId,
                        with: account
                    )
                    let settings = Settings.shared
                    try await navigation.minerManager.startMiner(
                        minerId: reconnectingMinerId,
                        priorityGames: settings.priorityGames(forAccountId: account.id),
                        excludedGames: settings.excludedGames(forAccountId: account.id),
                        strategy: settings.miningStrategy,
                        enableBadgesEmotes: settings.enableBadgesEmotes,
                        showClaimNotifications: settings.showClaimNotifications && settings.allowsOperatorNotifications(),
                        avoidDuplicateStreams: settings.avoidDuplicateStreams,
                        antiStallRecoveryEnabled: settings.antiStallRecoveryEnabled,
                        prioritiseFollowedStreamers: settings.prioritiseFollowedStreamers,
                        failoverStreamers: settings.gameFailoverStreamers
                    )
                    scheduleSuccessDismissal()
                } catch {
                    loginService.fail(message: error.localizedDescription)
                }
            }
            return
        }

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
                excludedGames: settings.excludedGames(forAccountId: account.id),
                strategy: settings.miningStrategy,
                enableBadgesEmotes: settings.enableBadgesEmotes,
                showClaimNotifications: settings.showClaimNotifications && settings.allowsOperatorNotifications(),
                avoidDuplicateStreams: settings.avoidDuplicateStreams,
                antiStallRecoveryEnabled: settings.antiStallRecoveryEnabled,
                prioritiseFollowedStreamers: settings.prioritiseFollowedStreamers,
                failoverStreamers: settings.gameFailoverStreamers
            )
        }

        scheduleSuccessDismissal()
    }

    private func scheduleSuccessDismissal() {
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
    AuthRequiredSheet(
        isPresented: .constant(true),
        reconnectingMinerId: nil,
        existingAccountCount: 1
    )
        .environment(NavigationModel(clientId: "preview"))
}
