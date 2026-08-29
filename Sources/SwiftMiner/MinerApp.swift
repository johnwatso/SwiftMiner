import AppKit
import ServiceManagement
import SwiftUI
import SwiftMinerCore
import UserNotifications
import WebKit

@main
struct MinerApp: App {

    @NSApplicationDelegateAdaptor(LaunchContextDelegate.self) private var launchContext
    @StateObject private var updater = AppUpdater()
    @StateObject private var unattendedHealth: UnattendedHealthModel
    private var settings: Settings { .shared }
    @StateObject private var presentationController = AppPresentationController()
    @State private var minerManager: MinerManager
    @State private var appModel: AppModel
    @State private var navigation: NavigationModel
    @State private var notificationDelegate = AppNotificationDelegate()
    @State private var didApplyLaunchWindowPreference = false
    @State private var showLegacyBackupPrompt = false
    @State private var showUncleanExitPrompt = false
    @Environment(\.openWindow) private var openWindow

    init() {
        if !SwiftMinerRuntime.isRunningTests {
            AppMetrics.shared.start()
        }
        let clientId = ClientConfiguration.clientId
        let healthStore = SwiftMinerRuntime.isRunningTests
            ? nil
            : UnattendedHealthStore(fileURL: UnattendedHealthStore.defaultFileURL())
        let ledgerStore = SwiftMinerRuntime.isRunningTests
            ? nil
            : EarningLedgerStore(fileURL: EarningLedgerStore.defaultFileURL())
        let manager = MinerManager(
            clientId: clientId,
            unattendedHealthStore: healthStore,
            earningLedgerStore: ledgerStore
        )
        self._minerManager = State(initialValue: manager)
        self._unattendedHealth = StateObject(wrappedValue: UnattendedHealthModel(store: healthStore))
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
                .environmentObject(unattendedHealth)
                .task {
                    if !SwiftMinerRuntime.isRunningTests {
                        ApplicationsFolderInstaller.promptToMoveIfNecessary()
                        // Migrate any legacy hardware-UUID account file into the real Keychain
                        // BEFORE accounts are loaded below. No-op on DEBUG and after the first run.
                        await LegacyAccountMigrator.migrateIfNeeded()
                        // Reclaims the cache and defaults the removed Steam artwork feature left.
                        LegacySteamArtworkCleanup.runIfNeeded()
                        if settings.shouldPromptForLegacyBackupDeletion {
                            settings.markLegacyBackupPromptShown()
                            showLegacyBackupPrompt = true
                        }
                    }

                    // Await navigation setup first — loads accounts from keychain
                    // and optionally auto-starts miners before AppModel reads miner state.
                    navigation.onWebDashboardAvailabilityChanged = { isAvailable, detail in
                        Task { @MainActor in
                            if isAvailable {
                                await unattendedHealth.resolveSystemIncident(
                                    id: "system:web-dashboard",
                                    kind: .webDashboardUnavailable
                                )
                            } else {
                                await unattendedHealth.recordSystemIncident(
                                    id: "system:web-dashboard",
                                    displayName: "Web Dashboard",
                                    kind: .webDashboardUnavailable,
                                    severity: .warning,
                                    summary: "The dashboard could not start\(detail.map { ": \($0)" } ?? "")",
                                    recommendedAction: "Open SwiftMiner and review the Activity Log"
                                )
                            }
                        }
                    }
                    await navigation.setup()
                    await appModel.setup()
                    unattendedHealth.startMonitoring()

                    if launchContext.previousExitWasUnclean {
                        navigation.logEvent(
                            message: "SwiftMiner didn't shut down cleanly last time (crash, force-quit, or power loss).",
                            level: .warning,
                            rawMessage: "[lifecycle] unclean previous exit detected"
                        )
                        showUncleanExitPrompt = true
                    }

                    updater.onError = { error in
                        navigation.logEvent(
                            message: "Update check failed: \(error.localizedDescription). You can download manually from https://github.com/johnwatso/SwiftMiner/releases",
                            level: .warning,
                            rawMessage: "[update] Update check failed: \(error.localizedDescription)"
                        )
                        Task { @MainActor in
                            await unattendedHealth.recordSystemIncident(
                                id: "system:automatic-updates",
                                displayName: "Automatic Updates",
                                kind: .automaticUpdateFailed,
                                severity: .warning,
                                summary: "SwiftMiner could not check for updates",
                                recommendedAction: "Check your connection or download the latest release manually"
                            )
                        }
                    }
                    updater.isSafeToInstallNow = { navigation.isSafeToInstallUpdateNow }
                    updater.onAutoInstall = { version, plan in
                        Task { @MainActor in
                            await unattendedHealth.resolveSystemIncident(
                                id: "system:automatic-updates",
                                kind: .automaticUpdateFailed
                            )
                        }
                        navigation.recordPendingUpdate(to: version)
                        navigation.logEvent(
                            message: "SwiftMiner \(version) downloaded — \(plan); the app will relaunch itself and resume mining.",
                            level: .info,
                            rawMessage: "[update] SwiftMiner \(version) downloaded — \(plan)"
                        )
                    }
                    updater.onUpToDate = {
                        Task { @MainActor in
                            await unattendedHealth.resolveSystemIncident(
                                id: "system:automatic-updates",
                                kind: .automaticUpdateFailed
                            )
                        }
                        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
                        navigation.logEvent(
                            message: "Already up to date\(version.isEmpty ? "" : " — SwiftMiner \(version)")",
                            level: .info,
                            rawMessage: "[update] Already up to date \(version)"
                        )
                    }
                    navigation.configureOnboardingPresentation()
                    if !SwiftMinerRuntime.isRunningTests {
                        UNUserNotificationCenter.current().delegate = notificationDelegate
                        UpdateCompletionNotification.registerCategory()
                        await requestNotificationPermission()
                        if let completedUpdate = navigation.consumeCompletedUpdateNotification() {
                            await UpdateCompletionNotification.deliver(completedUpdate)
                        }
                    }
                    presentationController.configure(mode: settings.appPresenceMode)
                    applyLaunchWindowPreferenceIfNeeded()
                }
                .onChange(of: settings.appPresenceMode) { _, newValue in
                    presentationController.configure(mode: newValue)
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
                ) { _ in
                    unattendedHealth.stopMonitoring()
                    // Watch time accumulates in memory between throttled writes; flush so the
                    // final stretch before quitting survives.
                    Task { try? await minerManager.earningLedgerStore?.flush() }
                    Task { await appModel.stop() }
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
                ) { _ in
                    appModel.refreshNotificationBadge()
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: .openSwiftMinerReleaseNotes)
                ) { _ in
                    presentationController.prepareToOpenWindow()
                    openWindow(id: AppWindowID.releaseNotes)
                }
                .onOpenURL { url in
                    handleDeepLink(url)
                }
                .alert("Accounts moved to Keychain", isPresented: $showLegacyBackupPrompt) {
                    Button("Delete Backup", role: .destructive) {
                        do {
                            try settings.deleteLegacyBackup()
                        } catch {
                            navigation.logEvent(
                                message: "Couldn't delete the old account backup: \(error.localizedDescription)",
                                level: .warning,
                                rawMessage: "[migration] delete legacy backup failed: \(error.localizedDescription)"
                            )
                        }
                    }
                    Button("Keep", role: .cancel) {}
                } message: {
                    Text("Your accounts are now stored securely in the macOS Keychain. The old encrypted backup file is no longer needed — delete it now, or keep it and we'll ask again next week.")
                }
                .alert("SwiftMiner quit unexpectedly", isPresented: $showUncleanExitPrompt) {
                    Button("Report Issue…") {
                        GitHubIssueReporter.openNewIssue(
                            title: "[Crash] ",
                            note: "SwiftMiner appears to have quit unexpectedly during its previous run. If macOS showed a crash report, attaching it (or the matching .ips file from Console.app → Crash Reports) helps a lot."
                        )
                    }
                    Button("Dismiss", role: .cancel) {}
                } message: {
                    Text("The previous run ended without a clean shutdown — this can be a crash, a force-quit, or a power loss. If SwiftMiner crashed, you can report it with the app and macOS versions pre-filled.")
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About SwiftMiner") {
                    showAboutPanel()
                }

