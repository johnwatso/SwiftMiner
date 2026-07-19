import XCTest
@testable import SwiftMinerCore

final class SwiftMinerCoreTests: XCTestCase {

    // MARK: - Campaign time window

    func testCampaignTimeActive() {
        let now = Date()
        let game = Game(id: "g1", name: "Test Game")
        let campaign = Campaign(
            id: "c1", name: "Test Campaign", game: game, status: .active,
            startDate: now.addingTimeInterval(-3600),
            endDate: now.addingTimeInterval(3600)
        )
        XCTAssertTrue(campaign.isTimeActive)
    }

    func testCampaignNotActiveYet() {
        let now = Date()
        let game = Game(id: "g1", name: "Test Game")
        let campaign = Campaign(
            id: "c1", name: "Test Campaign", game: game, status: .upcoming,
            startDate: now.addingTimeInterval(3600),
            endDate: now.addingTimeInterval(7200)
        )
        XCTAssertFalse(campaign.isTimeActive)
    }

    // MARK: - Drop progress

    func testDropProgressViaProgress() {
        let progress = Progress(
            dropId: "d1", campaignId: "c1",
            currentMinutes: 0, requiredMinutes: 60, isClaimed: false
        )
        let drop = Drop(id: "d1", name: "Test Drop", requiredMinutes: 60, progress: progress)
        XCTAssertFalse(drop.isClaimed)
        XCTAssertFalse(drop.isClaimable)
    }

    // MARK: - Account token validity

    func testAccountTokenValidity() {
        let valid = Account(
            id: "u1", username: "user",
            accessToken: "tok", refreshToken: "ref",
            tokenExpiry: Date().addingTimeInterval(600),
            scopes: ["user:read:email"]
        )
        XCTAssertTrue(valid.isTokenValid)

        let expired = Account(
            id: "u2", username: "user2",
            accessToken: "tok", refreshToken: "ref",
            tokenExpiry: Date().addingTimeInterval(-600),
            scopes: ["user:read:email"]
        )
        XCTAssertFalse(expired.isTokenValid)
    }

    // MARK: - Channel

    func testChannelDropsEnabled() {
        let channel = Channel(
            id: "ch1", login: "testchannel", displayName: "TestChannel",
            isLive: true, hasDropsEnabled: true
        )
        XCTAssertTrue(channel.isLive)
        XCTAssertTrue(channel.hasDropsEnabled)
    }

    // MARK: - Progress calculations

    func testProgressCalculation() {
        let p = Progress(
            id: "pr1", dropId: "d1", dropName: "Drop",
            campaignId: "c1", currentMinutes: 30, requiredMinutes: 60
        )
        XCTAssertEqual(p.percentComplete, 50.0, accuracy: 0.01)
        XCTAssertEqual(p.remainingMinutes, 30)
        XCTAssertFalse(p.isComplete)

        let done = Progress(
            id: "pr2", dropId: "d2", dropName: "Done Drop",
            campaignId: "c1", currentMinutes: 60, requiredMinutes: 60
        )
        XCTAssertEqual(done.percentComplete, 100.0, accuracy: 0.01)
        XCTAssertEqual(done.remainingMinutes, 0)
        XCTAssertTrue(done.isComplete)
    }

    // MARK: - OverallProgress

    func testOverallProgress() {
        let progress = OverallProgress(
            totalCampaigns: 5, activeCampaigns: 3,
            totalDrops: 10, claimedDrops: 4, pendingDrops: 6,
            totalWatchTimeMinutes: 120, campaigns: []
        )
        XCTAssertEqual(progress.totalCampaigns, 5)
        XCTAssertEqual(progress.claimedDrops, 4)
        XCTAssertEqual(progress.pendingDrops, 6)
    }

    // MARK: - Spade beacon interval

    func testSpadeWatchInterval() {
        // The beacon must fire every 59 seconds — this is the Twitch-defined window
        XCTAssertEqual(SpadeBeaconService.watchInterval, 59)
    }

    func testDirectoryPageGameHashMatchesCurrentTwitchQuery() {
        XCTAssertEqual(
            GQLHashes.directoryPage_Game,
            "86bcceb4e8b1a51256ff8eed8bd8aae4acacf80d737efe904f84f3aeadf8cafd"
        )
    }

