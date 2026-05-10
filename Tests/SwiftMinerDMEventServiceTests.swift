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
            discordUserId: "discord-1",
            priorityGames: ["THE FINALS"]
        )
        await service.emitCampaignDetected(
            campaignId: "campaign-1",
            campaignName: "Launch Drops",
            gameName: "THE FINALS",
            discordUserId: "discord-1",
            priorityGames: ["THE FINALS"]
        )

        let requests = await connection.sentRequests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.messageType, .campaignDetected)
        XCTAssertEqual(requests.first?.eventId, "campaignDetected:campaign-1")
        XCTAssertEqual(requests.first?.affectedGame, "THE FINALS")
    }
}

private actor RecordingConnectionService: SwiftBotConnectionService {
    private(set) var sentRequests: [SwiftBotDMRequest] = []

    func updateEndpoint(_ urlString: String) async {}

    func checkHealth() async -> SwiftBotConnectionState { .connected }

    func sendTestEvent() async -> Bool { true }

    func fetchDiscordUsers() async -> [SwiftBotDiscordUser] { [] }

    func sendLinkedDM(to discordUserId: String, twitchUsername: String?, priorityGames: [String]) async -> Bool {
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
