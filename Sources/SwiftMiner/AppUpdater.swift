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

#if canImport(Sparkle)
    private var updaterController: SPUStandardUpdaterController?
#endif
    private let stableFeedURL: String
    private var autoCheckTask: Task<Void, Never>?

    init(bundle: Bundle = .main) {
        let persistedChannelRaw = UserDefaults.standard.string(forKey: Self.updateChannelDefaultsKey) ?? UpdateChannel.stable.rawValue
        let persistedChannel = UpdateChannel(rawValue: persistedChannelRaw) ?? .stable
        selectedChannel = persistedChannel

        let feedURL = (bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let publicKey = (bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let configured = !feedURL.isEmpty && !publicKey.isEmpty
        stableFeedURL = feedURL

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
            updaterController?.updater.automaticallyChecksForUpdates = true
            updaterController?.updater.automaticallyDownloadsUpdates = true
            canCheckForUpdates = true
            startAutoCheckLoop()
        } else {
            updaterController = nil
            canCheckForUpdates = false
        }
#else
        canCheckForUpdates = false
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
}

#if canImport(Sparkle)
extension AppUpdater: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        Self.resolvedFeedURL(stableFeedURL: stableFeedURL, channel: selectedChannel)
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        false
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        true
    }
}
#endif
