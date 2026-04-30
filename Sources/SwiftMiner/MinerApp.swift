import AppKit
import SwiftUI
import SwiftMinerCore
import UserNotifications

@main
struct MinerApp: App {

    @StateObject private var updater = AppUpdater()
    @StateObject private var settings = Settings.shared
    @StateObject private var presentationController = AppPresentationController()
    @State private var minerManager = MinerManager(clientId: ClientConfiguration.clientId)
    @State private var appModel: AppModel
    @State private var navigation: NavigationModel
    @State private var notificationDelegate = AppNotificationDelegate()
    @State private var didApplyLaunchWindowPreference = false

    init() {
        let clientId = ClientConfiguration.clientId
        let manager = MinerManager(clientId: clientId)
        self._minerManager = State(initialValue: manager)
        self._appModel = State(initialValue: AppModel(clientId: clientId, minerManager: manager))
        self._navigation = State(initialValue: NavigationModel(clientId: clientId, minerManager: manager))
    }

    var body: some Scene {
        // Main window
        WindowGroup(id: AppWindowID.main) {
            ContentView()
                .environment(appModel)
                .environment(navigation)
                .environmentObject(updater)
                .task {
                    // Await navigation setup first — loads accounts from keychain
                    // and optionally auto-starts miners before AppModel reads miner state.
                    await navigation.setup()
                    await appModel.setup()
                    navigation.configureOnboardingPresentation()
                    UNUserNotificationCenter.current().delegate = notificationDelegate
                    await requestNotificationPermission()
                    updater.checkForUpdatesInBackground()
                    presentationController.configure(mode: settings.appPresenceMode)
                    applyLaunchWindowPreferenceIfNeeded()
                }
                .onChange(of: settings.appPresenceMode) { _, newValue in
                    presentationController.configure(mode: newValue)
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
                ) { _ in
                    Task { await appModel.stop() }
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }
            CommandGroup(after: .appSettings) {
                Button("Claim All Drops") {
                    Task { await appModel.claimAllDrops() }
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])

                Button("Refresh Progress") {
                    Task { await appModel.refreshProgress() }
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }

        MenuBarExtra(isInserted: menuBarExtraIsInserted) {
            MenuBarContent(presentationController: presentationController)
                .environment(appModel)
                .environment(navigation)
        } label: {
            MenuBarLabel()
                .environment(appModel)
        }
        .menuBarExtraStyle(.menu)

        // Settings window
        SwiftUI.Settings {
            SettingsView()
                .environment(appModel)
                .environment(navigation)
                .environmentObject(updater)
        }
    }

    private func requestNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    @MainActor
    private func applyLaunchWindowPreferenceIfNeeded() {
        guard !didApplyLaunchWindowPreference else { return }
        didApplyLaunchWindowPreference = true

        guard settings.startMinimized else { return }

        DispatchQueue.main.async {
            NSApp.windows
                .filter { $0.canBecomeMain && $0.isVisible }
                .forEach { $0.miniaturize(nil) }
        }
    }

    private var menuBarExtraIsInserted: Binding<Bool> {
        Binding {
            settings.appPresenceMode.showsMenuBarExtra
        } set: { _ in
        }
    }
}

private enum AppWindowID {
    static let main = "main"
}

@MainActor
fileprivate final class AppPresentationController: ObservableObject {
    private var mode: AppPresenceMode = .dockOnly
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        let notifications: [NSNotification.Name] = [
            NSWindow.didBecomeMainNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.willCloseNotification,
            NSWindow.didResizeNotification
        ]

        observers = notifications.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.applyCurrentMode()
                }
            }
        }
    }

    func configure(mode: AppPresenceMode) {
        self.mode = mode
        applyCurrentMode()
    }

    func prepareToOpenWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyCurrentMode() {
        switch mode {
        case .dockOnly, .dockAndMenuBar:
            NSApp.setActivationPolicy(.regular)
        case .menuBarWhenClosed:
            NSApp.setActivationPolicy(hasOpenUserWindow ? .regular : .accessory)
        }
    }

    private var hasOpenUserWindow: Bool {
        NSApp.windows.contains { window in
            window.canBecomeMain && window.isVisible && !window.isMiniaturized
        }
    }
}

private final class AppNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound, .badge]
    }
}

// MARK: - Menu bar label

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Image(systemName: appModel.activeMiners > 0 ? "gift.fill" : "gift")
    }
}

// MARK: - Menu bar content

struct MenuBarContent: View {
    @Environment(AppModel.self) private var appModel
    @Environment(NavigationModel.self) private var navigation
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    fileprivate let presentationController: AppPresentationController

    var body: some View {
        Group {
            Label(statusText, systemImage: statusIcon)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                VStack(alignment: .leading) {
                    Text("Miners Running")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(appModel.activeMiners) / \(appModel.totalMiners)")
                        .font(.headline)
                }

                Divider()
                    .frame(height: 30)

                VStack(alignment: .leading) {
                    Text("Drops Today")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(appModel.dropsClaimedToday)")
                        .font(.headline)
                }
            }
            .padding(.vertical, 4)

            Divider()

            Button("Claim All Drops") {
                Task { await appModel.claimAllDrops() }
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])

            Divider()

            Button("Open Dashboard") {
                openDashboard()
            }

            Button("Settings...") {
                presentationController.prepareToOpenWindow()
                openSettings()
            }

            Divider()

            Button("Quit") {
                Task {
                    await appModel.stop()
                    NSApp.terminate(nil)
                }
            }
        }
        .frame(minWidth: 200)
    }

    private var statusText: String {
        if appModel.activeMiners == 0 {
            return "No miners active"
        } else if appModel.activeMiners == appModel.totalMiners {
            return "All miners active"
        } else {
            return "\(appModel.activeMiners) miners active"
        }
    }

    private var statusIcon: String {
        switch appModel.overallStatus {
        case .watching:          return "play.fill"
        case .authenticating:    return "key.fill"
        case .fetchingCampaigns: return "arrow.clockwise"
        case .claiming:          return "gift.fill"
        case .error:             return "exclamationmark.triangle.fill"
        case .waitingForStream:  return "clock.fill"
        case .stopped, .idle:    return "stop.fill"
        case .paused:            return "clock.fill"
        case .idleNoEligibleCampaigns: return "pause.circle"
        case .blockedAccountNotLinked: return "link.badge.plus"
        }
    }

    private func openDashboard() {
        presentationController.prepareToOpenWindow()

        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: AppWindowID.main)
        }
    }
}

enum ClientConfiguration {
    // Resolve from environment first, but treat empty/malformed values as missing.
    static var clientId: String {
        let raw = ProcessInfo.processInfo.environment["TWITCH_CLIENT_ID"] ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return fallbackClientId }

        // Xcode scheme envs can sometimes be pasted as JSON blobs.
        if let parsed = parseWrappedValue(trimmed), !parsed.isEmpty {
            return parsed
        }

        return trimmed
    }

    private static let fallbackClientId = "kd1unb4b3q4t58fwlpcbzcbnm76a8fp"

    private static func parseWrappedValue(_ input: String) -> String? {
        guard input.hasPrefix("{") || input.hasPrefix("[") else { return nil }
        guard let valueRange = input.range(of: "\"value\""),
              let colonRange = input[valueRange.upperBound...].range(of: ":"),
              let quoteStart = input[colonRange.upperBound...].range(of: "\"") else {
            return nil
        }
        let afterQuote = input[quoteStart.upperBound...]
        guard let quoteEnd = afterQuote.range(of: "\"") else { return nil }
        return String(afterQuote[..<quoteEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