    func testPubSubTopicsAreSplitIntoBoundedBatches() {
        let topics = (0..<45).map { "topic.\($0)" }
        let batches = PubSubClient.topicBatches(topics)

        XCTAssertEqual(batches.map(\.count), [20, 20, 5])
        XCTAssertEqual(Set(batches.flatMap { $0 }), Set(topics))
        XCTAssertTrue(batches.allSatisfy { $0.count <= PubSubClient.topicBatchSize })
    }

    func testPubSubReconnectReplaysDesiredTopicsAfterSocketStateReset() {
        let desired: Set<String> = ["drop.1", "drop.2", "video.1"]

        XCTAssertEqual(
            PubSubClient.pendingTopicSubscriptions(
                desired: desired,
                submitted: ["drop.1", "video.1"]
            ),
            ["drop.2"]
        )
        XCTAssertEqual(
            PubSubClient.pendingTopicSubscriptions(desired: desired, submitted: []),
            ["drop.1", "drop.2", "video.1"]
        )
    }

    // MARK: - Errors

    func testErrorDescriptions() {
        XCTAssertNotNil(TwitchMinerError.tokenExpired.errorDescription)
        XCTAssertNotNil(TwitchMinerError.networkError("test").errorDescription)
        XCTAssertNotNil(TwitchMinerError.rateLimited(retryAfter: 30).errorDescription)
        XCTAssertNotNil(TwitchMinerError.dropAlreadyClaimed.errorDescription)
        XCTAssertNotNil(TwitchMinerError.unknown("boom").errorDescription)
    }

    // MARK: - Token storage

    func testSQLiteTokenStoreRoundTripsOwnerAndEmptyScopes() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftMinerTests-\(UUID().uuidString).sqlite")
        let manager = SQLiteManager(databaseURL: databaseURL)
        try await manager.open()
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
        }

        let store = SQLiteTokenStore(manager: manager)
        let account = Account(
            id: "twitch-1",
            username: "miner",
            nickname: "Drop Runner",
            ownerDiscordId: "123456789012345678",
            accessToken: "access",
            refreshToken: "refresh",
            tokenExpiry: Date().addingTimeInterval(3600),
            scopes: []
        )

        try await store.save(account: account)

        let loadedAccount = try await store.loadAccount(twitchUserId: account.id)
        let loaded = try XCTUnwrap(loadedAccount)
        XCTAssertEqual(loaded.nickname, account.nickname)
        XCTAssertEqual(loaded.displayName, "Drop Runner")
        XCTAssertEqual(loaded.ownerDiscordId, account.ownerDiscordId)
        XCTAssertEqual(loaded.scopes, [])

        try await store.updateTokenMaterial(
            twitchUserId: account.id,
            accessToken: "new-access",
            refreshToken: nil,
            expiry: Date().addingTimeInterval(7200)
        )

        let refreshedAccount = try await store.loadAccount(twitchUserId: account.id)
        let refreshed = try XCTUnwrap(refreshedAccount)
        XCTAssertEqual(refreshed.nickname, account.nickname)
        XCTAssertEqual(refreshed.ownerDiscordId, account.ownerDiscordId)
        XCTAssertEqual(refreshed.accessToken, "new-access")
        XCTAssertEqual(refreshed.refreshToken, "refresh")
        XCTAssertEqual(refreshed.scopes, [])

        try await store.updateNickname(twitchUserId: account.id, nickname: "Boss Miner")
        let renamedAccount = try await store.loadAccount(twitchUserId: account.id)
        let renamed = try XCTUnwrap(renamedAccount)
        XCTAssertEqual(renamed.nickname, "Boss Miner")
        XCTAssertEqual(renamed.accessToken, "new-access")

        await manager.close()
    }

    func testSQLiteTokenStoreOperatorExclusivity() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftMinerTests-\(UUID().uuidString).sqlite")
        let manager = SQLiteManager(databaseURL: databaseURL)
        try await manager.open()
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
        }

        let store = SQLiteTokenStore(manager: manager)
        let account1 = Account(
            id: "twitch-1", username: "miner1", nickname: nil, ownerDiscordId: nil,
            accessToken: "access1", refreshToken: "refresh1", tokenExpiry: Date().addingTimeInterval(3600),
            scopes: [], isOperator: false
        )
        let account2 = Account(
            id: "twitch-2", username: "miner2", nickname: nil, ownerDiscordId: nil,
            accessToken: "access2", refreshToken: "refresh2", tokenExpiry: Date().addingTimeInterval(3600),
            scopes: [], isOperator: false
        )

        try await store.save(account: account1)
        try await store.save(account: account2)

        try await store.updateOperatorStatus(twitchUserId: "twitch-1", isOperator: true)
        
        let a1 = try await store.loadAccount(twitchUserId: "twitch-1")
        let a2 = try await store.loadAccount(twitchUserId: "twitch-2")
        let loaded1 = try XCTUnwrap(a1)
        let loaded2 = try XCTUnwrap(a2)
        XCTAssertTrue(loaded1.isOperator)
        XCTAssertFalse(loaded2.isOperator)

        try await store.updateOperatorStatus(twitchUserId: "twitch-2", isOperator: true)

        let a1After = try await store.loadAccount(twitchUserId: "twitch-1")
        let a2After = try await store.loadAccount(twitchUserId: "twitch-2")
        let loaded1After = try XCTUnwrap(a1After)
        let loaded2After = try XCTUnwrap(a2After)
        XCTAssertFalse(loaded1After.isOperator)
        XCTAssertTrue(loaded2After.isOperator)

        await manager.close()
    }
}

