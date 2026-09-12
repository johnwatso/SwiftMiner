import XCTest
@testable import SwiftMinerCore

/// A hash is only worth trusting if the document behind it answers the question SwiftMiner
/// is asking. Twitch keys persisted queries by document, not operation name, so a
/// registered hash can answer 200 with an entirely different shape.
final class TwitchCompatibilityContractTests: XCTestCase {
    private func body(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    func testInventoryContractAcceptsTheDocumentSwiftMinerReads() {
        let data = body([
            "data": ["currentUser": ["inventory": ["gameEventDrops": []]]]
        ])
        XCTAssertTrue(GQLQuery.inventory.responseSatisfiesContract(data))
    }

    func testInventoryContractRejectsASiblingDocument() {
        // Valid, well-formed, and useless: this is the shape that marked every claimed
        // drop unclaimed and sent finished campaigns back into mining.
        let data = body([
            "data": ["currentUser": ["inventory": ["dropCampaignsInProgress": []]]]
        ])
        XCTAssertFalse(GQLQuery.inventory.responseSatisfiesContract(data))
    }

    func testExplicitNullFailsTheContract() {
        let data = body([
            "data": ["currentUser": ["inventory": ["gameEventDrops": NSNull()]]]
        ])
        XCTAssertFalse(GQLQuery.inventory.responseSatisfiesContract(data))
    }

    func testDashboardContractAcceptsEitherShapeTwitchHasServed() {
        XCTAssertTrue(GQLQuery.viewerDropsDashboard.responseSatisfiesContract(
            body(["data": ["currentUser": ["dropCampaigns": []]]])
        ))
        XCTAssertTrue(GQLQuery.viewerDropsDashboard.responseSatisfiesContract(
            body(["data": ["dropCampaigns": []]])
        ))
        XCTAssertFalse(GQLQuery.viewerDropsDashboard.responseSatisfiesContract(
            body(["data": ["currentUser": [:]]])
        ))
    }

    func testAnOperationWithoutAContractIsNeverRejected() {
        // A contract that cannot be stated safely must not block adoption: these responses
        // legitimately omit their payload (a campaign the account cannot see, a restricted
        // channel), so asserting them would retire good hashes on ordinary days.
        XCTAssertTrue(GQLQuery.dropCampaignDetails.responseContracts.isEmpty)
        XCTAssertTrue(GQLQuery.playbackAccessToken.responseContracts.isEmpty)
        XCTAssertTrue(GQLQuery.dropCampaignDetails.responseSatisfiesContract(body(["data": [:]])))
    }

    func testMalformedBodyFailsAContractItCannotSatisfy() {
        XCTAssertFalse(GQLQuery.inventory.responseSatisfiesContract(Data("not json".utf8)))
        // …but still passes where nothing is asserted.
        XCTAssertTrue(GQLQuery.playbackAccessToken.responseSatisfiesContract(Data("not json".utf8)))
    }
}

/// The recovery signal fires on breakage, never on difference.
final class TwitchRecoverySignalTests: XCTestCase {
    private var suiteName: String!
    private var store: TwitchQueryHashStore!

    override func setUp() {
        super.setUp()
        suiteName = "com.swiftminer.tests.recovery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        store = TwitchQueryHashStore(defaults: defaults)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testNothingNeedsRecoveryByDefault() {
        XCTAssertTrue(store.queriesNeedingRecovery().isEmpty)
    }

    func testABrokenBundledHashIsRecordedOnce() {
        store.recordRecoveryNeeded(for: .directoryPageGame)
        store.recordRecoveryNeeded(for: .directoryPageGame)
        XCTAssertEqual(store.queriesNeedingRecovery(), [.directoryPageGame])
    }

    func testAdoptingAWorkingHashClearsTheAlarm() {
        let hash = String(repeating: "f", count: 64)
        store.recordRecoveryNeeded(for: .inventory)
        store.submitCandidate(hash, for: .inventory)
        store.accept(hash, for: .inventory)
        XCTAssertTrue(store.queriesNeedingRecovery().isEmpty)
    }
}

/// Category slugs for the recovery scan's directory page.
final class TwitchCategorySlugTests: XCTestCase {
    func testSlugMatchesTwitchsOwnCategoryFormat() {
        XCTAssertEqual(slug("Rainbow Six Siege"), "rainbow-six-siege")
        XCTAssertEqual(slug("THE FINALS"), "the-finals")
        XCTAssertEqual(slug("ARC Raiders"), "arc-raiders")
    }

