import XCTest
@testable import SwiftMinerService

final class SwiftMinerDMEventServiceTests: XCTestCase {
    func testRecurringNotificationsDoNotSetPersistentEventIds() async {
        let connection = RecordingConnectionService()
        let service = SwiftMinerDMEventService(connectionService: connection)

        await service.emitReauthRequired(
            accountId: "account-1",
            discordUserId: "discord-1",
            twitchUsername: "miner"
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
        XCTAssertTrue(requests.allSatisfy { $0.eventId == nil })
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
