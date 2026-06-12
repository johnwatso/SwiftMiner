import AppKit
import ServiceManagement
import SwiftUI
import SwiftMinerCore
import TipKit
import UserNotifications
import WebKit

@main
struct MinerApp: App {

    @NSApplicationDelegateAdaptor(LaunchContextDelegate.self) private var launchContext
    @StateObject private var updater = AppUpdater()
    @StateObject private var settings = Settings.shared
    @StateObject private var presentationController = AppPresentationController()
    @State private var minerManager = MinerManager(clientId: ClientConfiguration.clientId)
    @State private var appModel: AppModel
    @State private var navigation: NavigationModel
    @State private var notificationDelegate = AppNotificationDelegate()
    @State private var didApplyLaunchWindowPreference = false
    @Environment(\.openWindow) private var openWindow

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
                    updater.onError = { error in
                        navigation.logEvent(
                            message: "Update check failed: \(error.localizedDescription). You can download manually from https://github.com/johnwatso/SwiftMiner/releases",
                            level: .warning,
                            rawMessage: "[update] Update check failed: \(error.localizedDescription)"
                        )
                    }
                    updater.isSafeToInstallNow = { navigation.isSafeToInstallUpdateNow }
                    updater.onAutoInstall = { version, plan in
                        navigation.logEvent(
                            message: "SwiftMiner \(version) downloaded — \(plan); the app will relaunch itself and resume mining.",
                            level: .info,
                            rawMessage: "[update] SwiftMiner \(version) downloaded — \(plan)"
                        )
                    }
                    updater.onUpToDate = {
                        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
                        navigation.logEvent(
                            message: "Already up to date\(version.isEmpty ? "" : " — SwiftMiner \(version)")",
                            level: .info,
                            rawMessage: "[update] Already up to date \(version)"
                        )
                    }
                    navigation.configureOnboardingPresentation()
                    UNUserNotificationCenter.current().delegate = notificationDelegate
                    await requestNotificationPermission()
                    updater.checkForUpdatesInBackground()
                    presentationController.configure(mode: settings.appPresenceMode)
                    applyLaunchWindowPreferenceIfNeeded()
                    try? Tips.configure([
                        .displayFrequency(.immediate),
                        .datastoreLocation(.applicationDefault)
                    ])
                }
                .onChange(of: settings.appPresenceMode) { _, newValue in
                    presentationController.configure(mode: newValue)
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
                ) { _ in
                    Task { await appModel.stop() }
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
                ) { _ in
                    appModel.refreshNotificationBadge()
                }
                .onOpenURL { url in
                    handleDeepLink(url)
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

                Button("What's New") {
                    openWindow(id: AppWindowID.releaseNotes)
                }
                .disabled(updater.releaseNotesURL == nil)
            }
            CommandGroup(after: .appSettings) {
                Button("Refresh Progress") {
                    Task { await appModel.refreshProgress() }
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
            CommandGroup(after: .help) {
                Button("Export Diagnostic Logs…") {
                    LogExporter.presentSavePanel(navigation: navigation)
                }
                Button("Raise Issue on GitHub…") {
                    GitHubIssueReporter.openNewIssue()
                }
            }
            // The default View menu contains toolbar/sidebar toggles — we keep sidebar
            // so users can toggle it.
            CommandGroup(replacing: .toolbar) {}
            // The File menu only contains "New Window" / "Close" — neither is
            // useful for a single-window app. Strip the SwiftUI-injected items;
            // the menu itself is removed alongside View in LaunchContextDelegate.
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .saveItem) {}
            #if DEBUG
            CommandMenu("Developer") {
                if minerManager.miners.isEmpty {
                    Button("No miners added") {
                        // no-op
                    }
                    .disabled(true)
                } else {
                    ForEach(minerManager.miners) { miner in
                        Menu(miner.displayName) {
                            Button("Cycle State") {
                                minerManager.cycleDebugState(for: miner.id)
                            }
                            Divider()
                            ForEach(MinerManager.DebugState.allCases, id: \.self) { state in
                                Button("Set to: \(state.rawValue)") {
                                    minerManager.setDebugState(for: miner.id, state: state)
                                }
                            }
                            Divider()
                            Button("Revert to Live Data") {
                                Task {
                                    await minerManager.revertToLiveData(for: miner.id)
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Revert All to Live Data") {
                        Task {
                            await minerManager.revertAllToLiveData()
                        }
                    }
                }
            }
            #endif
        }

        Window("What's New", id: AppWindowID.releaseNotes) {
            ReleaseNotesWindow(releaseNotesURL: updater.releaseNotesURL)
        }
        .defaultSize(width: 760, height: 680)

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

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "swiftminer" else { return }
        switch url.host {
        case "pair":
            navigation.requestSwiftBotPairing()
            NSApp.activate(ignoringOtherApps: true)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        default:
            break
        }
    }

    @MainActor
    private func applyLaunchWindowPreferenceIfNeeded() {
        guard !didApplyLaunchWindowPreference else { return }
        didApplyLaunchWindowPreference = true

        guard settings.startMinimized else { return }

        // Only auto-minimise when the app was launched at login. Manual launches
        // (Dock, Finder, Spotlight) should always show the window. We require
        // BOTH signals: NSApplication.launchIsDefaultUserInfoKey AND an active
        // SMAppService registration. The userInfo key alone has been observed
        // to mis-report on manual launches, so the registration check acts as
        // a structural backstop — `Start minimised` is meaningless if the app
        // isn't actually registered as a login item.
        guard launchContext.wasLaunchedAtLogin else { return }
        guard SMAppService.mainApp.status == .enabled else { return }

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
    static let releaseNotes = "releaseNotes"
}

/// Captures whether the app was launched automatically at login (vs. opened by the user).
/// The `didFinishLaunching` notification's `launchIsDefaultUserInfoKey` is `false` when the
/// system launched the app on the user's behalf — login items, reopen-on-restart, etc.
final class LaunchContextDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published private(set) var wasLaunchedAtLogin: Bool = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let isDefault = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool {
            wasLaunchedAtLogin = !isDefault
        }

        // SwiftMiner is single-window by design — disable macOS automatic
        // window tabbing so the Window menu doesn't expose "Show Tab Bar",
        // "Merge All Windows", etc.
        NSWindow.allowsAutomaticWindowTabbing = false

        // SwiftUI's empty `.toolbar` / `.sidebar` command groups still leave
        // an empty "View" menu in the menu bar; the same applies to the File
        // menu after stripping `.newItem` / `.saveItem`. Remove both directly
        // from the main menu, and re-strip whenever the menu is rebuilt.
        Self.removeRedundantTopLevelMenus()
        NotificationCenter.default.addObserver(
            forName: NSMenu.didAddItemNotification,
            object: NSApp.mainMenu,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { Self.removeRedundantTopLevelMenus() }
        }

        // Disable fullscreen on every window. macOS auto-adds an
        // "Enter Full Screen" item to the View menu whenever any key window
        // declares `.fullScreenPrimary` — stripping that flag also removes
        // the menu item, which lets our empty View command groups collapse
        // the menu out of the menu bar entirely.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                var behavior = window.collectionBehavior
                behavior.remove(.fullScreenPrimary)
                behavior.remove(.fullScreenAuxiliary)
                behavior.insert(.fullScreenNone)
                window.collectionBehavior = behavior
                window.standardWindowButton(.zoomButton)?.isEnabled = true
            }
        }
    }

    @MainActor
    private static func removeRedundantTopLevelMenus() {
        guard let mainMenu = NSApp.mainMenu else { return }
        // SwiftUI's empty `.toolbar` / `.sidebar` / `.newItem` / `.saveItem`
        // command groups leave the View and File menus structurally empty.
        // Identify them by emptiness rather than localised title so this works
        // on any system locale. Skip the application menu (index 0).
        let removable = mainMenu.items.enumerated().compactMap { index, item -> NSMenuItem? in
            guard index > 0, let submenu = item.submenu else { return nil }
            let hasRealItem = submenu.items.contains { !$0.isSeparatorItem }
            return hasRealItem ? nil : item
        }
        for item in removable {
            mainMenu.removeItem(item)
        }
    }
}

