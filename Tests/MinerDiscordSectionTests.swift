import XCTest
@testable import SwiftMiner
@testable import SwiftMinerCore
import SwiftMinerService

@MainActor
final class MinerDiscordSectionTests: XCTestCase {

    // MARK: - Status resolution

    func testLinkedAndReachableAccountReportsConnected() {
        let presentation = resolve(
            miner: makeMiner(ownerDiscordId: "discord-1"),
            discordUser: makeDiscordUser()
        )

        XCTAssertTrue(presentation.isLinked)
        XCTAssertEqual(presentation.status, .connected)
        XCTAssertEqual(presentation.status.label, "Connected")
        XCTAssertFalse(presentation.status.isProblem)
        XCTAssertNil(presentation.statusDetail)
    }

    func testUnlinkedMinerReportsRestrainedEmptyStateRatherThanAnError() {
        let presentation = resolve(miner: makeMiner(ownerDiscordId: nil), discordUser: nil)

        XCTAssertFalse(presentation.isLinked)
        XCTAssertEqual(presentation.status, .notLinked)
        XCTAssertEqual(presentation.status.label, "Not linked")
        XCTAssertFalse(presentation.status.isProblem)
        XCTAssertEqual(
            presentation.statusDetail,
            "Discord notifications aren't available for this miner."
        )
    }

    func testUnreachableBotIsDistinguishableFromNotLinked() {
        let presentation = resolve(
            miner: makeMiner(ownerDiscordId: "discord-1"),
            discordUser: makeDiscordUser(),
            connectionState: .disconnected
        )

        XCTAssertEqual(presentation.status, .botOffline)
        XCTAssertTrue(presentation.status.isProblem)
    }

    func testLinkedAccountSwiftBotCannotSeeReportsAccountUnavailable() {
        let presentation = resolve(
            miner: makeMiner(ownerDiscordId: "discord-1"),
            discordUser: nil
        )

        XCTAssertEqual(presentation.status, .accountUnavailable)
        XCTAssertTrue(presentation.status.isProblem)
    }

    func testFailedSendTakesPrecedenceOverEveryOtherLinkedState() {
        let presentation = resolve(
            miner: makeMiner(ownerDiscordId: "discord-1"),
            discordUser: makeDiscordUser(),
            connectionState: .disconnected,
            recentSendFailed: true
        )

        XCTAssertEqual(presentation.status, .deliveryFailed)
        XCTAssertEqual(presentation.status.label, "Delivery failed")
    }

    /// Twitch auth is the miner's problem, surfaced by the attention banner and
    /// the Status section. Repeating it here would be a redundant second state.
    func testExpiredTwitchAuthDoesNotMarkDiscordUnhealthy() {
        let presentation = resolve(
            miner: makeMiner(ownerDiscordId: "discord-1", needsAuth: true),
            discordUser: makeDiscordUser()
        )

        XCTAssertEqual(presentation.status, .connected)
    }

    // MARK: - Identity

    func testUsernameIsDroppedWhenItOnlyRepeatsTheDisplayName() {
        let presentation = resolve(
            miner: makeMiner(ownerDiscordId: "discord-1"),
            discordUser: SwiftBotDiscordUser(id: "discord-1", displayName: "sorbertman", username: "sorbertman"),
            discordDisplayName: "sorbertman"
        )

        XCTAssertEqual(presentation.displayName, "sorbertman")
        XCTAssertNil(presentation.username)
    }

    func testUsernameIsKeptWhenItAddsInformation() {
        let presentation = resolve(
            miner: makeMiner(ownerDiscordId: "discord-1"),
            discordUser: SwiftBotDiscordUser(id: "discord-1", displayName: "Sorbertman", username: "sorbertman#1234")
        )

        XCTAssertEqual(presentation.displayName, "Sorbertman")
        XCTAssertEqual(presentation.username, "sorbertman#1234")
    }

    func testUnlinkedMinerCarriesNoDiscordHistory() {
        let presentation = resolve(
            miner: makeMiner(ownerDiscordId: nil),
            discordUser: nil,
            lastDM: MinerDiscordPresentation.LastDM(
                title: "Welcome",
                detail: nil,
                sentAt: Date(),
                isDelivered: true
            ),
            messageCount: 4
        )

        XCTAssertNil(presentation.lastDM)
        XCTAssertEqual(presentation.messageCount, 0)
    }

    // MARK: - Pending item ↔ reminder matching

    func testLinkReminderMatchesTheLoggedDMForItsOwnGame() {
        let item = linkItem(gameId: "game-rust", gameName: "Rust")

        XCTAssertTrue(item.matchesReminder(item.dmRequest(miner: makeMiner(), priorityGames: [])))
    }

    func testLinkReminderDoesNotMatchTheSameMessageTypeForAnotherGame() {
        let rust = linkItem(gameId: "game-rust", gameName: "Rust")
        let halo = linkItem(gameId: "game-halo", gameName: "Halo Infinite")

        let haloRequest = halo.dmRequest(miner: makeMiner(), priorityGames: [])

        XCTAssertFalse(rust.matchesReminder(haloRequest))
    }

    func testLinkReminderFallsBackToGameNameWhenThePayloadHasNoGameId() {
        let item = linkItem(gameId: "rust", gameName: "Rust")
        let legacyRequest = SwiftBotDMRequest(
            messageType: .prioritisedGameNeedsLinking,
            debug: false,
            affectedGame: "rust"
        )

        XCTAssertTrue(item.matchesReminder(legacyRequest))
    }

