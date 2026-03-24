import AppKit
import SwiftUI
import SwiftTwitchMiner
import UserNotifications

/// Optional onboarding surface that reflects current app readiness.
/// Styled as a calm, step-by-step modal with one glass surface.
struct OnboardingView: View {
    @Environment(NavigationModel.self) private var navigation
    @StateObject private var settings = Settings.shared
    @State private var currentStepIndex = 0
    @State private var showAccountSuccessState = false

    private enum OnboardingStep: String, CaseIterable {
        case welcome
        case account
        case gamePreferences
        case settings
        case privacy
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
                    .padding(.bottom, 24)

                stepContentContainer(step: step, presentation: presentation)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                footer(stepIndex: stepIndex, totalSteps: steps.count, presentation: presentation)
                    .padding(.top, 20)
            }
            .padding(32)
            .frame(width: 680)
            .frame(maxHeight: 760)
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.regularMaterial)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.white.opacity(0.38), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.24), radius: 30, y: 12)
            .onAppear {
                navigation.refreshOnboardingPresentation()
                currentStepIndex = clampedStepIndex
            }
            .onChange(of: settings.gamePreferencesData) { _, _ in
                withAnimation(.easeInOut(duration: 0.2)) {
                    navigation.refreshOnboardingPresentation()
                }
            }
            .onChange(of: navigation.showAddAccountSheet) { _, isShowing in
                guard !isShowing else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    navigation.refreshOnboardingPresentation()
                }
            }
            .onChange(of: navigation.onboardingPresentation) { _, _ in
                currentStepIndex = clampedStepIndex
            }
        }
    }

    // MARK: - Layout

    private func topBar(step: Int, total: Int) -> some View {
        HStack(spacing: 12) {
            Text("STEP \(step) OF \(total)")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                dismissOnboarding()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
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
                    .transition(.opacity.combined(with: .offset(y: 10)))
            }
            .frame(maxWidth: 540, alignment: .leading)
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
                }

                Button(nextButtonTitle(stepIndex: stepIndex, totalSteps: totalSteps, presentation: presentation)) {
                    advance(stepIndex: stepIndex, totalSteps: totalSteps)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.94, green: 0.17, blue: 0.30))
            }
        }
        .frame(maxWidth: 540, alignment: .leading)
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

        case .gamePreferences:
            gamePreferencesStep

        case .settings:
            settingsStep

        case .privacy:
            privacyStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 12) {
                Image(nsImage: appIconImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.20), radius: 8, y: 4)

                Text("Welcome to SwiftMiner")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.primary)

                Text("Set up in a minute. You can skip or change everything later.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                OnboardingInfoRow(title: "Connect your Twitch account", subtitle: "Start discovering active drop campaigns.")
                OnboardingInfoRow(title: "Choose game priorities", subtitle: "Optional filters for focused mining.")
                OnboardingInfoRow(title: "Tune quick settings", subtitle: "Notifications and auto-start behavior.")
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

        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                if hasConnectedAccount {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.green)
                }

                Text(hasConnectedAccount ? "Account connected" : "Connect an account")
                    .font(.system(size: 40, weight: .bold))
                Text(hasConnectedAccount ? "You're ready to start mining campaigns." : "Add an account to start mining campaigns.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
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
                    .tint(Color(red: 0.94, green: 0.17, blue: 0.30))

                case .hasAccounts(let count):
                    if let miner = primaryMiner {
                        OnboardingConnectedAccountRow(username: miner.username, status: "Connected")
                    }

                    if count > 1 {
                        Text("\(count) accounts connected.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Button("Add Another Account") {
                        navigation.showAddAccountSheet = true
                    }
                    .buttonStyle(.plain)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
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

    private var gamePreferencesStep: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Game preferences")
                    .font(.system(size: 40, weight: .bold))
                Text("Pick priorities or leave empty to mine all eligible campaigns.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            GamePreferencesSection(settings: settings, minerManager: navigation.minerManager)
        }
    }

    private var settingsStep: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Quick settings")
                    .font(.system(size: 40, weight: .bold))
                Text("These apply instantly and can be changed anytime.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                OnboardingToggleRow(
                    title: "Claim notifications",
                    subtitle: "Alert me when a drop is secured.",
                    isOn: $settings.showClaimNotifications
                )

                OnboardingToggleRow(
                    title: "Auto-start on launch",
                    subtitle: "Start mining when SwiftMiner opens.",
                    isOn: $settings.autoStartOnLaunch
                )
            }
            .onChange(of: settings.showClaimNotifications) { _, newValue in
                guard newValue else { return }
                Task {
                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                }
            }
        }
    }

    private var privacyStep: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Data & privacy")
                    .font(.system(size: 40, weight: .bold))
                Text("Your token stays in the macOS keychain. Remove accounts whenever you want.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                PrivacyRow(
                    title: "Stored securely",
                    subtitle: "Account credentials are saved in your local keychain."
                )
                PrivacyRow(
                    title: "You stay in control",
                    subtitle: "Delete accounts from the dashboard at any time."
                )
            }
        }
    }

    // MARK: - Flow

    private var clampedStepIndex: Int {
        min(max(0, currentStepIndex), steps.count - 1)
    }

    private func advance(stepIndex: Int, totalSteps: Int) {
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
        guard isLast else { return "Continue" }

        switch presentation.accountState {
        case .noAccounts:
            return "Finish"
        case .hasAccounts:
            return "Start Mining"
        }
    }

    private func dismissOnboarding() {
        withAnimation(.easeInOut(duration: 0.2)) {
            navigation.dismissOnboarding()
        }
    }
}

// MARK: - Rows

private struct OnboardingInfoRow: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct OnboardingToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
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
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.14))
                Text(initials)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(username)
                    .font(.headline)
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

private struct PrivacyRow: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Preview

#Preview {
    OnboardingView()
        .environment(AppModel(clientId: "preview"))
        .environment(NavigationModel(clientId: "preview"))
}