actor TestTokenStore: TokenStore {
    private var accounts: [String: Account] = [:]

    func save(account: Account) async throws {
        accounts[account.id] = account
    }

    func loadAllAccounts() async throws -> [Account] {
        Array(accounts.values)
    }

    func loadAccount(twitchUserId: String) async throws -> Account? {
        accounts[twitchUserId]
    }

    func updateTokenMaterial(twitchUserId: String, accessToken: String, refreshToken: String?, expiry: Date) async throws {
        guard let existing = accounts[twitchUserId] else { return }
        accounts[twitchUserId] = Account(
            id: existing.id,
            username: existing.username,
            nickname: existing.nickname,
            ownerDiscordId: existing.ownerDiscordId,
            accessToken: accessToken,
            refreshToken: refreshToken ?? existing.refreshToken,
            tokenExpiry: expiry,
            scopes: existing.scopes,
            isOperator: existing.isOperator
        )
    }

    func updateNickname(twitchUserId: String, nickname: String?) async throws {
        guard let existing = accounts[twitchUserId] else { return }
        accounts[twitchUserId] = Account(
            id: existing.id,
            username: existing.username,
            nickname: nickname,
            ownerDiscordId: existing.ownerDiscordId,
            accessToken: existing.accessToken,
            refreshToken: existing.refreshToken,
            tokenExpiry: existing.tokenExpiry,
            scopes: existing.scopes,
            isOperator: existing.isOperator
        )
    }

    func updateOperatorStatus(twitchUserId: String, isOperator: Bool) async throws {
        if isOperator {
            for (id, acc) in accounts {
                if id != twitchUserId && acc.isOperator {
                    accounts[id] = Account(
                        id: acc.id,
                        username: acc.username,
                        nickname: acc.nickname,
                        ownerDiscordId: acc.ownerDiscordId,
                        accessToken: acc.accessToken,
                        refreshToken: acc.refreshToken,
                        tokenExpiry: acc.tokenExpiry,
                        scopes: acc.scopes,
                        isOperator: false
                    )
                }
            }
        }
        guard let existing = accounts[twitchUserId] else { return }
        accounts[twitchUserId] = Account(
            id: existing.id,
            username: existing.username,
            nickname: existing.nickname,
            ownerDiscordId: existing.ownerDiscordId,
            accessToken: existing.accessToken,
            refreshToken: existing.refreshToken,
            tokenExpiry: existing.tokenExpiry,
            scopes: existing.scopes,
            isOperator: isOperator
        )
    }

    func deleteAccount(twitchUserId: String) async throws {
        accounts.removeValue(forKey: twitchUserId)
    }
}
