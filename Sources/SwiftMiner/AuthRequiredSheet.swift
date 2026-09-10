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

private enum InvitationDeliveryRoute: Equatable {
    case manual
    case swiftBot
}

/// Sheet for adding a new Twitch account via device-code OAuth.
///
/// Presented from `ContentView` at the `NavigationSplitView` level so that
/// macOS List selection never interferes with sheet presentation.
///
/// The layout follows SwiftMiner's macOS 26 settings language: one quiet content
/// layer, generously rounded grouped surfaces, and system controls. The sheet
/// supplies no material of its own, leaving its Liquid Glass appearance to
/// SwiftUI and macOS.
struct AuthRequiredSheet: View {
    @Binding var isPresented: Bool
    let reconnectingMinerId: String?
    @Environment(NavigationModel.self) private var navigation

    @State private var stage: AccountAddSheetStage
    @State private var loginService = MinerLoginService()
    @State private var successDismissTask: Task<Void, Never>?
    @State private var copiedCode = false
    @State private var swiftBotInvitation: SwiftMinerInvitation?
    @State private var mailFailureMessage: String?
    @State private var connectedAvatarURL: URL?
    @State private var invitationDeliveryRoute: InvitationDeliveryRoute = .manual
    @State private var shouldPresentSwiftBotPickerWhenReady = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var settings: Settings { .shared }

