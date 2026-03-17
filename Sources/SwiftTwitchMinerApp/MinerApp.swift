import SwiftUI
import SwiftTwitchMiner
import UserNotifications

@main
struct MinerApp: App {

    @State private var appModel = AppModel(clientId: ClientConfiguration.clientId)

    var body: some Scene {
        // Main window
        WindowGroup {
            ContentView()
                .environment(appModel)
                .task {
                    await appModel.setup()
                    await requestNotificationPermission()
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
            CommandGroup(after: .appSettings) {
                Button("Claim All Drops") {
                    Task { await appModel.claimAllDrops() }
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])

                Button("Start All Miners") {
                    Task { await appModel.startAll() }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button("Stop All Miners") {
                    Task { await appModel.stopAll() }
                }
                .keyboardShortcut("x", modifiers: [.command, .shift])

                Button("Refresh Progress") {
                    Task { await appModel.refreshProgress() }
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }

        // Menu bar extra — always present so the app can run in the background.
        MenuBarExtra {
            MenuBarContent()
                .environment(appModel)
        } label: {
            MenuBarLabel()
                .environment(appModel)
        }
        .menuBarExtraStyle(.menu)

        // Settings window (macOS 14+ Settings scene)
        SwiftUI.Settings {
            SettingsView()
                .padding()
        }
    }

    private func requestNotificationPermission() async {
        guard Settings.shared.showClaimNotifications else { return }
        try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
}

// MARK: - Menu bar label

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        // Use a filled/unfilled icon to indicate active vs idle state
        // Show badge count for active miners
        Image(systemName: appModel.activeMiners > 0 ? "gift.fill" : "gift")
    }
}

// MARK: - Menu bar content

struct MenuBarContent: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Group {
            // Status header
            Label(statusText, systemImage: statusIcon)
                .foregroundStyle(.secondary)

            Divider()

            // Quick stats
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

            // Actions
            Button("Start All") {
                Task { await appModel.startAll() }
            }
            .disabled(appModel.activeMiners == appModel.totalMiners)

            Button("Stop All") {
                Task { await appModel.stopAll() }
            }
            .disabled(appModel.activeMiners == 0)

            Button("Claim All Drops") {
                Task { await appModel.claimAllDrops() }
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])

            Divider()

            Button("Open Dashboard") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
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
            return "All miners stopped"
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
        case .stopped, .idle:    return "stop.fill"
        case .paused:            return "pause.fill"
        }
    }
}

// MARK: - Build-time configuration

enum ClientConfiguration {
    /// Override via the `TWITCH_CLIENT_ID` environment variable or replace this default.
    /// Using Twitch's Android client ID is required for device flow to work with GQL.
    static let clientId = ProcessInfo.processInfo.environment["TWITCH_CLIENT_ID"] ?? "kd1unb4b3q4t58fwlpcbzcbnm76a8fp"
}
