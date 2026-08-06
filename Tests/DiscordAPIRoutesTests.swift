import Foundation
import SQLite3
import XCTest
@testable import SwiftMinerService
import SwiftMinerCore

final class DiscordAPIRoutesTests: XCTestCase {
    private let discordUserId = "123456789012345678"

    func testRegisterUserIsIdempotentAndReturnsDMState() async throws {
        let harness = try await RouteHarness()

        let first = await harness.router.handle(HTTPRequest(
            method: "POST",
            path: "/v1/users",
            headers: [:],
            body: #"{"discordUserId":"123456789012345678"}"#.data(using: .utf8)!
        ))
        XCTAssertEqual(first.statusCode, 201)

        let firstPayload = try decodeJSON(first.body)
        XCTAssertEqual(firstPayload["status"] as? String, "registered")
        XCTAssertEqual(firstPayload["discord_user_id"] as? String, discordUserId)

        let second = await harness.router.handle(HTTPRequest(
            method: "POST",
            path: "/v1/users",
            headers: [:],
            body: #"{"discordUserId":"123456789012345678"}"#.data(using: .utf8)!
        ))
        XCTAssertEqual(second.statusCode, 200)

        let secondPayload = try decodeJSON(second.body)
        XCTAssertEqual(secondPayload["status"] as? String, "already_registered")
        let dmState = try XCTUnwrap(secondPayload["dm_state"] as? [String: Any])
        XCTAssertEqual(dmState["has_received_welcome_message"] as? Bool, false)
        XCTAssertEqual(dmState["has_completed_initial_dm_flow"] as? Bool, false)
    }

    func testUpdateDMStatePreservesUnspecifiedFields() async throws {
        let harness = try await RouteHarness()
        try await harness.registerUser(discordUserId)

        let response = await harness.router.handle(HTTPRequest(
            method: "PATCH",
            path: "/v1/users/\(discordUserId)/dm-state",
            headers: [:],
            body: #"{"has_received_welcome_message":true}"#.data(using: .utf8)!
        ))
        XCTAssertEqual(response.statusCode, 200)

        let payload = try decodeJSON(response.body)
        let dmState = try XCTUnwrap(payload["dm_state"] as? [String: Any])
        XCTAssertEqual(dmState["has_received_welcome_message"] as? Bool, true)
        XCTAssertEqual(dmState["has_completed_initial_dm_flow"] as? Bool, false)
    }

    func testMinerControlRequiresRegisteredUserAndDelegatesValidActions() async throws {
        let harness = try await RouteHarness()
        let recorder = MinerControlRecorder()
        await harness.routes.setOnMinerControl { discordUserId, action in
            await recorder.record(discordUserId: discordUserId, action: action)
            return MinerControlResponse(
                ok: true,
                action: action.rawValue,
                state: "WATCHING",
                twitchUsername: "miner",
                message: "Watching THE FINALS"
            )
        }

        let missingUser = await harness.router.handle(HTTPRequest(
            method: "POST",
            path: "/v1/users/\(discordUserId)/miner/status",
            headers: [:],
            body: Data()
        ))
        XCTAssertEqual(missingUser.statusCode, 404)
        let initialCallCount = await recorder.callCount()
        XCTAssertEqual(initialCallCount, 0)

        try await harness.registerUser(discordUserId)

        let response = await harness.router.handle(HTTPRequest(
            method: "POST",
            path: "/v1/users/\(discordUserId)/miner/status",
            headers: [:],
            body: Data()
        ))
        XCTAssertEqual(response.statusCode, 200)
        let recordedActions = await recorder.actions()
        XCTAssertEqual(recordedActions, [.status])

        let payload = try decodeJSON(response.body)
        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(payload["state"] as? String, "WATCHING")
        XCTAssertEqual(payload["twitchUsername"] as? String, "miner")
    }

    func testMinerControlReturnsConflictWhenDelegateRejectsAction() async throws {
        let harness = try await RouteHarness()
        try await harness.registerUser(discordUserId)
        await harness.routes.setOnMinerControl { _, action in
            MinerControlResponse(
                ok: false,
                action: action.rawValue,
                state: "not_linked",
                twitchUsername: nil,
                message: "No linked Twitch account was found."
            )
        }

        let response = await harness.router.handle(HTTPRequest(
            method: "POST",
            path: "/v1/users/\(discordUserId)/miner/resume",
            headers: [:],
            body: Data()
        ))
        XCTAssertEqual(response.statusCode, 409)

        let payload = try decodeJSON(response.body)
        XCTAssertEqual(payload["ok"] as? Bool, false)
        XCTAssertEqual(payload["state"] as? String, "not_linked")
    }