                Divider()

                Button("Check for Updates...") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)

                Button("What's New") {
                    openWindow(id: AppWindowID.releaseNotes)
                }
                .disabled(updater.releaseNotesURL == nil)

                Button("SwiftMiner Website") {
                    NSWorkspace.shared.open(URL(string: "https://swiftminer.app")!)
                }
            }
            CommandGroup(after: .appSettings) {
                Button("Refresh Progress") {
                    Task { await appModel.refreshProgress() }
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
            // Replace SwiftUI's automatic Help item, which has no local Help Book
            // to open, with SwiftMiner's hosted help and support actions.
            CommandGroup(replacing: .help) {
                Button("SwiftMiner Help") {
                    NSWorkspace.shared.open(URL(string: "https://swiftminer.app/help/")!)
                }
                Button("Export Diagnostic Logs…") {
                    Task { await LogExporter.presentSavePanel(navigation: navigation) }
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
                Button("Preview Update Notification") {
                    Task {
                        UpdateCompletionNotification.registerCategory()
                        await requestNotificationPermission()
                        await UpdateCompletionNotification.deliverPreview()
                    }
                }

                Divider()

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
    private func showAboutPanel() {
        let websiteURL = URL(string: "https://swiftminer.app")!
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineSpacing = 3

        let credits = NSMutableAttributedString(
            string: "swiftminer.app",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.linkColor,
                .link: websiteURL,
                .paragraphStyle: paragraphStyle
            ]
        )
        credits.append(NSAttributedString(
            string: "\nMade in NZ ",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraphStyle
            ]
        ))

        let heartAttachment = NSTextAttachment()
        let heartConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: .systemRed))
        heartAttachment.image = NSImage(
            systemSymbolName: "heart.fill",
            accessibilityDescription: "Love"
        )?.withSymbolConfiguration(heartConfiguration)
        heartAttachment.bounds = CGRect(x: 0, y: -2, width: 12, height: 12)
        credits.append(NSAttributedString(attachment: heartAttachment))

        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
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
    @Published private(set) var previousExitWasUnclean: Bool = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let isDefault = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool {
            wasLaunchedAtLogin = !isDefault
        }

        previousExitWasUnclean = MainActor.assumeIsolated { CrashSentinel.armAndCheckPreviousExit() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { CrashSentinel.markCleanExit() }

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
    let urlSession: URLSession = .shared
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
            let (data, response) = try await urlSession.data(from: releaseNotesURL)
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

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.notification.request.content.categoryIdentifier
                == UpdateCompletionNotification.categoryIdentifier
        else { return }

        await MainActor.run {
            NotificationCenter.default.post(name: .openSwiftMinerReleaseNotes, object: nil)
        }
    }
}

