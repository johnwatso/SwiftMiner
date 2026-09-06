import AppKit
import SwiftUI
import SwiftMinerCore

/// SwiftMiner's About window.
///
/// Replaces `NSApp.orderFrontStandardAboutPanel`, which cannot separate the
/// version line from the build, tuck the engine stamp underneath it, or carry a
/// footer control. The layout deliberately keeps the standard panel's shape —
/// a narrow, vertically centred column of app identity, version, and a couple of
/// small links — so it still reads as a macOS About window rather than an
/// information page.
struct AboutWindow: View {
    @EnvironmentObject private var updater: AppUpdater

    private let metadata = AboutMetadata()

    var body: some View {
        VStack(spacing: 0) {
            identity
                .padding(.top, 30)
                .padding(.horizontal, 24)
                .padding(.bottom, 22)

            Divider()

            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
            .padding(.vertical, 14)
        }
        .frame(width: 300)
    }

    private var identity: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            Text("SwiftMiner")
                .font(.system(size: 20, weight: .semibold))
                .padding(.top, 12)

            Text("Native Twitch Drops mining for macOS")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 3)

            // Which build is installed, and — a step quieter — whether the mining
            // logic inside it has actually moved since the last one.
            VStack(spacing: 2) {
                Text(metadata.versionLine)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(metadata.engineLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .multilineTextAlignment(.center)
            .padding(.top, 14)

            website
                .padding(.top, 14)

            madeInNZ
                .padding(.top, 10)
        }
        .textSelection(.enabled)
    }

    private var website: some View {
        HStack(spacing: 4) {
            Image(systemName: "globe")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Link("swiftminer.app", destination: AboutMetadata.websiteURL)
        }
        .font(.system(size: 11))
    }

    private var madeInNZ: some View {
        (
            Text("Made in NZ ").foregroundStyle(.secondary)
                + Text(Image(systemName: "heart.fill")).foregroundStyle(.red)
        )
        .font(.system(size: 11))
        .accessibilityLabel("Made in New Zealand with love")
    }
}

/// The strings the About window shows, read from the running bundle and the
/// engine stamp rather than hardcoded.
struct AboutMetadata {
    static let websiteURL = URL(string: "https://swiftminer.app")!

    let versionLine: String
    let engineLine: String

    init(bundle: Bundle = .main) {
        self.init(
            shortVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            engineVersion: MinerEngineVersion.current,
            engineUpdated: MinerEngineVersion.updated
        )
    }

    init(shortVersion: String?, build: String?, engineVersion: String, engineUpdated: String) {
        let version = shortVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let build = build?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        versionLine = [
            version.isEmpty ? nil : "Version \(version)",
            build.isEmpty ? nil : "Build \(build)"
        ]
        .compactMap { $0 }
        .joined(separator: " · ")

        engineLine = "Engine \(engineVersion) · Updated \(Self.displayDate(from: engineUpdated))"
    }

    /// `"2026-09-05"` → `"5 Sep 2026"`. The stamp is stored ISO so it sorts and
    /// diffs cleanly; only this window renders it for people to read. An
    /// unparseable value is passed through rather than dropped.
    static func displayDate(from isoDate: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"

        guard let date = formatter.date(from: isoDate) else { return isoDate }

        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }
}

/// Hosts ``AboutWindow`` in a panel with the standard About-panel chrome.
///
/// A SwiftUI `Window` scene would be less code, but macOS presents those at
/// launch until the user has closed one — an About window that shows itself on
/// first run is worse than the AppKit shell. A panel also brings the details
/// people expect here for free: Escape closes it, and it stays out of the
/// Window menu.
@MainActor
final class AboutWindowController {
    static let shared = AboutWindowController()

    private var panel: NSPanel?

    private init() {}

    func show(updater: AppUpdater) {
        let panel = panel ?? makePanel(updater: updater)
        self.panel = panel

        if !panel.isVisible {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makePanel(updater: AppUpdater) -> NSPanel {
        let content = NSHostingController(
            rootView: AboutWindow().environmentObject(updater)
        )
        let panel = NSPanel(contentViewController: content)
        panel.styleMask = [.titled, .closable, .fullSizeContentView]
        panel.title = "About SwiftMiner"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.isExcludedFromWindowsMenu = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        return panel
    }
}
