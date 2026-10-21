import XCTest
@testable import SwiftMinerCore
import struct SwiftMinerCore.Progress

@MainActor
final class ClaimServiceTests: XCTestCase {
    
    var mockSession: URLSession!
    var authService: TwitchAuthService!
    var apiClient: TwitchAPIClient!
    var dropsService: DropsService!
    var claimService: ClaimService!
    
    override func setUp() async throws {
        try await super.setUp()
        
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        mockSession = URLSession(configuration: config)
        
        authService = TwitchAuthService(clientId: "test_client", tokenStore: TestTokenStore())
        apiClient = TwitchAPIClient(authService: authService, clientId: "test_client", session: mockSession, persistsCampaignCaches: false)
        dropsService = DropsService(apiClient: apiClient)
        claimService = ClaimService(apiClient: apiClient, dropsService: dropsService)
    }
    
    override func tearDown() {
        MockURLProtocol.stubResponseData = nil
        MockURLProtocol.stubError = nil
        MockURLProtocol.lastRequest = nil
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }
    
    // MARK: - Claim Tests
    
    func testClaimDropSuccess() async throws {
        let progress = Progress(
            id: "instance123",
            dropId: "drop456",
            dropName: "Test Drop",
            campaignId: "camp789",
            currentMinutes: 60,
            requiredMinutes: 60,
            isClaimed: false
        )
        
        // Mirrors what Twitch actually returns for DropsPage_ClaimDropRewards.
        // This fixture used to be written from the parser instead of from real
        // traffic (claimDropBenefit), so it passed while every live claim failed.
        let successJson = "{\"data\": {\"claimDropRewards\": {\"id\": \"instance123\", \"status\": \"CLAIMED\"}}}"
        
        MockURLProtocol.requestHandler = { request in
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, successJson.data(using: .utf8)!)
        }
        
