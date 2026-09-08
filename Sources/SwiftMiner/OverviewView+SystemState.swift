import SwiftUI
import SwiftMinerCore
import AppKit

#if DEBUG
/// Reproducible, privacy-safe data for README and website captures.
///
/// The fixture deliberately starts from Twitch campaign records already cached
/// by the app, so names, reward metadata and artwork stay authentic. It only
/// changes the time window and progress to present those claimed/history
/// campaigns as a lively five-miner fleet. Nothing here exists in Release.
enum MarketingScreenshotFixture {
    static let environmentKey = "SWIFTMINER_MARKETING_SCREENSHOTS"
    static let usernames = ["quietcomet", "Pixelpanda", "nightowl", "emberfox", "saltmarsh"]

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment[environmentKey] == "1"
    }

    /// How many sample miners the fixture presents, via
    /// `SWIFTMINER_MARKETING_MINERS`. The landing hero wants a calm two-card
    /// fleet while the multi-account shot wants the full five, and both are
    /// captured from the same build — so the count belongs in the environment
    /// beside the switch that turns the fixture on, not baked into the array.
    static var minerCount: Int {
        guard let raw = ProcessInfo.processInfo.environment["SWIFTMINER_MARKETING_MINERS"],
              let requested = Int(raw) else { return usernames.count }
        return min(max(requested, 1), usernames.count)
    }

    /// Local portraits stay stable across captures and never use real account photos.
    /// Index-aligned with `usernames`, so reordering the fleet means reordering
    /// both together or every miner swaps face.
    static let avatarNames = [
        "DebugAvatarAnimeGirl", "DebugAvatarPixelPanda", "DebugAvatarCorgi",
        "DebugAvatarBowCat", "DebugAvatarYellowDuck"
    ]

    static let discordAvatarNames = avatarNames.map { $0 + "Discord" }

    private static func profileIndex(forAccountId accountId: String) -> Int? {
        guard isEnabled else { return nil }
        return usernames.indices.first { accountId == "marketing-account-\($0)" }
    }

    /// Fixture portraits ship as loose bundle resources, and Release strips them,
    /// so every lookup has to tolerate the file simply not being there.
    static func bundledAvatarURL(named name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "png")
    }

    static func avatarURL(forAccountId accountId: String) -> URL? {
        guard let index = profileIndex(forAccountId: accountId) else { return nil }
        return bundledAvatarURL(named: avatarNames[index])
    }

    /// Not every portrait has a drawn Discord counterpart. Where one is missing,
    /// the miner's own picture stands in rather than leaving the Discord row
    /// showing the generic placeholder mid-capture.
    static func discordAvatarURL(forAccountId accountId: String) -> URL? {
        guard let index = profileIndex(forAccountId: accountId) else { return nil }
        return bundledAvatarURL(named: discordAvatarNames[index])
            ?? bundledAvatarURL(named: avatarNames[index])
    }

    // MARK: - Activity log

    // The fleet substitution covers views that render `ManagedMiner`. The
    // Activity Log does not: it renders stored log text, so real account names
    // and the operator's own dashboard host arrive as free text and survive
    // everything above. `LogRedactor` is the wrong tool here — it exists to
    // blank secrets for diagnostic export, and `<redacted>` in a marketing
    // screenshot looks like a bug. These substitute instead: same rows, same
    // wording, fictional names.

    /// Row labels. Real miner ids keep their identity as keys so filtering and
    /// selection still work; only the name shown changes.
    static func minerNames(replacing real: [String: String]) -> [String: String] {
        guard isEnabled else { return real }
        return real.keys.sorted().enumerated().reduce(into: [:]) { mapped, pair in
            mapped[pair.element] = usernames[pair.offset % usernames.count]
        }
    }

    /// Pairs each real username with the fixture name that replaced it, so a log
    /// line naming an account is rewritten the same way its row label was.
    private static func nameSubstitutions(from real: [String: String]) -> [(String, String)] {
        real.keys.sorted().enumerated().compactMap { offset, id in
            guard let actual = real[id]?.trimmingCharacters(in: .whitespaces), !actual.isEmpty else {
                return nil
            }
            return (actual, usernames[offset % usernames.count])
        }
    }

    static func sanitisedEvents(_ events: [EventEntry], realNames: [String: String]) -> [EventEntry] {
        guard isEnabled else { return events }
        let substitutions = nameSubstitutions(from: realNames)
        return events.map { event in
            EventEntry(
                id: event.id,
                timestamp: event.timestamp,
                message: sanitised(event.message, substitutions: substitutions),
                level: event.level,
                minerId: event.minerId,
                rawMessage: event.rawMessage.map { sanitised($0, substitutions: substitutions) },
                category: event.category
            )
        }
    }

    private static let hostPattern = try? NSRegularExpression(
        pattern: #"https?://([A-Za-z0-9.\-]+)"#,
        options: [.caseInsensitive]
    )

    private static func sanitised(_ text: String, substitutions: [(String, String)]) -> String {
        var result = text
        for (real, replacement) in substitutions {
            result = result.replacingOccurrences(of: real, with: replacement, options: [.caseInsensitive])
        }

        // Whatever host the operator actually runs their dashboard on is theirs.
        // Twitch's own URLs are part of what the log legitimately says, so they
        // stay; everything else becomes the product's public domain.
        guard let hostPattern else { return result }
        let matches = hostPattern.matches(
            in: result,
            range: NSRange(result.startIndex..<result.endIndex, in: result)
        )
        for match in matches.reversed() {
            guard match.numberOfRanges > 1,
                  let hostRange = Range(match.range(at: 1), in: result) else { continue }
            let host = String(result[hostRange])
            guard host != "swiftminer.app",
                  !host.hasSuffix("twitch.tv"),
                  !host.hasSuffix("twitchcdn.net") else { continue }
            result.replaceSubrange(hostRange, with: "swiftminer.app")
        }
        return result
    }

    static func discordID(forAccountId accountId: String) -> String? {
        guard let index = profileIndex(forAccountId: accountId) else { return nil }
        return String(100_000_000_000_000_001 + index)
    }

    private static let avatarImages: [URL: NSImage] = Dictionary(
        uniqueKeysWithValues: (avatarNames + discordAvatarNames).compactMap { name in
            guard let url = bundledAvatarURL(named: name),
                  let image = NSImage(contentsOf: url) else { return nil }
            return (url, image)
        }
    )

    static func avatarImage(for url: URL?) -> NSImage? {
        guard isEnabled, let url else { return nil }
        return avatarImages[url]
    }

    static func miners(from realMiners: [MinerManager.ManagedMiner]) -> [MinerManager.ManagedMiner] {
        guard isEnabled, !realMiners.isEmpty else { return realMiners }

        let targetCount = minerCount
        let campaignPool = selectedCampaigns(from: realMiners.flatMap(\.allCampaigns), count: targetCount)
        guard !campaignPool.isEmpty else { return realMiners }

        let names = usernames
        let progressFractions = [0.38, 0.62, 0.27, 0.74, 0.51]
        let now = Date()

        return (0..<targetCount).map { minerIndex in
            let campaigns = (0..<min(3, campaignPool.count)).map { queueIndex in
                makeLiveCampaign(
                    campaignPool[(minerIndex + queueIndex) % campaignPool.count],
                    minerIndex: minerIndex,
                    queueIndex: queueIndex,
                    progressFraction: queueIndex == 0 ? progressFractions[minerIndex] : 0
                )
            }
            let current = campaigns[0]

            return MinerManager.ManagedMiner(
                id: "marketing-\(minerIndex)-\(names[minerIndex])",
                accountId: "marketing-account-\(minerIndex)",
                username: names[minerIndex],
                ownerDiscordId: discordID(forAccountId: "marketing-account-\(minerIndex)"),
                status: .watching,
                needsAuth: false,
                currentCampaign: current.name,
                currentCampaignId: current.id,
                allCampaigns: campaigns,
                dropsClaimed: 4 + minerIndex * 3,
                isRunning: true,
                priorityGames: campaigns.map(\.game.name),
                lastEventAt: now.addingTimeInterval(-Double(8 + minerIndex * 3)),
                lastSuccessfulPollAt: now.addingTimeInterval(-Double(6 + minerIndex * 2)),
                lastCampaignRefreshAt: now.addingTimeInterval(-Double(42 + minerIndex * 7)),
                lastDropProgressAt: now.addingTimeInterval(-Double(25 + minerIndex * 4)),
                workerStartedAt: now.addingTimeInterval(-Double(6_600 + minerIndex * 840)),
                workerState: .running,
                isHealthy: true,
                isStalled: false,
                isOperator: minerIndex == 0
            )
        }
    }

    /// Prefer recognisable, real campaigns in a stable order so successive
    /// captures do not reshuffle. Extra slots draw from other cached campaigns
    /// with real reward data and one campaign per game.
    private static func selectedCampaigns(from campaigns: [Campaign], count: Int) -> [Campaign] {
        let preferredGames = [
            "THE FINALS",
            "ARC Raiders",
            "Battlefield 6",
            "Halo Infinite",
            "Call of Duty: Modern Warfare 4"
        ]
        var selected: [Campaign] = []
        var selectedGames = Set<String>()

        for gameName in preferredGames {
            guard let campaign = campaigns.first(where: {
                $0.game.name.localizedCaseInsensitiveCompare(gameName) == .orderedSame
                    && !$0.drops.isEmpty
            }) else { continue }
            selected.append(campaign)
            selectedGames.insert(campaign.game.name.lowercased())
        }

        for campaign in campaigns where selected.count < count && !campaign.drops.isEmpty {
            guard selectedGames.insert(campaign.game.name.lowercased()).inserted else { continue }
            selected.append(campaign)
        }

        return selected
    }

    private static func makeLiveCampaign(
        _ source: Campaign,
        minerIndex: Int,
        queueIndex: Int,
        progressFraction: Double
    ) -> Campaign {
        let campaignId = "marketing-\(minerIndex)-\(queueIndex)-\(source.id)"
        var drops = source.drops

        for index in drops.indices {
            let requiredMinutes = max(30, drops[index].requiredMinutes)
            let isCurrentDrop = queueIndex == 0 && index == 0
            let currentMinutes = isCurrentDrop
                ? max(1, min(requiredMinutes - 1, Int(Double(requiredMinutes) * progressFraction)))
                : 0
            drops[index].isClaimed = false
            drops[index].progress = Progress(
                id: "\(campaignId)-\(drops[index].id)",
                dropId: drops[index].id,
                dropName: drops[index].name,
                campaignId: campaignId,
                currentMinutes: currentMinutes,
                requiredMinutes: requiredMinutes,
                lastUpdated: Date()
            )
        }

        return Campaign(
            id: campaignId,
            name: source.name,
            game: source.game,
            status: .active,
            startDate: Date().addingTimeInterval(-2 * 24 * 60 * 60),
            endDate: Date().addingTimeInterval(Double(5 + queueIndex) * 24 * 60 * 60),
            drops: drops,
            channels: source.channels,
            isAccountConnected: true,
            allowIsEnabled: source.allowIsEnabled,
            isPrioritised: true
        )
    }
}

