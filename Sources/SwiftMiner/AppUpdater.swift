import Foundation
import SwiftUI
#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
final class AppUpdater: NSObject, ObservableObject {
    enum UpdateChannel: String, CaseIterable, Identifiable {
        case stable
        case beta

        var id: String { rawValue }

        var label: String {
            switch self {
            case .stable:
                return "Stable"
            case .beta:
                return "Beta"
            }
        }

        var symbolName: String {
            switch self {
            case .stable:
                return "checkmark.seal"
            case .beta:
                return "flask.fill"
            }
        }
    }

    private static let updateChannelDefaultsKey = "SwiftMinerAppUpdateChannel"

    @Published private(set) var isConfigured = false
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var feedURLString = ""
    @Published private(set) var hasPublicKey = false
    @Published private(set) var bundlePath = Bundle.main.bundlePath
    @Published private(set) var selectedChannel: UpdateChannel = .stable
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false

#if canImport(Sparkle)
    private var updaterController: SPUStandardUpdaterController?
#endif
    private let stableFeedURL: String
    private let currentShortVersion: String
    private var autoCheckTask: Task<Void, Never>?
    var onError: ((Error) -> Void)?
    /// Called when an update check completes and the app is already current.
    var onUpToDate: (() -> Void)?
    /// Called when a downloaded update is ready. Arguments are the new version
    /// and a human-readable description of when it will install.
    var onAutoInstall: ((String, String) -> Void)?
    /// Answers whether installing (and relaunching) right now would interrupt
    /// active mining. Wired by the app; nil means "always safe".
    var isSafeToInstallNow: (() -> Bool)?

    init(bundle: Bundle = .main) {
        let persistedChannelRaw = UserDefaults.standard.string(forKey: Self.updateChannelDefaultsKey) ?? UpdateChannel.stable.rawValue
        let persistedChannel = UpdateChannel(rawValue: persistedChannelRaw) ?? .stable
        selectedChannel = persistedChannel

        let feedURL = (bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let publicKey = (bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let shortVersion = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let configured = !feedURL.isEmpty && !publicKey.isEmpty
        stableFeedURL = feedURL
        currentShortVersion = shortVersion

        super.init()

        feedURLString = Self.resolvedFeedURL(stableFeedURL: feedURL, channel: persistedChannel)
        hasPublicKey = !publicKey.isEmpty
        bundlePath = bundle.bundlePath
        isConfigured = configured

#if canImport(Sparkle)
        if configured {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: self,
                userDriverDelegate: nil
            )
            // Hands-free updates by default: check + download silently. One-time
            // seed so a user who later opts out in the Updates tab stays opted out.
            let autoDefaultsKey = "SwiftMinerAutoUpdateDefaultApplied"
            if !UserDefaults.standard.bool(forKey: autoDefaultsKey) {
                updaterController?.updater.automaticallyChecksForUpdates = true
                updaterController?.updater.automaticallyDownloadsUpdates = true
                UserDefaults.standard.set(true, forKey: autoDefaultsKey)
            }
            automaticallyChecksForUpdates = updaterController?.updater.automaticallyChecksForUpdates ?? false
            automaticallyDownloadsUpdates = updaterController?.updater.automaticallyDownloadsUpdates ?? false
            canCheckForUpdates = true
            updateAutoCheckLoop()
        } else {
            updaterController = nil
            canCheckForUpdates = false
            automaticallyChecksForUpdates = false
            automaticallyDownloadsUpdates = false
        }
#else
        canCheckForUpdates = false
        automaticallyChecksForUpdates = false
        automaticallyDownloadsUpdates = false
#endif
    }

    func checkForUpdates() {
#if canImport(Sparkle)
        updaterController?.checkForUpdates(nil)
#endif
    }

    func checkForUpdatesInBackground() {
#if canImport(Sparkle)
        updaterController?.updater.checkForUpdatesInBackground()
#endif
    }

    var releaseNotesURL: URL? {
        Self.releaseNotesURL(from: feedURLString, shortVersion: currentShortVersion)
    }

    func setAutomaticallyChecksForUpdates(_ isEnabled: Bool) {
#if canImport(Sparkle)
        updaterController?.updater.automaticallyChecksForUpdates = isEnabled
#endif
        automaticallyChecksForUpdates = isEnabled
        updateAutoCheckLoop()
    }

    func setAutomaticallyDownloadsUpdates(_ isEnabled: Bool) {
#if canImport(Sparkle)
        updaterController?.updater.automaticallyDownloadsUpdates = isEnabled
#endif
        automaticallyDownloadsUpdates = isEnabled
    }

    private func updateAutoCheckLoop() {
        if automaticallyChecksForUpdates {
            startAutoCheckLoop()
        } else {
            autoCheckTask?.cancel()
            autoCheckTask = nil
        }
    }

    private func startAutoCheckLoop() {
        autoCheckTask?.cancel()
        autoCheckTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000_000) // 5 minutes
                await MainActor.run {
                    self.checkForUpdatesInBackground()
                }
            }
        }
    }

    func setUpdateChannel(_ channel: UpdateChannel) {
        guard selectedChannel != channel else { return }
        selectedChannel = channel
        UserDefaults.standard.set(channel.rawValue, forKey: Self.updateChannelDefaultsKey)
        feedURLString = Self.resolvedFeedURL(stableFeedURL: stableFeedURL, channel: channel)
    }

    private static func resolvedFeedURL(stableFeedURL: String, channel: UpdateChannel) -> String {
        switch channel {
        case .stable:
            return stableFeedURL
        case .beta:
            return betaFeedURL(from: stableFeedURL)
        }
    }

    private static func betaFeedURL(from stableFeedURL: String) -> String {
        guard var components = URLComponents(string: stableFeedURL) else {
            return stableFeedURL
        }

        let path = components.path
        let betaPath: String
        if path.hasSuffix("/appcast.xml") {
            betaPath = String(path.dropLast("/appcast.xml".count)) + "/beta/appcast.xml"
        } else if path.hasSuffix("appcast.xml") {
            betaPath = String(path.dropLast("appcast.xml".count)) + "beta/appcast.xml"
        } else {
            betaPath = path.hasSuffix("/") ? path + "beta/appcast.xml" : path + "/beta/appcast.xml"
        }

        components.path = betaPath
        return components.url?.absoluteString ?? stableFeedURL
    }

    static func releaseNotesURL(from feedURLString: String, shortVersion: String) -> URL? {
        guard var components = URLComponents(string: feedURLString) else {
            return nil
        }

        let sanitizedVersion = shortVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = components.path
        if path.hasSuffix("/beta/appcast.xml") {
            components.path = String(path.dropLast("/beta/appcast.xml".count)) + "/release-notes/"
        } else if path.hasSuffix("/appcast.xml") {
            components.path = String(path.dropLast("/appcast.xml".count)) + "/release-notes/"
        } else if path.hasSuffix("appcast.xml") {
            components.path = String(path.dropLast("appcast.xml".count)) + "release-notes/"
        } else {
            components.path = path.hasSuffix("/") ? path + "release-notes/" : path + "/release-notes/"
        }

        if !sanitizedVersion.isEmpty {
            components.path += components.path.hasSuffix("/") ? "\(sanitizedVersion).html" : "/\(sanitizedVersion).html"
        }

        return components.url
    }
}