    func testPunctuationAndRunsCollapseToOneHyphen() {
        XCTAssertEqual(slug("Tom Clancy's  Rainbow Six"), "tom-clancy-s-rainbow-six")
        XCTAssertEqual(slug("  Spaced  Out  "), "spaced-out")
    }

    func testNothingUsableYieldsNoSlug() {
        XCTAssertNil(slug(""))
        XCTAssertNil(slug("   "))
        XCTAssertNil(slug("!!!"))
    }

    /// Mirrors TwitchCompatibilityRecovery.categorySlug, which lives in the app target.
    private func slug(_ name: String) -> String? {
        let allowed = CharacterSet.alphanumerics
        let pieces = name.lowercased().unicodeScalars
            .split { !allowed.contains($0) }
            .map(String.init)
        let value = pieces.joined(separator: "-")
        return value.isEmpty ? nil : value
    }
}

/// A queued candidate must not sit unvalidated behind whatever the mining loop happens
/// to need next.
final class TwitchCandidateSettlingTests: XCTestCase {
    private var suiteName: String!
    private var store: TwitchQueryHashStore!

    override func setUp() {
        super.setUp()
        suiteName = "com.swiftminer.tests.settle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        store = TwitchQueryHashStore(defaults: defaults)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testSettleAttemptIsRecordedAndReadBack() throws {
        XCTAssertNil(store.lastSettleAttempt)
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        store.recordSettleAttempt(at: when)
        let recorded = try XCTUnwrap(store.lastSettleAttempt)
        XCTAssertEqual(recorded.timeIntervalSince1970, when.timeIntervalSince1970, accuracy: 0.001)
    }

    func testAClaimMutationIsNeverExercisedJustToTestItsHash() {
        // Firing this to validate a hash would claim a drop as a side effect of a
        // compatibility check. It has to wait for a real claim.
        XCTAssertFalse(
            [GQLQuery.viewerDropsDashboard, .inventory].contains(.dropsPageClaimDropRewards)
        )
    }
}

/// When Twitch retires a persisted query, an operation whose document SwiftMiner can state
/// itself must not have to wait for anyone to ship a new hash.
final class TwitchDocumentFallbackTests: XCTestCase {
    func testClaimMutationCanBeSentWithoutAHash() throws {
        let document = try XCTUnwrap(GQLQuery.dropsPageClaimDropRewards.documentFallback)

        // Must match what `claimDrop` sends and what its parser reads back.
        XCTAssertTrue(document.contains("mutation DropsPage_ClaimDropRewards"))
        XCTAssertTrue(document.contains("$input: ClaimDropRewardsInput!"))
        XCTAssertTrue(document.contains("claimDropRewards(input: $input)"))
        XCTAssertTrue(document.contains("status"))
    }

    func testOperationNameInTheDocumentMatchesTheOperationItStandsInFor() throws {
        let document = try XCTUnwrap(GQLQuery.dropsPageClaimDropRewards.documentFallback)
        XCTAssertTrue(document.contains(GQLQuery.dropsPageClaimDropRewards.rawValue))
    }

    func testAnOperationWithoutAStatedDocumentOffersNoFallback() {
        // Deliberate: a document that is merely close would parse into the wrong shape,
        // which is worse than declining to guess.
        XCTAssertNil(GQLQuery.inventory.documentFallback)
        XCTAssertNil(GQLQuery.viewerDropsDashboard.documentFallback)
    }
}

/// Twitch serving a different document under the same operation name is routine, and must
/// not be reported as a problem while SwiftMiner's own query still works.
final class TwitchDifferenceVsBreakageTests: XCTestCase {
    private var suiteName: String!
    private var store: TwitchQueryHashStore!

    override func setUp() {
        super.setUp()
        suiteName = "com.swiftminer.tests.difference.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        store = TwitchQueryHashStore(defaults: defaults)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testAWorkingQueryIsNotFlaggedJustBecauseTwitchDiffers() {
        let sibling = String(repeating: "1", count: 64)
        store.recordObservation(sibling, for: .inventory)
        store.reject(sibling, for: .inventory)

        // Observed differs from what we send, but nothing recorded us as broken.
        XCTAssertNotEqual(store.observedHash(for: .inventory), store.resolution(for: .inventory).hash)
        XCTAssertTrue(store.queriesNeedingRecovery().isEmpty)
    }

    func testOnlyABrokenBundledHashCountsAsBreakage() {
        store.recordRecoveryNeeded(for: .inventory)
        XCTAssertEqual(store.queriesNeedingRecovery(), [.inventory])
    }
}