#Preview("Debug Profile Pictures") {
    HStack(alignment: .top, spacing: 20) {
        ForEach(MarketingScreenshotFixture.usernames.indices, id: \.self) { index in
            VStack(spacing: 12) {
                Text(MarketingScreenshotFixture.usernames[index])
                    .font(.headline)
                ForEach([false, true], id: \.self) { isDiscord in
                    let name = isDiscord
                        ? MarketingScreenshotFixture.discordAvatarNames[index]
                        : MarketingScreenshotFixture.avatarNames[index]
                    VStack(spacing: 4) {
                        if let url = MarketingScreenshotFixture.bundledAvatarURL(named: name),
                           let image = NSImage(contentsOf: url) {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 96, height: 96)
                                .clipShape(Circle())
                        } else {
                            // Names the gap instead of collapsing the row, so a
                            // portrait that was never drawn is obvious here.
                            Circle()
                                .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4]))
                                .frame(width: 96, height: 96)
                                .overlay {
                                    Text("Missing")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                        }
                        Text(isDiscord ? "Discord" : "Miner")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    .padding(24)
}
#endif

/// The campaign data behind Overview, and the miner list it renders.
extension OverviewView {
    // MARK: - Fleet

    /// Miners the Overview renders. Normally exactly the real ones; in DEBUG it
    /// can be padded for marketing screenshots.
    var displayedMiners: [MinerManager.ManagedMiner] {
        SwiftMinerFleet.displayedMiners(from: navigation.minerManager.miners)
    }

    /// Assigns only when the data actually changed, so refresh storms that
    /// produce an identical campaign array don't invalidate the whole overview.
    func applyOverviewCampaigns(_ fresh: [CampaignViewData]) {
        guard fresh != overviewCampaigns else { return }
        setOverviewCampaigns(fresh)
    }

    private func setOverviewCampaigns(_ fresh: [CampaignViewData]) {
        overviewCampaigns = fresh
        visibleCampaigns = Self.campaignsExcludingHiddenGames(in: fresh, excludedGames: settings.excludedGames)
    }

    static func campaignsExcludingHiddenGames(
        in campaigns: [CampaignViewData],
        excludedGames: [String]
    ) -> [CampaignViewData] {
        guard !excludedGames.isEmpty else { return campaigns }
        let index = GameMatchIndex(
            gamePreferences: [],
            priorityGames: [],
            excludedGames: excludedGames
        )
        return campaigns.filter { !index.isExcluded(gameName: $0.gameName) }
    }

    func refreshSummary() async {
        isRefreshing = true
        if overviewCampaigns.isEmpty && !navigation.minerManager.dataCoordinator.lastKnownAllCampaigns.isEmpty {
            setOverviewCampaigns(navigation.minerManager.dataCoordinator.lastKnownAllCampaigns)
        }
        applyOverviewCampaigns(await navigation.minerManager.dataCoordinator.allCampaigns())
        isRefreshing = false
    }

    func refreshFromOverview() async {
        isRefreshing = true
        defer { isRefreshing = false }

        await navigation.restartMinersAndRefreshOverviewData()

        applyOverviewCampaigns(await navigation.minerManager.dataCoordinator.allCampaigns())
    }

    func presentCustomArtworkImporter(for game: Game) {
        customArtworkImportGame = game
        DispatchQueue.main.async {
            isShowingArtworkImporter = true
        }
    }
}
