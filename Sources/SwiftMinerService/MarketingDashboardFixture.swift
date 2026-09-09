#if DEBUG
import Foundation
import SwiftMinerCore

/// Reproducible, privacy-safe data for web dashboard captures.
///
/// The app's `MarketingScreenshotFixture` substitutes the fleet inside SwiftUI
/// views and never reaches this target, so the dashboard would otherwise render
/// the operator's real accounts — the exact thing the app-side fixture exists to
/// avoid. This is the same idea one layer down: the routes, the page and the
/// client script are the shipping ones, and only the projection they render is
/// invented.
///
/// It deliberately presents the **member** view. An operator session lands on
/// the all-miners overview, which is a fleet management screen; the picture the
/// landing page wants is what a person sees about their own miner.
///
/// Enabled by the same `SWIFTMINER_MARKETING_SCREENSHOTS=1` as the app, so one
/// launch produces both sets of captures.
enum MarketingDashboardFixture {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["SWIFTMINER_MARKETING_SCREENSHOTS"] == "1"
    }

    /// Kept in step with `MarketingScreenshotFixture` in the app target by hand.
    /// The two cannot share a constant — the app depends on this library, not
    /// the other way round — and one name is a small enough surface to duplicate
    /// rather than push a marketing detail down into SwiftMinerCore.
    static let username = "quietcomet"
    static let discordHandle = "quietcomet.drops"
    static let sharedPriorityOwnerHandle = "Pixelpanda"
    static let accountId = "marketing-account-0"
    static let discordUserId = "100000000000000001"

    /// Portrait bytes, read from the app bundle that hosts this service. The
    /// PNGs are Debug-only resources, so this is nil whenever they were stripped
    /// and the dashboard falls back to its own placeholder.
    static let avatarPNG: Data? = {
        guard let url = Bundle.main.url(forResource: "DebugAvatarAnimeGirl", withExtension: "png") else {
            return nil
        }
        return try? Data(contentsOf: url)
    }()

    static let avatarPath = "/app/debug-avatar.png"

    /// Prepended to the dashboard script only while the fixture is on. The
    /// avatar guard reads this global; where it is undeclared the guard behaves
    /// exactly as it always has.
    static var scriptPrelude: String {
        "var MARKETING_PORTRAIT = \"\(avatarPath)\";\n"
    }

    /// The game the example miner is watching. Named here because the campaign,
    /// the completed drops and the box-art lookup all have to agree on it.
    static let activeGame = "THE FINALS"
    static let activeCampaignName = "DEEP SIGNAL EVENT"

    /// A session for capture. Reaching the dashboard normally means completing
    /// a Discord or Twitch sign-in, which a screenshot pass should not have to
    /// do — and must not do against someone's real account. Presented as a
    /// Discord principal because that is the route a member arrives by, and it
    /// is what keeps the operator chrome off the page.
    static func session() -> WebSessionRecord {
        WebSessionRecord(
            id: "marketing-screenshot-session",
            principalType: "discord",
            principalId: discordUserId,
            csrfToken: "marketing-screenshot-csrf",
            expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970
        )
    }

    /// - Parameter shared: the operator's real pinned games and their artwork,
    ///   so the queue shown here matches the app on the same page. Falls back to
    ///   naming the games without art rather than inventing URLs that 404.
    static func projection(
        shared: (games: [String], artwork: [String: String]) = ([], [:])
    ) -> DiscordUserProjection {
        let now = Date()
        let artwork = shared.artwork
        func art(_ game: String) -> String? { artwork[game.lowercased()] }
        return DiscordUserProjection(
            discordUserId: discordUserId,
            state: .active,
            account: DiscordUserProjection.Account(
                twitchAccountId: accountId,
                username: username,
                nickname: nil,
                profileImageURL: URL(string: avatarPath),
                discordProfileImageURL: URL(string: avatarPath),
                prefersDiscordProfileImage: false
            ),
            activeCampaign: DiscordUserProjection.ActiveCampaign(
                campaignId: "marketing-the-finals",
                game: activeGame,
                progress: DiscordUserProjection.Progress(current: 133, required: 180, unit: "minutes", pct: 74),
                endsAt: now.addingTimeInterval(5 * 24 * 60 * 60),
                boxArtURL: art(activeGame),
                currentChannelName: nil,
                currentChannelId: nil
            ),
            recentCompletedCampaigns: [
                DiscordUserProjection.RecentCampaign(
                    campaignId: "marketing-arc-raiders",
                    campaignName: "Live Update 1.42.0",
                    game: "ARC Raiders",
                    completedAt: now.addingTimeInterval(-6 * 60 * 60),
                    claimedDrops: 2,
                    totalDrops: 2,
                    boxArtURL: art("ARC Raiders")
                ),
                DiscordUserProjection.RecentCampaign(
                    campaignId: "marketing-halo",
                    campaignName: "Forge Showcase",
                    game: "Halo Infinite",
                    completedAt: now.addingTimeInterval(-30 * 60 * 60),
                    claimedDrops: 2,
                    totalDrops: 2,
                    boxArtURL: art("Halo Infinite")
                )
            ],
            dropsClaimedThisWeek: 11,
            issues: [],
            dmState: DiscordDMState(),
            priorityGames: shared.games,
            priorityGameArtwork: artwork,
            personalPriorityGames: [],
            includesGlobalPriorityGames: true,
            prioritySource: "global",
            excludedGames: [],
            configuredMinerCount: 5,
            sharedPriorityOwner: DiscordUserProjection.PriorityOwner(
                handle: sharedPriorityOwnerHandle,
                source: .discord
            ),
            diagnostics: nil
        )
    }
}
#endif