private struct ReleaseNotesWindow: View {
    let releaseNotesURL: URL?
    @State private var content: ReleaseNotesContent = .loading

    var body: some View {
        contentView
            .navigationTitle("What's New")
            .task(id: releaseNotesURL) {
                await loadReleaseNotes()
            }
    }

    @ViewBuilder
    private var contentView: some View {
        switch content {
        case .loading:
            ProgressView("Loading release notes...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let html, let baseURL):
            ReleaseNotesWebView(html: html, baseURL: baseURL)
        case .failed(let message):
            ContentUnavailableView(
                "Release Notes Unavailable",
                systemImage: "doc.text.magnifyingglass",
                description: Text(message)
            )
        }
    }

    private func loadReleaseNotes() async {
        guard let releaseNotesURL else {
            content = .failed("Configure the Sparkle feed URL to show What's New.")
            return
        }

        content = .loading

        do {
            let (data, response) = try await URLSession.shared.data(from: releaseNotesURL)
            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                content = .failed("SwiftMiner could not load \(releaseNotesURL.absoluteString) because the server returned \(httpResponse.statusCode).")
                return
            }

            guard let html = String(data: data, encoding: .utf8) else {
                content = .failed("SwiftMiner loaded the release notes, but the page was not valid UTF-8 HTML.")
                return
            }

            content = .loaded(html: html, baseURL: releaseNotesURL)
        } catch {
            content = .failed("SwiftMiner could not load \(releaseNotesURL.absoluteString). \(error.localizedDescription)")
        }
    }
}

private enum ReleaseNotesContent: Equatable {
    case loading
    case loaded(html: String, baseURL: URL)
    case failed(String)
}

private struct ReleaseNotesWebView: NSViewRepresentable {
    let html: String
    let baseURL: URL

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.loadHTMLString(html, baseURL: baseURL)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(html, baseURL: baseURL)
    }
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
            Text("\(Image(systemName: statusIcon)) \(statusText)")
                .foregroundStyle(statusColor)

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
            return "No miners running"
        } else if appModel.activeMiners == appModel.totalMiners {
            return "All miners running"
        } else {
            return "\(appModel.activeMiners) miners running"
        }
    }

    private var statusIcon: String {
        if appModel.totalMiners > 0, appModel.activeMiners == appModel.totalMiners {
            return appModel.hasMinerAttentionItems ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        }

        if appModel.activeMiners > 0, appModel.activeMiners < appModel.totalMiners {
            return "exclamationmark.triangle.fill"
        }

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
        case .blockedAccountNotLinked: return "personalhotspot.slash"
        }
    }

    private var statusColor: Color {
        if appModel.totalMiners > 0, appModel.activeMiners == appModel.totalMiners {
            return appModel.hasMinerAttentionItems ? .orange : .green
        }

        if appModel.activeMiners > 0, appModel.activeMiners < appModel.totalMiners {
            return .orange
        }

        return .secondary
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