enum UpdateCompletionNotification {
    static let categoryIdentifier = "app_update_completed"
    static let viewReleaseNotesActionIdentifier = "view_release_notes"

    static func registerCategory(center: UNUserNotificationCenter = .current()) {
        let viewReleaseNotes = UNNotificationAction(
            identifier: viewReleaseNotesActionIdentifier,
            title: "What’s New",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [viewReleaseNotes],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    static func makeRequest(
        for update: NavigationModel.CompletedUpdate
    ) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "SwiftMiner Updated"
        content.body = "Updated to \(update.currentVersion). Mining resumed automatically."
        content.categoryIdentifier = categoryIdentifier
        content.sound = .default
        content.userInfo = [
            "previousVersion": update.previousVersion,
            "currentVersion": update.currentVersion,
            "currentBuild": update.currentBuild
        ]

        return UNNotificationRequest(
            identifier: "swiftminer-update-\(update.currentVersion)-\(update.currentBuild)",
            content: content,
            trigger: nil
        )
    }

    static func deliver(
        _ update: NavigationModel.CompletedUpdate,
        center: UNUserNotificationCenter = .current()
    ) async {
        do {
            try await center.add(makeRequest(for: update))
        } catch {
            Logger.notifications.error("Failed to send the update completion notification: \(error.localizedDescription)")
        }
    }

    static func deliverPreview(
        bundle: Bundle = .main,
        center: UNUserNotificationCenter = .current()
    ) async {
        let currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "1.31.1"
        let currentBuild = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "debug"
        let preview = NavigationModel.CompletedUpdate(
            previousVersion: "Previous version",
            currentVersion: currentVersion,
            currentBuild: currentBuild
        )
        await deliver(preview, center: center)
    }
}

private extension Notification.Name {
    static let openSwiftMinerReleaseNotes = Notification.Name("OpenSwiftMinerReleaseNotes")
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
        case .watching:          return "bolt.fill"
        case .authenticating:    return "key.fill"
        case .fetchingCampaigns: return "arrow.clockwise"
        case .claiming:          return "gift.fill"
        case .error:             return "exclamationmark.triangle.fill"
        case .waitingForStream:  return "clock.fill"
        case .stopped, .idle:    return "stop.fill"
        case .paused:            return "clock.fill"
        case .idleNoEligibleCampaigns: return "pause.circle"
        case .blockedAccountNotLinked: return SystemSymbolCompatibility.resolvedName(for: "personalhotspot.slash")
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
