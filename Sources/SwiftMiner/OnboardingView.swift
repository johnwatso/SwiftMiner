import AppKit
import SwiftUI
import SwiftMinerCore

/// Optional onboarding surface that reflects current app readiness.
struct OnboardingView: View {
    @Environment(NavigationModel.self) private var navigation
    @State private var currentStepIndex = 0
    @State private var showAccountSuccessState = false

    private enum OnboardingStep: String, CaseIterable {
        case welcome
        case account
        case done
    }

    private var presentation: NavigationModel.OnboardingPresentation? {
        navigation.onboardingPresentation
    }

    private var steps: [OnboardingStep] { OnboardingStep.allCases }

    private var appIconImage: NSImage {
        if let image = NSApplication.shared.applicationIconImage.copy() as? NSImage {
            image.isTemplate = false
            return image
        }
        return NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }

    var body: some View {
        if let presentation {
            let stepIndex = clampedStepIndex
            let step = steps[stepIndex]

            VStack(alignment: .leading, spacing: 0) {
                topBar(step: stepIndex + 1, total: steps.count)
                    .padding(.bottom, 18)

                stepContentContainer(step: step, presentation: presentation)
                    .frame(maxWidth: .infinity, minHeight: 282, alignment: .topLeading)

                footer(stepIndex: stepIndex, totalSteps: steps.count, presentation: presentation)
                    .padding(.top, 22)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 20)
            .frame(width: 540)
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.regularMaterial)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.white.opacity(0.32), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 34, y: 18)
            .onAppear {
                navigation.refreshOnboardingPresentation()
                syncStep(with: navigation.onboardingPresentation)
            }
            .onChange(of: navigation.showAddAccountSheet) { _, isShowing in
                guard !isShowing else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    navigation.refreshOnboardingPresentation()
                }
            }
            .onChange(of: navigation.onboardingPresentation) { _, presentation in
                syncStep(with: presentation)
            }
        }
    }

    // MARK: - Layout

    private func topBar(step: Int, total: Int) -> some View {
        HStack(spacing: 12) {
            Text("STEP \(step) OF \(total)")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                dismissOnboarding()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Color.secondary.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Skip onboarding. You can finish setup later from Accounts or Settings.")
        }
    }

    private func stepContentContainer(
        step: OnboardingStep,
        presentation: NavigationModel.OnboardingPresentation
    ) -> some View {
        ScrollView(showsIndicators: false) {
            ZStack(alignment: .topLeading) {
                stepView(step: step, presentation: presentation)
                    .id(step.rawValue)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
            .frame(maxWidth: 484, alignment: .leading)
            .animation(.easeInOut(duration: 0.22), value: step)
        }
    }

    private func footer(
        stepIndex: Int,
        totalSteps: Int,
        presentation: NavigationModel.OnboardingPresentation
    ) -> some View {
        VStack(spacing: 14) {
            stepDots(stepIndex: stepIndex, totalSteps: totalSteps)

            HStack(spacing: 12) {
                Button("Skip") {
                    dismissOnboarding()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                if stepIndex > 0 {
                    Button("Back") {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            currentStepIndex = max(0, currentStepIndex - 1)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }

                Button(nextButtonTitle(stepIndex: stepIndex, totalSteps: totalSteps, presentation: presentation)) {
                    advance(stepIndex: stepIndex, totalSteps: totalSteps)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(isNextButtonDisabled(stepIndex: stepIndex, presentation: presentation))
            }
        }
        .frame(maxWidth: 484, alignment: .leading)
    }

    private func stepDots(stepIndex: Int, totalSteps: Int) -> some View {
        HStack(spacing: 7) {
            ForEach(0..<totalSteps, id: \.self) { index in
                Circle()
                    .fill(index == stepIndex ? Color.secondary.opacity(0.34) : Color.secondary.opacity(0.12))
                    .frame(width: 6, height: 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Step Content

    @ViewBuilder
    private func stepView(step: OnboardingStep, presentation: NavigationModel.OnboardingPresentation) -> some View {
        switch step {
        case .welcome:
            welcomeStep

        case .account:
            accountStep(presentation: presentation)

        case .done:
            doneStep(presentation: presentation)
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            OnboardingHeader(
                title: "Welcome to SwiftMiner",
                subtitle: "Set up mining in a minute. You can skip this now and adjust everything later."
            ) {
                Image(nsImage: appIconImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.16), radius: 8, y: 4)
            }

            OnboardingInsetGroup {
                OnboardingInfoRow(
                    symbol: "person.crop.circle.badge.plus",
                    tint: .blue,
                    title: "Connect Twitch",
                    subtitle: "Discover active drops for your account."
                )
                Divider()
                OnboardingInfoRow(
                    symbol: "rectangle.3.group",
                    tint: .purple,
                    title: "Open the dashboard",
                    subtitle: "Manage miners, drops, preferences, and alerts after setup."
                )
            }
        }
    }

    @ViewBuilder
    private func accountStep(presentation: NavigationModel.OnboardingPresentation) -> some View {
        let primaryMiner = navigation.minerManager.miners.first
        let hasConnectedAccount = {
            if case .hasAccounts = presentation.accountState { return true }
            return false
        }()

        VStack(alignment: .leading, spacing: 22) {
            OnboardingHeader(
                title: hasConnectedAccount ? "Account connected" : "Connect Twitch",
                subtitle: hasConnectedAccount ? "SwiftMiner is preparing your dashboard." : "Sign in once so SwiftMiner can find and mine eligible drops."
            ) {
                OnboardingSymbol(symbol: hasConnectedAccount ? "checkmark.circle.fill" : "person.crop.circle.badge.plus", tint: hasConnectedAccount ? .green : .blue)
            }

            VStack(alignment: .leading, spacing: 12) {
                switch presentation.accountState {
                case .noAccounts:
                    Button {
                        navigation.showAddAccountSheet = true
                    } label: {
                        Label("Connect Account", systemImage: "person.badge.key.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                case .hasAccounts(let count):
                    if let stage = presentation.setupStage {
                        OnboardingSetupProgressRow(stage: stage)
                    } else {
                        OnboardingInsetGroup {
                            if let miner = primaryMiner {
                                OnboardingConnectedAccountRow(username: miner.username, status: "Connected")
                            }

                            if count > 1 {
                                Divider()
                                Text("\(count) accounts connected")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 2)
                            }
                        }
                    }

                }
            }
            .scaleEffect(hasConnectedAccount ? (showAccountSuccessState ? 1.0 : 0.985) : 1.0, anchor: .topLeading)
            .opacity(hasConnectedAccount ? (showAccountSuccessState ? 1.0 : 0.0) : 1.0)
            .onAppear {
                guard hasConnectedAccount else {
                    showAccountSuccessState = true
                    return
                }

                showAccountSuccessState = false
                withAnimation(.easeOut(duration: 0.28).delay(0.03)) {
                    showAccountSuccessState = true
                }
            }
            .onChange(of: presentation.accountState) { _, _ in
                guard hasConnectedAccount else {
                    showAccountSuccessState = true
                    return
                }

                showAccountSuccessState = false
                withAnimation(.easeOut(duration: 0.24)) {
                    showAccountSuccessState = true
                }
            }
        }
    }

    private func doneStep(presentation: NavigationModel.OnboardingPresentation) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            OnboardingHeader(
                title: "You're ready",
                subtitle: "Opening your dashboard..."
            ) {
                OnboardingSymbol(symbol: "checkmark.circle.fill", tint: .green)
            }

            OnboardingInsetGroup {
                if let miner = navigation.minerManager.miners.first {
                    OnboardingConnectedAccountRow(username: miner.username, status: "Connected")
                } else {
                    OnboardingInfoRow(
                        symbol: "checkmark.circle.fill",
                        tint: .green,
                        title: "Setup complete",
                        subtitle: "SwiftMiner is ready to use."
                    )
                }
            }
        }
        .task(id: presentation.accountState) {
            guard presentation.accountState.hasAccounts, presentation.setupStage == nil else { return }
            try? await Task.sleep(for: .milliseconds(850))
            guard !Task.isCancelled else { return }
            dismissOnboarding()
        }
    }

    // MARK: - Flow

    private var clampedStepIndex: Int {
        min(max(0, currentStepIndex), steps.count - 1)
    }

    private var doneStepIndex: Int {
        steps.firstIndex(of: .done) ?? max(0, steps.count - 1)
    }

    private func syncStep(with presentation: NavigationModel.OnboardingPresentation?) {
        guard let presentation else { return }
        if presentation.accountState.hasAccounts && presentation.setupStage == nil {
            withAnimation(.easeInOut(duration: 0.22)) {
                currentStepIndex = doneStepIndex
            }
        } else if presentation.accountState.hasAccounts {
            withAnimation(.easeInOut(duration: 0.22)) {
                currentStepIndex = steps.firstIndex(of: .account) ?? clampedStepIndex
            }
        } else {
            currentStepIndex = clampedStepIndex
        }
    }

    private func advance(stepIndex: Int, totalSteps: Int) {
        if steps[stepIndex] == .account, case .noAccounts = presentation?.accountState {
            navigation.showAddAccountSheet = true
            return
        }

        guard stepIndex < totalSteps - 1 else {
            dismissOnboarding()
            return
        }

        withAnimation(.easeInOut(duration: 0.22)) {
            currentStepIndex = stepIndex + 1
        }
    }

    private func nextButtonTitle(
        stepIndex: Int,
        totalSteps: Int,
        presentation: NavigationModel.OnboardingPresentation
    ) -> String {
        let isLast = stepIndex >= totalSteps - 1
        if steps[stepIndex] == .account {
            switch presentation.accountState {
            case .noAccounts:
                return "Connect Twitch"
            case .hasAccounts:
                return presentation.setupStage == nil ? "Open Dashboard" : "Preparing..."
            }
        }

        guard isLast else { return "Continue" }

        switch presentation.accountState {
        case .noAccounts:
            return "Finish"
        case .hasAccounts:
            return "Open Dashboard"
        }
    }

    private func isNextButtonDisabled(
        stepIndex: Int,
        presentation: NavigationModel.OnboardingPresentation
    ) -> Bool {
        steps[stepIndex] == .account && presentation.setupStage != nil
    }

    private func dismissOnboarding() {
        withAnimation(.easeInOut(duration: 0.2)) {
            navigation.dismissOnboarding()
        }
    }
}

// MARK: - Rows

private struct OnboardingHeader<Icon: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var icon: Icon

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            icon

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title.weight(.bold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct OnboardingSymbol: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 42, height: 42)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(tint.opacity(0.18), lineWidth: 1)
            }
    }
}

private struct OnboardingInsetGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(12)
        .background(.thinMaterial.opacity(0.72), in: RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct OnboardingInfoRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct OnboardingConnectedAccountRow: View {
    let username: String
    let status: String

    private var initials: String {
        let pieces = username.split(separator: " ")
        if pieces.count > 1 {
            let first = pieces.first?.first.map(String.init) ?? ""
            let second = pieces.dropFirst().first?.first.map(String.init) ?? ""
            let combined = (first + second).uppercased()
            return combined.isEmpty ? "U" : combined
        }

        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = trimmed.first.map { String($0).uppercased() } ?? "U"
        return first
    }

    var body: some View {
        let swatch = AvatarColorPalette.swatch(for: nil, username: username)

        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                Circle()
                    .fill(swatch.gradient)
                    .opacity(0.9)
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.22), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .opacity(0.68)
                Circle()
                    .strokeBorder(.white.opacity(0.62), lineWidth: 1)
                Text(initials)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(swatch.text)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(username)
                    .font(.subheadline.weight(.semibold))
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.green)
        }
    }
}

private struct OnboardingSetupProgressRow: View {
    let stage: NavigationModel.OnboardingSetupStage

    var body: some View {
        OnboardingInsetGroup {
            HStack(alignment: .center, spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(stage.title)
                        .font(.subheadline.weight(.semibold))
                    Text("This only takes a moment.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private extension NavigationModel.OnboardingAccountState {
    var hasAccounts: Bool {
        if case .hasAccounts = self { return true }
        return false
    }
}

// MARK: - Preview

#Preview {
    OnboardingView()
        .environment(AppModel(clientId: "preview"))
        .environment(NavigationModel(clientId: "preview"))
}