    func testPauseLinkWarningRequiresRegisteredUserAndDelegates() async throws {
        let harness = try await RouteHarness()
        let recorder = LinkWarningPauseRecorder()
        await harness.routes.setOnPauseLinkWarning { discordUserId, gameName, expiresAt in
            await recorder.record(discordUserId: discordUserId, gameName: gameName, expiresAt: expiresAt)
            return true
        }

        let missingUser = await harness.router.handle(HTTPRequest(
            method: "POST",
            path: "/v1/users/\(discordUserId)/link-warnings/Black%20Ops%207/pause",
            headers: [:],
            body: #"{"days":7}"#.data(using: .utf8)!
        ))
        XCTAssertEqual(missingUser.statusCode, 404)
        let missingCallCount = await recorder.callCount()
        XCTAssertEqual(missingCallCount, 0)

        try await harness.registerUser(discordUserId)

        let response = await harness.router.handle(HTTPRequest(
            method: "POST",
            path: "/v1/users/\(discordUserId)/link-warnings/Black%20Ops%207/pause",
            headers: [:],
            body: #"{"days":7}"#.data(using: .utf8)!
        ))
        XCTAssertEqual(response.statusCode, 200)
        let callCount = await recorder.callCount()
        let pausedGames = await recorder.games()
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(pausedGames, ["Black Ops 7"])

        let payload = try decodeJSON(response.body)
        XCTAssertEqual(payload["paused"] as? Bool, true)
        XCTAssertEqual(payload["game"] as? String, "Black Ops 7")
        XCTAssertNotNil(payload["expiresAt"] as? String)
    }

    func testPriorityUpdateRequiresRegisteredUserAndDelegates() async throws {
        let harness = try await RouteHarness()
        try await harness.registerUser(discordUserId)
        let recorder = PriorityUpdateRecorder()
        await harness.routes.setOnPrioritiseGame { discordUserId, accountId, gameName in
            await recorder.record(discordUserId: discordUserId, accountId: accountId, gameName: gameName)
            return [gameName, "THE FINALS"]
        }

        let response = await harness.router.handle(HTTPRequest(
            method: "POST",
            path: "/v1/users/\(discordUserId)/miners/account-1/priorities",
            headers: [:],
            body: #"{"game_name":"Black Ops 7","placement":"top"}"#.data(using: .utf8)!
        ))

        XCTAssertEqual(response.statusCode, 200)
        let priorityGames = await recorder.games()
        XCTAssertEqual(priorityGames, ["Black Ops 7"])
        let payload = try decodeJSON(response.body)
        XCTAssertEqual(payload["prioritised"] as? Bool, true)
        XCTAssertEqual(payload["account_id"] as? String, "account-1")
        XCTAssertEqual(payload["game_name"] as? String, "Black Ops 7")
        XCTAssertEqual(payload["priority_games"] as? [String], ["Black Ops 7", "THE FINALS"])
    }

    func testWebCampaignsReturnsConfiguredCampaignSummaries() async throws {
        let harness = try await RouteHarness()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = Date(timeIntervalSince1970: 1_800_086_400)
        await harness.routes.setOnCampaignSummaries { accountId in
            XCTAssertEqual(accountId, "account-1")
            return [
                WebCampaignSummary(
                    campaignId: "campaign-1",
                    campaignName: "Launch Drops",
                    game: "Black Ops 7",
                    status: "upcoming",
                    startsAt: start,
                    endsAt: end,
                    dropCount: 4,
                    claimedDrops: 1,
                    subscriptionRequiredDropCount: 3,
                    requiresSubscription: true,
                    boxArtURL: "https://example.com/box.jpg"
                )
            ]
        }

        let response = await harness.routes.webCampaigns(accountId: "account-1")
        XCTAssertEqual(response.statusCode, 200)

        let payload = try decodeJSON(response.body)
        let campaigns = try XCTUnwrap(payload["campaigns"] as? [[String: Any]])
        XCTAssertEqual(campaigns.count, 1)
        XCTAssertEqual(campaigns.first?["campaignId"] as? String, "campaign-1")
        XCTAssertEqual(campaigns.first?["game"] as? String, "Black Ops 7")
        XCTAssertEqual(campaigns.first?["status"] as? String, "upcoming")
        XCTAssertEqual(campaigns.first?["dropCount"] as? Int, 4)
        XCTAssertEqual(campaigns.first?["claimedDrops"] as? Int, 1)
        XCTAssertEqual(campaigns.first?["subscriptionRequiredDropCount"] as? Int, 3)
        XCTAssertEqual(campaigns.first?["requiresSubscription"] as? Bool, true)
        XCTAssertEqual(campaigns.first?["boxArtURL"] as? String, "https://example.com/box.jpg")
    }

