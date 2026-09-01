import XCTest
@testable import SwiftMinerService

final class SwiftMinerDMEventServiceTests: XCTestCase {
    func testRecurringNotificationsCarryBucketedEventIds() async {
        let connection = RecordingConnectionService()
        let service = SwiftMinerDMEventService(connectionService: connection)

        await service.emitReauthRequired(
            accountId: "account-1",
            discordUserId: "discord-1",
            twitchUsername: "miner",
            priorityGames: ["THE FINALS"]
        )
        await service.emitPrioritisedGameNeedsLinking(
            gameName: "THE FINALS",
            gameId: "game-1",
            accountId: "account-1",
            minerDisplayName: "miner",
            discordUserId: "discord-1",
            priorityGames: ["THE FINALS"]
        )
        await service.emitWelcomeBack(
            accountId: "account-1",
            discordUserId: "discord-1",
            twitchUsername: "miner",
            priorityGames: ["THE FINALS"]
        )
        await service.emitAccountActionRequired(
            accountId: "account-1",
            reason: "miner stalled",
            discordUserId: "discord-1",
            twitchUsername: "miner",
            priorityGames: ["THE FINALS"]
        )

        let requests = await connection.sentRequests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests.map(\.messageType), [.reauth, .prioritisedGameNeedsLinking, .welcomeBack, .accountActionRequired])

        let ids = requests.compactMap(\.eventId)
        XCTAssertEqual(ids.count, 4, "All cooldown-based events should carry an eventId for cross-restart dedup")
        XCTAssertTrue(ids[0].hasPrefix("reauth:account-1:"))
        XCTAssertTrue(ids[1].hasPrefix("linkWarning:the finals:"))
        XCTAssertTrue(ids[2].hasPrefix("welcomeBack:account-1:"))
        XCTAssertTrue(ids[3].hasPrefix("accountAction:account-1:"))

