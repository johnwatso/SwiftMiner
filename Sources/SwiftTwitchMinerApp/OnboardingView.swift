import SwiftUI
import SwiftTwitchMiner
import UserNotifications

/// Optional onboarding surface that reflects current app readiness.
/// Implements a native macOS "setup panel" feel — non-blocking and state-driven.
struct OnboardingView: View {
    @Environment(NavigationModel.self) private var navigation
    @StateObject private var settings = Settings.shared

    private var presentation: NavigationModel.OnboardingPresentation? {
        navigation.onboardingPresentation
    }

    var body: some View {
        if let presentation {
            VStack(alignment: .leading, spacing: 0) {
                // Main Setup Panel
                VStack(alignment: .leading, spacing: 20) {
                    panelHeader(presentation: presentation)
                    
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 18) {
                            // 1. Setup Status (Syncing) - High Priority
                            if let stage = presentation.setupStage {
                                SetupStatusCard(stage: stage)
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }

                            // 2. Account Section (Connect/Add)
                            AccountSetupCard(state: presentation.accountState)

                            // 3. Game Preferences Section (Optional)
                            if presentation.showsGamePreferences {
                                GamePreferencesCard()
                                    .transition(.scale(scale: 0.95).combined(with: .opacity))
                            }

                            // 4. Default Settings (Optional)
                            if presentation.showsPreferences {
                                GeneralPreferencesCard()
                                    .transition(.scale(scale: 0.95).combined(with: .opacity))
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(24)
            }
            .frame(width: 440)
            .frame(maxHeight: 680)
            .glassContentSurface(cornerRadius: 32)
            .shadow(color: .black.opacity(0.22), radius: 24, y: 16)
            .onAppear {
                navigation.refreshOnboardingPresentation()
            }
            .onChange(of: settings.gamePreferencesData) { _, _ in
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    navigation.refreshOnboardingPresentation()
                }
            }
            .onChange(of: navigation.showAddAccountSheet) { _, isShowing in
                guard !isShowing else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    navigation.refreshOnboardingPresentation()
                }
            }
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: presentation)
        }
    }

    // MARK: - Header

    private func panelHeader(presentation: NavigationModel.OnboardingPresentation) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SwiftMiner Setup")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .textCase(.uppercase)
                        .tracking(1.8)
                        .foregroundStyle(.purple.opacity(0.85))

                    Text(presentation.title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Button {
                    withAnimation(.easeIn(duration: 0.2)) {
                        navigation.dismissOnboarding()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .padding(8)
                        .background(.thinMaterial, in: Circle())
                        .overlay {
                            Circle().strokeBorder(.white.opacity(0.1), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .help("Dismiss this panel. You can always finish setup from Accounts or Settings.")
            }

            Text(presentation.subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
        }
    }
}

// MARK: - Setup Components

private struct OnboardingCardBase<Content: View>: View {
    let title: String
    let subtitle: String?
    let icon: String?
    let content: Content

    init(_ title: String, subtitle: String? = nil, icon: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if let icon {
                    Image(systemName: icon)
                        .font(.headline)
                        .foregroundStyle(.purple)
                }
                Text(title)
                    .font(.headline)
            }
            
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            content
        }
        .padding(20)
        .background(.ultraThinMaterial.opacity(0.6), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct AccountSetupCard: View {
    let state: NavigationModel.OnboardingAccountState
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        switch state {
        case .noAccounts:
            OnboardingCardBase("Connect your account", subtitle: "Link at least one Twitch account to start discovering mining-eligible campaigns.", icon: "person.badge.key.fill") {
                Button {
                    navigation.showAddAccountSheet = true
                } label: {
                    Label("Connect Account", systemImage: "person.badge.key")
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

        case .hasAccounts(let count):
            OnboardingCardBase("\(count) \(count == 1 ? "account" : "accounts") connected", subtitle: "Multi-account mining is supported. Add more anytime for broader coverage.", icon: "checkmark.circle.fill") {
                Button {
                    navigation.showAddAccountSheet = true
                } label: {
                    Label("Add Another Account", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

private struct GamePreferencesCard: View {
    @StateObject private var settings = Settings.shared
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        OnboardingCardBase("Prioritize certain games", subtitle: "Selections save live. If empty, SwiftMiner mines any available campaign.", icon: "star.fill") {
            GamePreferencesSection(settings: settings, minerManager: navigation.minerManager)
                .frame(minHeight: 80)
        }
    }
}

private struct GeneralPreferencesCard: View {
    @StateObject private var settings = Settings.shared

    var body: some View {
        OnboardingCardBase("Quick settings", subtitle: "Tune these core behaviors now or later in Settings.", icon: "gearshape.fill") {
            VStack(alignment: .leading, spacing: 16) {
                Toggle(isOn: $settings.showClaimNotifications) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Claim notifications")
                            .font(.subheadline.weight(.medium))
                        Text("Get alerted when a drop is secured.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider().opacity(0.5)

                Toggle(isOn: $settings.autoStartOnLaunch) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-start on launch")
                            .font(.subheadline.weight(.medium))
                        Text("Jump into mining as soon as the app opens.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onChange(of: settings.showClaimNotifications) { _, newValue in
                guard newValue else { return }
                Task {
                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                }
            }
        }
    }
}

private struct SetupStatusCard: View {
    let stage: NavigationModel.OnboardingSetupStage

    private var progress: Double {
        let stages = NavigationModel.OnboardingSetupStage.allCases
        guard let index = stages.firstIndex(of: stage) else { return 0.25 }
        return Double(index + 1) / Double(stages.count)
    }

    var body: some View {
        OnboardingCardBase("Syncing with Twitch", subtitle: "The dashboard is live and usable while we finish the initial sync.") {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.12), lineWidth: 3)
                        .frame(width: 38, height: 38)

                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(
                            LinearGradient(colors: [.purple, .blue], startPoint: .top, endPoint: .bottom),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .frame(width: 38, height: 38)
                        .rotationEffect(.degrees(-90))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(stage.title)
                        .font(.subheadline.weight(.semibold))
                    Text("Synchronizing campaigns & inventory…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Previews

#Preview {
    OnboardingView()
        .environment(AppModel(clientId: "preview"))
        .environment(NavigationModel(clientId: "preview"))
}