    func testDiscordProjectionUsesLinkedTwitchRuntimeState() async throws {
        let harness = try await RouteHarness()
        let twitchAccountId = "twitch-1"
        try await harness.manager.execute { db in
            let sql = """
            INSERT INTO miner_users (discord_id, status) VALUES ('123456789012345678', 'registered');
            INSERT INTO twitch_accounts (
                twitch_id, owner_discord_id, username, access_token, refresh_token, token_expiry, scopes, link_state
            ) VALUES (
                'twitch-1', '123456789012345678', 'linkedminer', 'access', 'refresh', '2099-01-01T00:00:00Z', '', 'linked'
            );
            """
            var error: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
                let message = error.map { String(cString: $0) } ?? "unknown SQLite error"
                sqlite3_free(error)
                throw NSError(domain: "DiscordAPIRoutesTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }

        let expectedDiscordId = discordUserId
        let builder = DiscordProjectionBuilder(
            manager: harness.manager,
            stateProvider: LinkedTwitchProjectionStateProvider(),
            twitchProfileImageURL: { accountId in
                accountId == twitchAccountId ? URL(string: "https://example.com/twitch-avatar.png") : nil
            },
            discordProfileImageURL: { discordId in
                discordId == expectedDiscordId ? URL(string: "https://cdn.discordapp.com/avatars/123/avatar.png") : nil
            }
        )

        let maybeDiscordProjection = await builder.buildProjection(discordUserId: discordUserId)
        let maybeTwitchProjection = await builder.buildProjection(twitchId: twitchAccountId)
        let discordProjection = try XCTUnwrap(maybeDiscordProjection)
        let twitchProjection = try XCTUnwrap(maybeTwitchProjection)

        XCTAssertEqual(discordProjection.account?.twitchAccountId, twitchAccountId)
        XCTAssertEqual(discordProjection.account?.profileImageURL, URL(string: "https://example.com/twitch-avatar.png"))
        XCTAssertEqual(twitchProjection.account?.profileImageURL, URL(string: "https://example.com/twitch-avatar.png"))
        XCTAssertEqual(discordProjection.account?.discordProfileImageURL, URL(string: "https://cdn.discordapp.com/avatars/123/avatar.png"))
        XCTAssertEqual(twitchProjection.account?.discordProfileImageURL, URL(string: "https://cdn.discordapp.com/avatars/123/avatar.png"))
        XCTAssertEqual(discordProjection.state, twitchProjection.state)
        XCTAssertEqual(discordProjection.activeCampaign?.campaignId, twitchProjection.activeCampaign?.campaignId)
        XCTAssertEqual(discordProjection.activeCampaign?.game, "Linked Twitch Game")
        XCTAssertEqual(discordProjection.recentCompletedCampaigns.map(\.campaignId), twitchProjection.recentCompletedCampaigns.map(\.campaignId))
        XCTAssertEqual(discordProjection.priorityGames, twitchProjection.priorityGames)
        XCTAssertEqual(discordProjection.personalPriorityGames, twitchProjection.personalPriorityGames)
        XCTAssertEqual(discordProjection.configuredMinerCount, 1)
        XCTAssertEqual(twitchProjection.configuredMinerCount, 1)

        // Without the app supplying a choice — a standalone service — clients
        // keep the Twitch-first order.
        XCTAssertEqual(discordProjection.account?.prefersDiscordProfileImage, false)
        XCTAssertEqual(twitchProjection.account?.prefersDiscordProfileImage, false)

        // With it, both projection paths carry the account's choice so the
        // dashboard resolves the same picture the app does.
        let discordPreferringBuilder = DiscordProjectionBuilder(
            manager: harness.manager,
            stateProvider: LinkedTwitchProjectionStateProvider(),
            twitchProfileImageURL: { _ in URL(string: "https://example.com/twitch-avatar.png") },
            discordProfileImageURL: { _ in URL(string: "https://cdn.discordapp.com/avatars/123/avatar.png") },
            prefersDiscordProfileImage: { $0 == twitchAccountId }
        )
        let preferredByDiscordId = await discordPreferringBuilder.buildProjection(discordUserId: discordUserId)
        let preferredByTwitchId = await discordPreferringBuilder.buildProjection(twitchId: twitchAccountId)
        XCTAssertEqual(preferredByDiscordId?.account?.prefersDiscordProfileImage, true)
        XCTAssertEqual(preferredByTwitchId?.account?.prefersDiscordProfileImage, true)
    }
}

private final class RouteHarness {
    let manager: SQLiteManager
    let router: HTTPRouter
    let routes: DiscordAPIRoutes
    private let databaseURL: URL

    init() async throws {
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftMiner-DiscordAPIRoutesTests-\(UUID().uuidString).sqlite")
        manager = SQLiteManager(databaseURL: databaseURL)
        try await manager.open()
        router = HTTPRouter()
        routes = DiscordAPIRoutes(
            manager: manager,
            projectionBuilder: DiscordProjectionBuilder(manager: manager),
            apiKey: "test-api-key"
        )
        await routes.configure(router)
    }

    deinit {
        Task { [manager, databaseURL] in
            await manager.close()
            try? FileManager.default.removeItem(at: databaseURL)
        }
    }

    func registerUser(_ discordUserId: String) async throws {
        let response = await router.handle(HTTPRequest(
            method: "POST",
            path: "/v1/users",
            headers: [:],
            body: #"{"discordUserId":"\#(discordUserId)"}"#.data(using: .utf8)!
        ))
        XCTAssertTrue([200, 201].contains(response.statusCode))
    }
}

private actor MinerControlRecorder {
    private var calls: [(discordUserId: String, action: MinerControlAction)] = []

    func record(discordUserId: String, action: MinerControlAction) {
        calls.append((discordUserId, action))
    }

    func callCount() -> Int {
        calls.count
    }

    func actions() -> [MinerControlAction] {
        calls.map(\.action)
    }
}

private actor LinkWarningPauseRecorder {
    private var calls: [(discordUserId: String, gameName: String, expiresAt: Date)] = []

    func record(discordUserId: String, gameName: String, expiresAt: Date) {
        calls.append((discordUserId, gameName, expiresAt))
    }

    func callCount() -> Int {
        calls.count
    }

    func games() -> [String] {
        calls.map(\.gameName)
    }
}

private actor PriorityUpdateRecorder {
    private var calls: [(discordUserId: String, accountId: String, gameName: String)] = []

    func record(discordUserId: String, accountId: String, gameName: String) {
        calls.append((discordUserId, accountId, gameName))
    }

    func games() -> [String] {
        calls.map(\.gameName)
    }
}

private struct LinkedTwitchProjectionStateProvider: ProjectionStateProvider {
    func activeCampaign(for discordUserId: String) async -> DiscordUserProjection.ActiveCampaign? {
        DiscordUserProjection.ActiveCampaign(
            campaignId: "discord-stale",
            game: "Discord Stale Game",
            progress: DiscordUserProjection.Progress(current: 1, required: 10, unit: "minutes", pct: 10),
            endsAt: Date(timeIntervalSince1970: 1_800_086_400)
        )
    }

    func recentCompletedCampaigns(for discordUserId: String, limit: Int) async -> [DiscordUserProjection.RecentCampaign] {
        [
            DiscordUserProjection.RecentCampaign(
                campaignId: "discord-history",
                campaignName: "Discord History",
                game: "Discord Stale Game",
                claimedDrops: 1,
                totalDrops: 1
            )
        ]
    }

    func projectionState(for discordUserId: String) async -> DiscordUserProjection.ProjectionState? {
        .blocked
    }

    func priorityGames(for discordUserId: String) async -> [String] {
        ["Discord Stale Game"]
    }

    func activeCampaign(forTwitchAccount accountId: String) async -> DiscordUserProjection.ActiveCampaign? {
        DiscordUserProjection.ActiveCampaign(
            campaignId: "twitch-current",
            game: "Linked Twitch Game",
            progress: DiscordUserProjection.Progress(current: 7, required: 10, unit: "minutes", pct: 70),
            endsAt: Date(timeIntervalSince1970: 1_800_086_400)
        )
    }

    func recentCompletedCampaigns(forTwitchAccount accountId: String, limit: Int) async -> [DiscordUserProjection.RecentCampaign] {
        [
            DiscordUserProjection.RecentCampaign(
                campaignId: "twitch-history",
                campaignName: "Twitch History",
                game: "Linked Twitch Game",
                claimedDrops: 2,
                totalDrops: 2
            )
        ]
    }

    func projectionState(forTwitchAccount accountId: String) async -> DiscordUserProjection.ProjectionState? {
        .active
    }

    func priorityGames(forTwitchAccount accountId: String) async -> [String] {
        ["Linked Twitch Game"]
    }

    func personalPriorityGames(forTwitchAccount accountId: String) async -> [String] {
        ["Linked Twitch Game"]
    }
}

private func decodeJSON(_ data: Data) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
