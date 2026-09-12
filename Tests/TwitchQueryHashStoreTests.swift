import XCTest
@testable import SwiftMinerCore

final class TwitchQueryHashStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: TwitchQueryHashStore!

    override func setUp() {
        super.setUp()
        suiteName = "com.swiftminer.tests.query-hashes.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        store = TwitchQueryHashStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testBundledHashIsPermanentFallback() {
        let resolution = store.resolution(for: .viewerDropsDashboard)

        XCTAssertEqual(resolution.source, .bundled)
        XCTAssertEqual(resolution.hash, GQLHashes.viewerDropsDashboard)
    }

    func testCandidateMustBeLowercaseSHA256() {
        XCTAssertFalse(store.submitCandidate("not-a-hash", for: .viewerDropsDashboard))
        XCTAssertFalse(store.submitCandidate(String(repeating: "A", count: 64), for: .viewerDropsDashboard))
        XCTAssertNil(store.candidate(for: .viewerDropsDashboard))
    }

    func testCandidateIsUsedThenPromotedOnlyAfterAcceptance() {
        let candidate = String(repeating: "a", count: 64)

        XCTAssertTrue(store.submitCandidate(candidate, for: .viewerDropsDashboard))
        XCTAssertEqual(
            store.resolution(for: .viewerDropsDashboard),
            TwitchQueryHashResolution(hash: candidate, source: .candidate)
        )

        store.accept(candidate, for: .viewerDropsDashboard)

        XCTAssertNil(store.candidate(for: .viewerDropsDashboard))
        XCTAssertEqual(store.override(for: .viewerDropsDashboard), candidate)
        XCTAssertEqual(store.resolution(for: .viewerDropsDashboard).source, .override)
        XCTAssertNotNil(store.date(for: .accepted, query: .viewerDropsDashboard))
    }

    func testRejectedCandidateReturnsToBundledHash() {
        let candidate = String(repeating: "b", count: 64)
        XCTAssertTrue(store.submitCandidate(candidate, for: .inventory))

        store.reject(candidate, for: .inventory)

        XCTAssertNil(store.candidate(for: .inventory))
        XCTAssertNil(store.override(for: .inventory))
        XCTAssertEqual(store.resolution(for: .inventory).hash, GQLHashes.inventory)
        XCTAssertNotNil(store.date(for: .rejected, query: .inventory))
    }

    func testStaleCandidateFailureDoesNotRemovePromotedOverride() {
        let candidate = String(repeating: "e", count: 64)
        XCTAssertTrue(store.submitCandidate(candidate, for: .inventory))
        store.accept(candidate, for: .inventory)

        XCTAssertFalse(store.reject(candidate, for: .inventory, source: .candidate))

        XCTAssertEqual(store.override(for: .inventory), candidate)
        XCTAssertNil(store.date(for: .rejected, query: .inventory))
    }

    func testResetNeverRemovesBundledHash() {
        let candidate = String(repeating: "c", count: 64)
        XCTAssertTrue(store.submitCandidate(candidate, for: .directoryPageGame))
        store.accept(candidate, for: .directoryPageGame)

        store.reset(.directoryPageGame)

        XCTAssertEqual(
            store.resolution(for: .directoryPageGame),
            TwitchQueryHashResolution(
                hash: GQLHashes.directoryPage_Game,
                source: .bundled
            )
        )
    }

    func testBundledAndAlreadyAcceptedObservationsDoNotBecomeCandidates() {
        XCTAssertTrue(
            store.submitCandidate(GQLHashes.viewerDropsDashboard, for: .viewerDropsDashboard)
        )
        XCTAssertNil(store.candidate(for: .viewerDropsDashboard))

        let accepted = String(repeating: "d", count: 64)
        XCTAssertTrue(store.submitCandidate(accepted, for: .viewerDropsDashboard))
        store.accept(accepted, for: .viewerDropsDashboard)
        XCTAssertTrue(store.submitCandidate(accepted, for: .viewerDropsDashboard))

        XCTAssertNil(store.candidate(for: .viewerDropsDashboard))
        XCTAssertEqual(store.override(for: .viewerDropsDashboard), accepted)
    }

    func testAutomaticDiscoveryDefaultsOff() {
        XCTAssertFalse(store.automaticDiscoveryEnabled)
        store.automaticDiscoveryEnabled = true
        XCTAssertTrue(store.automaticDiscoveryEnabled)
    }

    func testObservationIsRecordedWhenHashStillMatchesBundledFallback() {
        XCTAssertTrue(
            store.recordObservation(GQLHashes.viewerDropsDashboard, for: .viewerDropsDashboard)
        )

        XCTAssertEqual(
            store.observedHash(for: .viewerDropsDashboard),
            GQLHashes.viewerDropsDashboard
        )
        XCTAssertNotNil(store.date(for: .observed, query: .viewerDropsDashboard))
        XCTAssertNil(store.candidate(for: .viewerDropsDashboard))
    }

    func testClearingObservationsPreservesCandidateAndOverrideState() {
        let candidate = String(repeating: "f", count: 64)
        XCTAssertTrue(store.recordObservation(candidate, for: .inventory))

        store.clearObservations()

        XCTAssertNil(store.observedHash(for: .inventory))
        XCTAssertNil(store.date(for: .observed, query: .inventory))
        XCTAssertEqual(store.candidate(for: .inventory), candidate)
    }

    // MARK: Retired hashes

    func testRejectingAPromotedCandidateRemovesItWhereverItLanded() {
        let hash = String(repeating: "a", count: 64)
        store.submitCandidate(hash, for: .inventory)
        // Transport success promotes before any response body is read.
        store.accept(hash, for: .inventory)
        XCTAssertEqual(store.resolution(for: .inventory).hash, hash)

        // The parser only now discovers the reply is unusable. An unqualified source must
        // retire the hash from the override slot it was promoted into.
        XCTAssertTrue(store.reject(hash, for: .inventory))

        XCTAssertEqual(store.resolution(for: .inventory).hash, GQLQuery.inventory.bundledHash)
        XCTAssertEqual(store.resolution(for: .inventory).source, .bundled)
    }

    func testRejectedHashIsNotQueuedAgainByANewObservation() {
        let hash = String(repeating: "b", count: 64)
        store.submitCandidate(hash, for: .inventory)
        store.accept(hash, for: .inventory)
        store.reject(hash, for: .inventory)

        // Twitch serves the same hash on every page load; re-queueing it is the loop that
        // left the status row checking forever.
        XCTAssertFalse(store.recordObservation(hash, for: .inventory))
        XCTAssertNil(store.candidate(for: .inventory))
        XCTAssertEqual(store.resolution(for: .inventory).source, .bundled)
        // The observation itself is still recorded, so the UI can say Twitch has changed.
        XCTAssertEqual(store.observedHash(for: .inventory), hash)
    }

    func testAnExplicitRecheckGivesARejectedHashAnotherGo() {
        let hash = String(repeating: "c", count: 64)
        store.submitCandidate(hash, for: .inventory)
        store.accept(hash, for: .inventory)
        store.reject(hash, for: .inventory)

        store.clearObservations()

        XCTAssertNil(store.rejectedHash(for: .inventory))
        XCTAssertTrue(store.recordObservation(hash, for: .inventory))
        XCTAssertEqual(store.candidate(for: .inventory), hash)
    }

    func testADifferentHashIsStillTriedAfterOneWasRejected() {
        let bad = String(repeating: "d", count: 64)
        let next = String(repeating: "e", count: 64)
        store.submitCandidate(bad, for: .inventory)
        store.accept(bad, for: .inventory)
        store.reject(bad, for: .inventory)

        XCTAssertTrue(store.recordObservation(next, for: .inventory))
        XCTAssertEqual(store.candidate(for: .inventory), next)
    }
}
