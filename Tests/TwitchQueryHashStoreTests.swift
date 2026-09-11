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
}