#if canImport(Sparkle)
extension AppUpdater: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        Self.resolvedFeedURL(stableFeedURL: stableFeedURL, channel: selectedChannel)
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        false
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let nsError = error as NSError
        if nsError.domain == "SUSparkleErrorDomain" {
            let code = nsError.code
            // Sparkle 2's SUNoUpdateError is 1001 — "no update" is success,
            // not failure. (4001/2401 kept from the old, incorrect mapping in
            // case older Sparkle builds report them.)
            if code == 1001 || code == 4001 || code == 2401 {
                onUpToDate?()
                return
            }
            // User-cancelled installs are not failures either.
            if code == 4003 || code == 2403 {
                return
            }
        }

        onError?(error)
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        true
    }

    /// Sparkle stages silently-downloaded updates to install "on quit" — but a
    /// 24/7 miner never quits, so without this hook automatic updates would
    /// never actually complete. Returning true and invoking the block installs
    /// the update now; Sparkle relaunches the app afterwards and mining
    /// auto-resumes on startup.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        Task { @MainActor in
            let settings = Settings.shared
            switch settings.autoUpdateInstallPolicy {
            case .immediate:
                self.onAutoInstall?(version, "installing now")
                // Give the log line a moment to land before the relaunch.
                try? await Task.sleep(for: .seconds(2))

            case .whenIdle:
                if self.isSafeToInstallNow?() ?? true {
                    self.onAutoInstall?(version, "miners are idle — installing now")
                    try? await Task.sleep(for: .seconds(2))
                } else {
                    self.onAutoInstall?(version, "waiting for miners to finish (installs within 24h regardless)")
                    // Poll each minute; install at first idle moment, or after
                    // 24h so a nonstop miner can't defer updates forever.
                    let deadline = Date().addingTimeInterval(24 * 60 * 60)
                    while Date() < deadline, !(self.isSafeToInstallNow?() ?? true) {
                        try? await Task.sleep(for: .seconds(60))
                    }
                }

            case .scheduled:
                if let target = Calendar.current.nextDate(
                    after: Date(),
                    matching: DateComponents(hour: settings.autoUpdateInstallHour, minute: 0),
                    matchingPolicy: .nextTime
                ) {
                    self.onAutoInstall?(version, "installing at \(target.formatted(date: .omitted, time: .shortened))")
                    // One-minute steps so Mac sleep can't stretch a long sleep
                    // past the window.
                    while Date() < target {
                        try? await Task.sleep(for: .seconds(60))
                    }
                } else {
                    self.onAutoInstall?(version, "installing now")
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            immediateInstallationBlock()
        }
        return true
    }
}
#endif