        let result = await claimService.claimDrop(progress)
        
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.dropInstanceId, "instance123")
        XCTAssertEqual(result.dropName, "Test Drop")
    }
    
    /// The status Twitch actually returns for a successful claim. Accepting only
    /// CLAIMED/SUCCESS reported every real claim as a failure.
    func testClaimDropTreatsEligibleForAllAsSuccess() async throws {
        let progress = Progress(
            id: "instance123",
            dropId: "drop456",
            dropName: "Test Drop",
            campaignId: "camp789",
            currentMinutes: 60,
            requiredMinutes: 60,
            isClaimed: false
        )

        let json = "{\"data\": {\"claimDropRewards\": {\"id\": \"instance123\", \"status\": \"ELIGIBLE_FOR_ALL\"}}}"
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json.data(using: .utf8)!)
        }

        let result = await claimService.claimDrop(progress)

        XCTAssertTrue(result.success, "ELIGIBLE_FOR_ALL is a successful claim, got error: \(result.error ?? "nil")")
    }

    /// A repeat claim of an instance Twitch already granted is still a success.
    func testClaimDropTreatsAlreadyClaimedInstanceAsSuccess() async throws {
        let progress = Progress(
            id: "instance123",
            dropId: "drop456",
            dropName: "Test Drop",
            campaignId: "camp789",
            currentMinutes: 60,
            requiredMinutes: 60,
            isClaimed: false
        )

        let json = "{\"data\": {\"claimDropRewards\": {\"id\": \"instance123\", \"status\": \"DROP_INSTANCE_ALREADY_CLAIMED\"}}}"
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json.data(using: .utf8)!)
        }

        let result = await claimService.claimDrop(progress)

        XCTAssertTrue(result.success, "Already-claimed instance should count as success, got error: \(result.error ?? "nil")")
    }

    /// Twitch has served `claimDropBenefit` historically; keep parsing it so a
    /// mixed rollout can't silently break claims again.
    func testClaimDropAcceptsLegacyBenefitKey() async throws {
        let progress = Progress(
            id: "instance123",
            dropId: "drop456",
            dropName: "Test Drop",
            campaignId: "camp789",
            currentMinutes: 60,
            requiredMinutes: 60,
            isClaimed: false
        )

        let legacyJson = "{\"data\": {\"claimDropBenefit\": {\"id\": \"instance123\", \"status\": \"CLAIMED\"}}}"
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, legacyJson.data(using: .utf8)!)
        }

        let result = await claimService.claimDrop(progress)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.dropInstanceId, "instance123")
    }

    /// The regression that hid this bug: an unrecognised payload key must name
    /// the keys Twitch did return, rather than collapsing to "Invalid response".
    func testClaimDropUnknownPayloadKeyReportsReturnedKeys() async throws {
        let progress = Progress(
            id: "instance123",
            dropId: "drop456",
            dropName: "Test Drop",
            campaignId: "camp789",
            currentMinutes: 60,
            requiredMinutes: 60,
            isClaimed: false
        )

        let unknownJson = "{\"data\": {\"somethingElse\": {\"status\": \"CLAIMED\"}}}"
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, unknownJson.data(using: .utf8)!)
        }

        let result = await claimService.claimDrop(progress)

        XCTAssertFalse(result.success)
        let error = result.error ?? ""
        XCTAssertTrue(error.contains("somethingElse"), "Expected the returned key to be named, got: \(error)")
    }

    /// GraphQL failures arrive as HTTP 200 with an `errors` array, so the
    /// message has to be surfaced rather than discarded.
    func testClaimDropSurfacesGraphQLErrorMessage() async throws {
        let progress = Progress(
            id: "instance123",
            dropId: "drop456",
            dropName: "Test Drop",
            campaignId: "camp789",
            currentMinutes: 60,
            requiredMinutes: 60,
            isClaimed: false
        )

        let errorJson = "{\"errors\": [{\"message\": \"PersistedQueryNotFound\"}]}"
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, errorJson.data(using: .utf8)!)
        }

        let result = await claimService.claimDrop(progress)

        XCTAssertFalse(result.success)
        let error = result.error ?? ""
        XCTAssertTrue(error.contains("Twitch compatibility update required"), "Expected the compatibility message to surface, got: \(error)")
    }

    func testClaimDropAlreadyClaimedFails() async throws {
        let progress = Progress(
            id: "instance123",
            dropId: "drop456",
            dropName: "Test Drop",
            campaignId: "camp789",
            currentMinutes: 60,
            requiredMinutes: 60,
            isClaimed: true
        )
        
        let result = await claimService.claimDrop(progress)
        
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, "Drop already claimed")
    }
    
    func testClaimDropNotCompleteFails() async throws {
        let progress = Progress(
            id: "instance123",
            dropId: "drop456",
            dropName: "Test Drop",
            campaignId: "camp789",
            currentMinutes: 30,
            requiredMinutes: 60,
            isClaimed: false
        )
        
        let result = await claimService.claimDrop(progress)
        
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, "Drop not ready to claim")
    }
    
    func testClaimDropApiError() async throws {
        let progress = Progress(
            id: "instance123",
            dropId: "drop456",
            dropName: "Test Drop",
            campaignId: "camp789",
            currentMinutes: 60,
            requiredMinutes: 60,
            isClaimed: false
        )
        
        MockURLProtocol.stubError = NSError(domain: "test", code: 500, userInfo: nil)
        
        let result = await claimService.claimDrop(progress)
        
        XCTAssertFalse(result.success)
        XCTAssertNotNil(result.error)
    }

    // MARK: - Repeat claim guard

    func testRepeatClaimGuardSuppressesInstanceAfterRepeatedAcceptedClaims() {
        var guardState = RepeatClaimGuard()
        for _ in 0..<RepeatClaimGuard.maxAcceptedClaims {
            XCTAssertFalse(guardState.isSuppressed("instance-1"))
            guardState.recordAcceptedClaim("instance-1")
        }
        XCTAssertTrue(guardState.isSuppressed("instance-1"))
        XCTAssertFalse(guardState.isSuppressed("instance-2"))
    }

    func testRepeatClaimGuardReportsSuppressionOnce() {
        var guardState = RepeatClaimGuard()
        XCTAssertTrue(guardState.markReported("instance-1"))
        XCTAssertFalse(guardState.markReported("instance-1"))
    }
    func testAcceptedClaimsStaySuppressedAfterRestartAndAccountsStaySeparate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = directory.appendingPathComponent("first.json")
        var first = RepeatClaimGuard(fileURL: firstURL)
        first.recordAcceptedClaim("instance", accountConnected: false)
        var restarted = RepeatClaimGuard(fileURL: firstURL)
        XCTAssertFalse(restarted.isSuppressed("instance"))
        restarted.recordAcceptedClaim("instance", accountConnected: false)
        var suppressed = RepeatClaimGuard(fileURL: firstURL)
        XCTAssertTrue(suppressed.isSuppressed("instance"))
        let otherAccount = RepeatClaimGuard(fileURL: directory.appendingPathComponent("second.json"))
        XCTAssertFalse(otherAccount.isSuppressed("instance"))

        suppressed.allowRetryAfterLinking("instance", accountConnected: false)
        XCTAssertTrue(suppressed.isSuppressed("instance"))
        suppressed.allowRetryAfterLinking("instance", accountConnected: true)
        XCTAssertFalse(suppressed.isSuppressed("instance"), "Linking repairs the reason for suppression")
        XCTAssertFalse(RepeatClaimGuard(fileURL: firstURL).isSuppressed("instance"))
    }

    func testPollingAndPubSubCannotClaimTheSameInstanceConcurrently() {
        var history = RepeatClaimGuard()
        XCTAssertTrue(history.beginClaim("instance"))
        XCTAssertFalse(history.beginClaim("instance"))
        XCTAssertTrue(history.beginClaim("other-instance"))
        history.endClaim("instance")
        XCTAssertTrue(history.beginClaim("instance"), "A failed request remains retryable")
    }

    func testOnlyConfirmedClaimsNotifyAndTheyStayDeduplicatedAcrossRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let historyURL = directory.appendingPathComponent("history.json")
        let progress = Progress(
            id: "instance", dropId: "drop", dropName: "Reward", campaignId: "campaign",
            currentMinutes: 60, requiredMinutes: 60
        )
        let counter = ClaimCallbackCounter()
        let engine = MinerEngine(clientId: "test", tokenStore: InMemoryTokenStore())
        await engine._testInstallClaimHistory(historyURL, accepted: progress)
        await engine.setDropClaimedHandler { _ in counter.increment() }
        let unconfirmed = InventorySnapshot(accountId: "account", benefitIDs: [], progress: [progress])
        await engine.confirmPendingClaims(in: unconfirmed)
        XCTAssertEqual(counter.value, 0, "Mutation acceptance alone must not count or notify")
        let restarted = MinerEngine(clientId: "test", tokenStore: InMemoryTokenStore())
        await restarted._testInstallClaimHistory(historyURL)
        await restarted.setDropClaimedHandler { _ in counter.increment() }
        var confirmed = progress
        confirmed.isClaimed = true
        let snapshot = InventorySnapshot(accountId: "account", benefitIDs: [], progress: [confirmed])
        await restarted.confirmPendingClaims(in: snapshot)
        await restarted.confirmPendingClaims(in: snapshot)
        XCTAssertEqual(counter.value, 1)
        let third = MinerEngine(clientId: "test", tokenStore: InMemoryTokenStore())
        await third._testInstallClaimHistory(historyURL)
        await third.setDropClaimedHandler { _ in counter.increment() }
        await third.reportConfirmedClaim(confirmed)
        XCTAssertEqual(counter.value, 1, "A relaunch or duplicate event must not report the reward again")
    }

    func testAwardedBenefitConfirmsAClaimThatDisappearedFromProgress() async {
        let engine = MinerEngine(clientId: "test", tokenStore: InMemoryTokenStore())
        let counter = ClaimCallbackCounter()
        let pending = Progress(
            id: "instance", dropId: "drop", dropName: "Reward", campaignId: "campaign",
            currentMinutes: 60, requiredMinutes: 60
        )
        await engine._testInstallClaimHistory(nil, accepted: pending)
        await engine._testSetClaimCampaign(Campaign(
            id: "campaign", name: "Campaign", game: Game(id: "game", name: "Game"),
            startDate: .distantPast, endDate: .distantFuture,
            drops: [Drop(id: "drop", name: "Reward", requiredMinutes: 60, benefitID: "benefit")],
            isAccountConnected: true
        ))
        await engine.setDropClaimedHandler { _ in counter.increment() }
        await engine._testSyncClaimInventory(InventorySnapshot(accountId: "account", benefitIDs: [], progress: []))
        XCTAssertEqual(counter.value, 0, "Disappearing from progress alone does not prove a claim")
        await engine._testSyncClaimInventory(InventorySnapshot(accountId: "account", benefitIDs: ["benefit"], progress: []))
        XCTAssertEqual(counter.value, 1, "Awarded benefits confirm drops Twitch removes from in-progress inventory")
    }

    func testConfirmationDoesNotCountAnUnrelatedDropInstance() async {
        let counter = ClaimCallbackCounter()
        let engine = MinerEngine(clientId: "test", tokenStore: InMemoryTokenStore())
        let pending = Progress(
            id: "pending", dropId: "drop", dropName: "Reward", campaignId: "campaign",
            currentMinutes: 60, requiredMinutes: 60
        )
        await engine._testInstallClaimHistory(nil, accepted: pending)
        await engine.setDropClaimedHandler { _ in counter.increment() }
        let unrelated = Progress(
            id: "other-instance", dropId: "drop", dropName: "Reward", campaignId: "other-campaign",
            currentMinutes: 60, requiredMinutes: 60, isClaimed: true
        )
        await engine.confirmPendingClaims(in: InventorySnapshot(accountId: "account", benefitIDs: [], progress: [unrelated]))
        XCTAssertEqual(counter.value, 0)
    }

}


extension MinerEngine {
    func _testSetClaimCampaign(_ campaign: Campaign) { allCampaigns = [campaign] }

    func _testSyncClaimInventory(_ snapshot: InventorySnapshot) async {
        syncCampaigns(with: snapshot)
        await confirmPendingClaims(in: snapshot)
    }

    func _testInstallClaimHistory(_ url: URL?, accepted progress: Progress? = nil) {
        repeatClaimGuard = RepeatClaimGuard(fileURL: url)
        if let progress { repeatClaimGuard.recordAcceptedClaim(progress.id, progress: progress) }
    }
}

private final class ClaimCallbackCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