    private let sheetWidth: CGFloat = 520

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
        Group {
            if let invitation = swiftBotInvitation {
                SwiftBotInvitationSheet(
                    invitation: invitation,
                    onCancel: { swiftBotInvitation = nil },
                    onSent: { swiftBotInvitation = nil }
                )
            } else {
                sheetContent
            }
        }
        .frame(width: sheetWidth)
        .fixedSize(horizontal: false, vertical: true)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: stage)
        .onAppear {
            startDeviceAuthIfNeeded()
        }
        .onChange(of: loginService.state) { _, newState in
            if case .succeeded(let account) = newState {
                handleSuccess(account: account)
                loadConnectedAvatar(for: account)
            } else {
                presentSwiftBotPickerIfReady()
            }
        }
        .onDisappear {
            successDismissTask?.cancel()
            successDismissTask = nil
            loginService.cancel()
        }
    }

    private var sheetContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            contentArea
            footerBar
        }
        .padding(24)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: headerSymbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 42, height: 42)
                .background(.tint.opacity(0.10), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(headerTitle)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(headerSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var headerTitle: String {
        if isSuccessState {
            return reconnectingMinerId == nil ? "Account Connected" : "Twitch Reconnected"
        }
        switch stage {
        case .choice: return "Add Account"
        case .localOverview: return "On This Mac"
        case .friendOverview: return "Invite Someone"
        case .friendActivation: return invitationIsReady ? "Invitation Ready" : "Creating Invitation"
        case .authentication:
            return reconnectingMinerId == nil ? "Connect Twitch" : "Reconnect Twitch"
        }
    }

    private var headerSymbol: String {
        if isSuccessState { return "checkmark.circle.fill" }
        switch stage {
        case .choice: return "person.crop.circle.badge.plus"
        case .localOverview: return "desktopcomputer"
        case .friendOverview: return "person.badge.plus"
        case .friendActivation: return invitationIsReady ? "link" : "clock"
        case .authentication: return "person.crop.circle.badge.checkmark"
        }
    }

    private var headerSubtitle: String {
        if isSuccessState {
            return reconnectingMinerId == nil
                ? "The account is set up and mining starts automatically."
                : "Credentials have been refreshed and mining will resume."
        }
        switch stage {
        case .choice:
            return "Choose how to connect the next Twitch account."
        case .localOverview:
            return "You'll approve the account in Twitch, and this Mac will run its miner."
        case .friendOverview:
            return "They'll connect their Twitch account from their device. SwiftMiner will add it automatically once they're done."
        case .friendActivation:
            return invitationIsReady
                ? "Send it however suits them. This Mac keeps waiting until they connect."
                : "Asking Twitch for a temporary activation code."
        case .authentication:
            return reconnectingMinerId == nil
                ? "Approve SwiftMiner in Twitch to finish adding the account."
                : "Approve SwiftMiner in Twitch to restore this miner."
        }
    }

    /// True once the device code exists, which is what turns "Creating
    /// Invitation" into the shareable "Invitation Ready" state.
    private var invitationIsReady: Bool {
        switch loginService.state {
        case .waitingForUser, .polling: return true
        case .failed: return loginService.deviceAuthorization != nil
        default: return false
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentArea: some View {
        switch stage {
        case .choice:
            addMinerChoice
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

    // MARK: - Screen 1 · Add Miner

    private var addMinerChoice: some View {
        SheetGroupedRows {
            SheetSelectionRow(
                symbol: "desktopcomputer",
                title: "Set Up on This Mac",
                detail: "Sign in to another Twitch account on this Mac."
            ) {
                stage = .localOverview
            }

            TahoeRowDivider(leadingInset: 58)

            SheetSelectionRow(
                symbol: "square.and.arrow.up",
                title: "Send It to Them",
                detail: "Create an invitation to send with Mail, Messages or AirDrop."
            ) {
                invitationDeliveryRoute = .manual
                stage = .friendOverview
            }

            if settings.swiftBotEnabled {
                TahoeRowDivider(leadingInset: 58)

                SheetSelectionRow(
                    symbol: "paperplane.fill",
                    title: "Invite via SwiftBot",
                    detail: swiftBotChoiceDetail
                ) {
                    invitationDeliveryRoute = .swiftBot
                    stage = .friendActivation
                    shouldPresentSwiftBotPickerWhenReady = true
                    loginService.startDeviceAuth(opensBrowser: false)
                }
                .disabled(navigation.swiftBotState != .connected)
            }
        }
    }

    private var swiftBotChoiceDetail: String {
        switch navigation.swiftBotState {
        case .connected:
            return "Choose someone from your connected Discord server."
        case .disconnected:
            return "SwiftBot is enabled but currently unavailable."
        case .unpaired:
            return "Finish pairing SwiftBot in Settings first."
        case .notConfigured:
            return "Finish setting up SwiftBot in Settings first."
        }
    }

    // MARK: - Screen 2 · Overviews

    private var localSetupOverview: some View {
        return stepList(
            steps: [
                ("Check the Twitch account", "Your browser may already be signed in — switch accounts there first if needed."),
                ("Approve SwiftMiner", "Twitch shows a short activation code and asks you to confirm access."),
                ("Mining starts here", "The new account gets its own miner and its own priorities.")
            ],
            note: "SwiftMiner never asks you to type a Twitch password into the app."
        )
    }

    private var friendSetupOverview: some View {
        let deliveryStep = invitationDeliveryRoute == .swiftBot
            ? ("Choose someone", "Select one person from your Discord server.")
            : ("Send it to them", "Use Mail, Messages or AirDrop.")

        return stepList(
            steps: [
                ("Create an invitation", "A temporary link is generated."),
                deliveryStep,
                ("They connect Twitch", "Their account appears automatically.")
            ],
            note: "The invitation expires after 30 minutes and can only connect one account."
        )
    }

    private func stepList(steps: [(String, String)], note: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SheetGroupedRows {
            ForEach(Array(steps.enumerated()), id: \.offset) { entry in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(entry.offset + 1)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.tint)
                        .frame(width: 26, height: 26)
                        .background(.tint.opacity(0.10), in: Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.element.0)
                            .font(.body.weight(.medium))
                        Text(entry.element.1)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)

                if entry.offset < steps.count - 1 {
                    TahoeRowDivider(leadingInset: 52)
                }
            }
            }

            Text(note)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Screen 3 · Invitation

    @ViewBuilder
    private var friendActivationContent: some View {
        switch loginService.state {
        case .idle, .starting:
            inlineProgress("Creating the invitation…")
        case .waitingForUser(let code, _, let expiresIn):
            invitationReadyView(
                code: code,
                expiresAt: loginService.deviceAuthorization?.expiresAt
                    ?? Date().addingTimeInterval(TimeInterval(expiresIn))
            )
        case .polling:
            if let authorization = loginService.deviceAuthorization {
                invitationReadyView(code: authorization.code, expiresAt: authorization.expiresAt)
            } else {
                inlineProgress("Creating the invitation…")
            }
        case .succeeded(let account):
            connectedSummary(username: account.username)
        case .failed(let message):
            if let authorization = loginService.deviceAuthorization,
               message.localizedCaseInsensitiveContains("expired") {
                invitationReadyView(code: authorization.code, expiresAt: authorization.expiresAt)
            } else {
                failureView(message: message, opensBrowserOnRetry: false)
            }
        }
    }

    private func invitationReadyView(code: String, expiresAt: Date) -> some View {
        let invitation = SwiftMinerInvitation(
            inviterName: setupInviterName,
            deviceCode: code,
            expiresAt: expiresAt
        )

        // One timeline drives both the countdown and the switch to the expired
        // state, so the sharing options cannot outlive the invitation.
        return TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = AdditionalAccountSetup.remainingSeconds(expiresAt: expiresAt, now: context.date)

            VStack(alignment: .leading, spacing: 18) {
                invitationSummary(code: code, remainingSeconds: remaining)

                if remaining == 0 {
                    Button("Create a New Invitation", action: sendFriendSetupAgain)
                        .controlSize(.large)
                } else {
                    sharingOptions(invitation: invitation)
                }

                if let mailFailureMessage {
                    Label(mailFailureMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if remaining > 0 {
                    waitingRow
                }
            }
        }
    }

    /// Code and countdown carry the weight here, so neither needs a container.
    /// The countdown is monospaced-digit so ticking never shifts the layout.
    private func invitationSummary(code: String, remainingSeconds: Int) -> some View {
        let expired = remainingSeconds == 0
        return HStack(spacing: 8) {
            Image(systemName: expired ? "clock.badge.exclamationmark" : "checkmark.circle.fill")
                .foregroundStyle(expired ? .orange : .green)
                .imageScale(.large)
                .accessibilityHidden(true)

            Text(code)
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .textSelection(.enabled)

            Text("·")
                .foregroundStyle(.tertiary)

            Text(expired
                 ? "Expired"
                 : "Expires in \(AdditionalAccountSetup.countdownText(remainingSeconds: remainingSeconds))")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button {
                copyCode(code)
            } label: {
                Image(systemName: copiedCode ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy the activation code")
            .accessibilityLabel(copiedCode ? "Code copied" : "Copy activation code")
        }
        .padding(14)
        .tahoeCard(tint: expired ? .orange.opacity(0.05) : .green.opacity(0.05))
        .accessibilityElement(children: .contain)
    }

    private func sharingOptions(invitation: SwiftMinerInvitation) -> some View {
        SheetGroupedRows {
            SheetSelectionRow(
                symbol: "envelope",
                title: "Mail",
                detail: "Open in Mail"
            ) {
                composeMailInvitation(invitation)
            }

            TahoeRowDivider(leadingInset: 58)

            InvitationShareButton(invitation: invitation) {
                SheetSelectionRowLabel(
                    symbol: "square.and.arrow.up",
                    title: "Share…",
                    detail: "Messages, AirDrop and other apps"
                )
            }
            .buttonStyle(SheetSelectionRowStyle())

            if navigation.swiftBotState == .connected {
                TahoeRowDivider(leadingInset: 58)

                SheetSelectionRow(
                    symbol: "person.crop.circle.badge.checkmark",
                    title: "SwiftBot",
                    detail: "Send to someone on your Discord server"
                ) {
                    swiftBotInvitation = invitation
                }
            }
        }
    }

    /// The connection status lives below the sharing options and becomes the
    /// connected account in place, so the sheet never has to change screens for
    /// the thing the user is already waiting on.
    @ViewBuilder
    private var waitingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)

            Text("Waiting for them to connect…")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func connectedSummary(username: String) -> some View {
        let displayName = username.hasPrefix("@") ? username : "@\(username)"
        return HStack(spacing: 12) {
            CachedAvatarImage(url: connectedAvatarURL) {
                Circle()
                    .fill(.quaternary)
                    .overlay {
                        Text(username.prefix(1).uppercased())
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 40, height: 40)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.body.weight(.medium))
                Text(stage == .friendActivation ? "Added to SwiftMiner" : "Connected to SwiftMiner")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            AnimatedStatusIcon(symbol: "checkmark.circle.fill", color: .green, size: 22)
                .accessibilityHidden(true)
        }
        .padding(14)
        .tahoeCard(tint: .green.opacity(0.05))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(displayName) added to SwiftMiner")
    }

    // MARK: - Twitch device-code flow

    @ViewBuilder
    private var authenticationContent: some View {
        switch loginService.state {
        case .idle, .starting:
            inlineProgress("Requesting a device code from Twitch…")
        case .waitingForUser(let code, let url, let expiresIn):
            waitingView(code: code, url: url, expiresIn: expiresIn)
        case .polling:
            inlineProgress("Waiting for you to approve SwiftMiner in Twitch…")
        case .succeeded(let account):
            connectedSummary(username: account.username)
        case .failed(let message):
            failureView(message: message, opensBrowserOnRetry: true)
        }
    }

    private func waitingView(code: String, url: URL, expiresIn: Int) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Enter this code on Twitch")
                    .font(.body.weight(.medium))

                HStack(spacing: 10) {
                    Text(code)
                        .font(.system(.title, design: .monospaced).weight(.semibold))
                        .tracking(4)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .textSelection(.enabled)

                    Button {
                        copyCode(code)
                    } label: {
                        Image(systemName: copiedCode ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy the activation code")
                    .accessibilityLabel(copiedCode ? "Code copied" : "Copy activation code")

                    Spacer(minLength: 0)
                }

                Text("Expires in \(max(expiresIn / 60, 1)) minutes")
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .tahoeCard()

            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Label("Open Twitch Activation Page", systemImage: "safari")
            }
            .buttonStyle(.borderedProminent)

            waitingConfirmationRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var waitingConfirmationRow: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Waiting for Twitch to confirm…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func inlineProgress(_ title: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func failureView(message: String, opensBrowserOnRetry: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(failureTitle(for: message))
                        .font(.body.weight(.medium))
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            Button("Try Again") {
                loginService.cancel()
                loginService.startDeviceAuth(opensBrowser: opensBrowserOnRetry)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .tahoeCard(tint: .orange.opacity(0.05))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 12) {
            switch footerLayout {
            case .success:
                Spacer()
                Button("Done") { dismissSuccessState() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)

            case .overview(let backStage, let continueTitle, let continueAction):
                Button {
                    stage = backStage
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(continueTitle, action: continueAction)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)

            case .cancelOnly:
                Spacer()
                Button("Cancel") {
                    loginService.cancel()
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .controlSize(.regular)
    }

    private enum FooterLayout {
        case success
        case overview(back: AccountAddSheetStage, continueTitle: String, action: () -> Void)
        case cancelOnly
    }

    private var footerLayout: FooterLayout {
        if isSuccessState { return .success }
        switch stage {
        case .localOverview:
            return .overview(back: .choice, continueTitle: "Continue") {
                stage = .authentication
                startDeviceAuthIfNeeded()
            }
        case .friendOverview:
            return .overview(back: .choice, continueTitle: "Create Invitation") {
                stage = .friendActivation
                shouldPresentSwiftBotPickerWhenReady = invitationDeliveryRoute == .swiftBot
                loginService.startDeviceAuth(opensBrowser: false)
            }
        default:
            return .cancelOnly
        }
    }

    private var isSuccessState: Bool {
        if case .succeeded = loginService.state { return true }
        return false
    }

    // MARK: - Actions

    private func composeMailInvitation(_ invitation: SwiftMinerInvitation) {
        mailFailureMessage = nil
        Task {
            do {
                try await MailInvitationComposer.composeDraft(for: invitation)
            } catch let failure as MailInvitationComposer.Failure {
                mailFailureMessage = failure.message
            }
        }
    }

    private func sendFriendSetupAgain() {
        mailFailureMessage = nil
        shouldPresentSwiftBotPickerWhenReady = invitationDeliveryRoute == .swiftBot
        loginService.cancel()
        loginService.startDeviceAuth(opensBrowser: false)
    }

    private func presentSwiftBotPickerIfReady() {
        guard shouldPresentSwiftBotPickerWhenReady,
              stage == .friendActivation,
              let authorization = loginService.deviceAuthorization
        else { return }

        shouldPresentSwiftBotPickerWhenReady = false
        swiftBotInvitation = SwiftMinerInvitation(
            inviterName: setupInviterName,
            deviceCode: authorization.code,
            expiresAt: authorization.expiresAt
        )
    }

    private var setupInviterName: String {
        AdditionalAccountSetup.inviterName(accounts: navigation.minerManager.miners.map {
            (name: $0.username, isOperator: $0.isOperator)
        })
    }

    /// Best effort — the connected row falls back to the account's initial while
    /// this resolves, or if Twitch has no picture for them.
    private func loadConnectedAvatar(for account: Account) {
        connectedAvatarURL = TwitchAvatarStore.shared.url(forAccountId: account.id)
        Task {
            guard let miner = navigation.minerManager.miners.first(where: { $0.accountId == account.id })
            else { return }
            await TwitchAvatarStore.shared.refresh(miner: miner, manager: navigation.minerManager)
            connectedAvatarURL = TwitchAvatarStore.shared.url(forAccountId: account.id)
        }
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
        // The invite flow shows the connected account in place of the waiting
        // row, so it stays put until the user is done looking at it.
        guard stage != .friendActivation else { return }
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

// MARK: - Grouped sheet rows

/// Uses the same content surface as Settings. Liquid Glass stays in the control
/// layer supplied by macOS instead of being painted behind every row.
private struct SheetGroupedRows<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .clipShape(RoundedRectangle(cornerRadius: TahoeMetrics.card, style: .continuous))
        .tahoeCard()
    }
}

/// The visual half of a selection row, so a plain button and a `ShareLink`-style
/// control can present the same way.
private struct SheetSelectionRowLabel: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
                .background(.tint.opacity(0.10), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Restrained hover feedback across the whole row, and a focus ring for keyboard
/// navigation — both from the system rather than drawn by hand.
private struct SheetSelectionRowStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if configuration.isPressed {
                    Color.accentColor.opacity(0.10)
                } else if isHovering {
                    Color.accentColor.opacity(0.055)
                }
            }
            .onHover { isHovering = $0 }
    }
}

private struct SheetSelectionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SheetSelectionRowLabel(symbol: symbol, title: title, detail: detail)
        }
        .buttonStyle(SheetSelectionRowStyle())
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }
}