        // Reauth request should now also carry the user's priority games.
        XCTAssertEqual(requests[0].priorityGames, ["THE FINALS"])
    }

    func testReauthDedupesWithinCooldownWindow() async {
        let connection = RecordingConnectionService()
        let service = SwiftMinerDMEventService(connectionService: connection)

        await service.emitReauthRequired(
            accountId: "account-1",
            discordUserId: "discord-1",
            twitchUsername: "miner",
            priorityGames: []
        )
        await service.emitReauthRequired(
            accountId: "account-1",
            discordUserId: "discord-1",
            twitchUsername: "miner",
            priorityGames: []
        )

        let requests = await connection.sentRequests
        XCTAssertEqual(requests.count, 1, "Second reauth within cooldown should be suppressed in-process")
    }

    func testCampaignDetectedUsesStableEventIdAndDedupesByCampaign() async {
        let connection = RecordingConnectionService()
        let service = SwiftMinerDMEventService(connectionService: connection)

        await service.emitCampaignDetected(
            campaignId: "campaign-1",
            campaignName: "Launch Drops",
            gameName: "THE FINALS",
            gameId: "game-1",
            gameArtworkURL: "https://example.com/finals.jpg",
            accountId: "account-1",
            minerDisplayName: "miner",
            discordUserId: "discord-1",
            priorityGames: ["THE FINALS"]
        )
        await service.emitCampaignDetected(
            campaignId: "campaign-1",
            campaignName: "Launch Drops",
            gameName: "THE FINALS",
            gameId: "game-1",
            gameArtworkURL: "https://example.com/finals.jpg",
            accountId: "account-1",
            minerDisplayName: "miner",
            discordUserId: "discord-1",
            priorityGames: ["THE FINALS"]
        )

        let requests = await connection.sentRequests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.messageType, .campaignDetected)
        XCTAssertEqual(requests.first?.eventId, "campaignDetected:campaign-1")
        XCTAssertEqual(requests.first?.affectedGame, "THE FINALS")
        XCTAssertEqual(requests.first?.affectedGameId, "game-1")
        XCTAssertEqual(requests.first?.accountId, "account-1")
        XCTAssertEqual(requests.first?.gameArtworkURL, "https://example.com/finals.jpg")
    }

    // MARK: - Portal deep links

    private static let portalBase = "https://swiftminer.example.com"

    /// A DM that says "do something" has to say where. Each automatic event
    /// should land on the page that explains or resolves it, not the root.
    func testEachEventDeepLinksAtWhatItIsAbout() async {
        let connection = RecordingConnectionService()
        let service = SwiftMinerDMEventService(
            connectionService: connection,
            portalBase: Self.portalBase
        )

        await service.emitReauthRequired(
            accountId: "account-1", discordUserId: "discord-1",
            twitchUsername: "miner", priorityGames: []
        )
        await service.emitPrioritisedGameNeedsLinking(
            gameName: "Cyberpunk 2077", gameId: "game-1", accountId: "account-1",
            minerDisplayName: "miner", discordUserId: "discord-1", priorityGames: []
        )
        await service.emitCampaignDetected(
            campaignId: "camp-1", campaignName: "Phantom Liberty Drops",
            gameName: "Cyberpunk 2077", gameId: "game-1", gameArtworkURL: nil,
            accountId: "account-1", minerDisplayName: "miner",
            discordUserId: "discord-1", priorityGames: []
        )
        await service.emitCampaignCompleted(
            campaignId: "camp-2", campaignName: "Phantom Liberty Drops",
            gameName: "Cyberpunk 2077", gameId: "game-1", gameArtworkURL: nil,
            accountId: "account-1", minerDisplayName: "miner",
            discordUserId: "discord-1", priorityGames: []
        )

        let requests = await connection.sentRequests
        let byType = Dictionary(uniqueKeysWithValues: requests.map { ($0.messageType, $0) })

        XCTAssertEqual(byType[.reauth]?.portalURL, "\(Self.portalBase)/app#/account/connection")
        XCTAssertEqual(byType[.reauth]?.portalDestination, "account_connection")
        XCTAssertEqual(byType[.reauth]?.issueKind, "connection_expired")

        XCTAssertEqual(byType[.prioritisedGameNeedsLinking]?.portalURL, "\(Self.portalBase)/app#/campaigns")
        XCTAssertEqual(byType[.prioritisedGameNeedsLinking]?.issueKind, "account_link_required")

        XCTAssertEqual(byType[.campaignDetected]?.portalURL, "\(Self.portalBase)/app#/campaign/camp%2D1")
        XCTAssertEqual(byType[.campaignDetected]?.campaignId, "camp-1")

        XCTAssertEqual(byType[.campaignCompleted]?.portalURL, "\(Self.portalBase)/app#/drops")
        XCTAssertEqual(byType[.campaignCompleted]?.portalDestination, "drops")
    }

    /// With no public URL there is nothing honest to link to. SwiftBot should
    /// then render no button rather than one that cannot resolve.
    func testNoPortalConfiguredMeansNoPortalButton() async {
        let connection = RecordingConnectionService()
        let service = SwiftMinerDMEventService(connectionService: connection)

        await service.emitReauthRequired(
            accountId: "account-1", discordUserId: "discord-1",
            twitchUsername: "miner", priorityGames: []
        )

        let request = await connection.sentRequests.first
        XCTAssertNil(request?.portalURL)
        XCTAssertNil(request?.portalDestination)
        // The cause is still classified — it does not depend on the portal.
        XCTAssertEqual(request?.issueKind, "connection_expired")
    }

    func testPortalBaseCanBeRepointedAfterTheURLChanges() async {
        let connection = RecordingConnectionService()
        let service = SwiftMinerDMEventService(connectionService: connection)

        await service.updatePortalBase(Self.portalBase)
        await service.emitReauthRequired(
            accountId: "account-1", discordUserId: "discord-1",
            twitchUsername: "miner", priorityGames: []
        )

        let request = await connection.sentRequests.first
        XCTAssertEqual(request?.portalURL, "\(Self.portalBase)/app#/account/connection")
    }

    /// The catch-all type must be able to name its actual cause, so a DM can
    /// read "Twitch Subscription Required" instead of "Needs a Look".
    func testAccountActionCarriesItsClassifiedCauseAndCampaign() async {
        let connection = RecordingConnectionService()
        let service = SwiftMinerDMEventService(
            connectionService: connection,
            portalBase: Self.portalBase
        )

        await service.emitAccountActionRequired(
            accountId: "account-1",
            reason: "A paid Twitch subscription is required.",
            discordUserId: "discord-1",
            twitchUsername: "miner",
            priorityGames: [],
            issueKind: .subscriptionRequired,
            campaignId: "camp-9"
        )

        let request = await connection.sentRequests.first
        XCTAssertEqual(request?.issueKind, "subscription_required")
        XCTAssertEqual(request?.campaignId, "camp-9")
        XCTAssertEqual(request?.portalURL, "\(Self.portalBase)/app#/campaign/camp%2D9")
        XCTAssertEqual(request?.helpURL, SwiftMinerHelpLink.url(for: .subscriptionRequired))
    }

    func testUnclassifiedAccountActionStillLandsOnTheMiner() async {
        let connection = RecordingConnectionService()
        let service = SwiftMinerDMEventService(
            connectionService: connection,
            portalBase: Self.portalBase
        )

        await service.emitAccountActionRequired(
            accountId: "account-1", reason: "miner stalled",
            discordUserId: "discord-1", twitchUsername: "miner", priorityGames: []
        )

        let request = await connection.sentRequests.first
        XCTAssertEqual(request?.issueKind, "unknown")
        XCTAssertEqual(request?.portalURL, "\(Self.portalBase)/app#/miner/account%2D1")
        XCTAssertNil(request?.campaignId)
    }
}

private actor RecordingConnectionService: SwiftBotConnectionService {
    private(set) var sentRequests: [SwiftBotDMRequest] = []

    func updateEndpoint(_ urlString: String) async {}

    func checkHealth() async -> SwiftBotConnectionState { .connected }

    func sendTestEvent() async -> Bool { true }

    func fetchDiscordUsers() async -> [SwiftBotDiscordUser] { [] }

    func sendLinkedDM(to discordUserId: String, twitchUsername: String?, priorityGames: [String], portalBase: String?) async -> Bool {
        true
    }

    func sendDebugDM(to discordUserId: String, request: SwiftBotDMRequest) async -> Bool {
        sentRequests.append(request)
        return true
    }

    func sendEventDM(to discordUserId: String, request: SwiftBotDMRequest) async -> Bool {
        sentRequests.append(request)
        return true
    }
}