    func testSubscriptionReminderMatchesOnCampaignAndAccount() {
        let item = subscriptionItem(campaignName: "Season of the Construct")

        XCTAssertTrue(item.matchesReminder(item.dmRequest(miner: makeMiner(), priorityGames: [])))
    }

    func testSubscriptionReminderIgnoresAnotherAccountsCampaignDM() {
        let item = subscriptionItem(campaignName: "Season of the Construct")
        let otherAccount = SwiftBotDMRequest(
            messageType: .accountActionRequired,
            debug: false,
            campaignName: "Season of the Construct",
            accountId: "account-2"
        )

        XCTAssertFalse(item.matchesReminder(otherAccount))
    }

    func testRemindersOfADifferentTypeNeverMatch() {
        let item = linkItem(gameId: "game-rust", gameName: "Rust")
        let welcome = SwiftBotDMRequest(messageType: .welcome, debug: false)

        XCTAssertFalse(item.matchesReminder(welcome))
    }

    func testReminderMessageTypeMatchesTheSettingsToggleEachItemDependsOn() {
        XCTAssertEqual(
            linkItem(gameId: "game-rust", gameName: "Rust").reminderMessageType,
            .prioritisedGameNeedsLinking
        )
        XCTAssertEqual(
            subscriptionItem(campaignName: "Season of the Construct").reminderMessageType,
            .accountActionRequired
        )
    }

    // MARK: - Pending reminder note

    func testSentNoteNamesDiscordAsTheDeliveryMechanism() {
        let note = PendingReminderNote.sent(Date().addingTimeInterval(-240))

        XCTAssertTrue(note.text.hasPrefix("Reminder sent via Discord "))
    }

    func testDisabledNoteSaysManualSendingStillWorks() {
        XCTAssertTrue(PendingReminderNote.automaticRemindersOff.text.contains("send one manually"))
    }

    // MARK: - Relative formatting

    func testRelativeFormatterCollapsesTheFirstMinuteToJustNow() {
        let now = Date()

        XCTAssertEqual(MinerDiscordFormat.relative(now.addingTimeInterval(-20), now: now), "Just now")
        XCTAssertNotEqual(MinerDiscordFormat.relative(now.addingTimeInterval(-120), now: now), "Just now")
    }

    // MARK: - Message titles

    func testLinkRequiredTitleNamesTheGameFromTheStoredPayload() {
        let entry = DMLogStore.Entry(
            messageType: SwiftBotDMMessageType.prioritisedGameNeedsLinking.rawValue,
            sentAt: Date(),
            isDebug: false
        )
        let request = SwiftBotDMRequest(
            messageType: .prioritisedGameNeedsLinking,
            debug: false,
            affectedGame: "Battlefield 6"
        )

        XCTAssertEqual(MinerDiscordFormat.title(for: entry, request: request), "Link Battlefield 6 to Twitch")
    }

    func testTitleFallsBackToTheMessageTypeWhenThePayloadDescribesAnolderSend() {
        let entry = DMLogStore.Entry(
            messageType: SwiftBotDMMessageType.webDashboardAvailable.rawValue,
            sentAt: Date(),
            isDebug: false
        )
        let unrelated = SwiftBotDMRequest(messageType: .welcome, debug: false)

        XCTAssertEqual(MinerDiscordFormat.title(for: entry, request: unrelated), "Web Dashboard Live")
    }

    // MARK: - Helpers

    private func resolve(
        miner: MinerManager.ManagedMiner,
        discordUser: SwiftBotDiscordUser?,
        discordDisplayName: String? = nil,
        connectionState: SwiftBotConnectionState = .connected,
        lastDM: MinerDiscordPresentation.LastDM? = nil,
        messageCount: Int = 0,
        recentSendFailed: Bool = false
    ) -> MinerDiscordPresentation {
        MinerDiscordPresentation.resolve(
            miner: miner,
            discordUser: discordUser,
            discordDisplayName: discordDisplayName,
            connectionState: connectionState,
            lastDM: lastDM,
            messageCount: messageCount,
            recentSendFailed: recentSendFailed
        )
    }

    private func makeDiscordUser() -> SwiftBotDiscordUser {
        SwiftBotDiscordUser(id: "discord-1", displayName: "Sorbertman", username: "sorbertman")
    }

    private func makeMiner(
        ownerDiscordId: String? = "discord-1",
        needsAuth: Bool = false
    ) -> MinerManager.ManagedMiner {
        MinerManager.ManagedMiner(
            id: "miner-1",
            accountId: "account-1",
            username: "tester",
            ownerDiscordId: ownerDiscordId,
            needsAuth: needsAuth,
            isRunning: true
        )
    }

    private func linkItem(gameId: String, gameName: String) -> PendingItem {
        PendingItem(
            kind: .accountLink(
                PrioritisedLinkIssue(
                    minerId: "miner-1",
                    accountId: "account-1",
                    minerName: "tester",
                    gameId: gameId,
                    gameName: gameName,
                    campaignNames: ["Twitch Drops Week 3"],
                    isIgnored: false
                )
            ),
            isMuted: false
        )
    }

    private func subscriptionItem(campaignName: String) -> PendingItem {
        PendingItem(
            kind: .subscriptionRequired(
                minerId: "miner-1",
                accountId: "account-1",
                campaignId: "campaign-1",
                gameName: "Diablo IV",
                campaignName: campaignName,
                dropNames: ["Hellfire Helm"]
            ),
            isMuted: false
        )
    }
}
