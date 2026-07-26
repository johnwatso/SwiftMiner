import XCTest
@testable import SwiftMinerCore

final class EarningLedgerStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("earning-ledger-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore(retentionDays: Int = 7, persistInterval: TimeInterval = 0) -> EarningLedgerStore {
        EarningLedgerStore(
            fileURL: directory.appendingPathComponent("ledger.json"),
            retentionDays: retentionDays,
            persistInterval: persistInterval
        )
    }

    /// A round epoch hour, so bucket boundaries in the tests are unambiguous.
    private func hour(_ index: Int) -> Date {
        Date(timeIntervalSince1970: 1_699_999_200 + Double(index) * 3600)
    }

    func testWatchingAndEarningAccumulateIntoTheSameHour() async {
        let store = makeStore()
        let base = hour(0).addingTimeInterval(90)

        await store.recordWatching(accountID: "a", seconds: 600, at: base)
        await store.recordWatching(accountID: "a", seconds: 300, at: base.addingTimeInterval(600))
        await store.recordEarned(accountID: "a", minutes: 14, claims: 1, at: base.addingTimeInterval(700))

        let buckets = await store.buckets(for: "a")
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets.first?.hourStart, hour(0))
        XCTAssertEqual(buckets.first?.watchingSeconds, 900)
        XCTAssertEqual(buckets.first?.earnedMinutes, 14)
        XCTAssertEqual(buckets.first?.claimedDrops, 1)
    }

    func testWritesAreSplitAcrossHourBoundaries() async {
        let store = makeStore()

        await store.recordWatching(accountID: "a", seconds: 1800, at: hour(0).addingTimeInterval(60))
        await store.recordWatching(accountID: "a", seconds: 1800, at: hour(1).addingTimeInterval(60))

        let buckets = await store.buckets(for: "a")
        XCTAssertEqual(buckets.map(\.hourStart), [hour(0), hour(1)])
        XCTAssertEqual(buckets.map(\.watchingSeconds), [1800, 1800])
    }

    /// The whole point of the ledger: an hour of watching that banked nothing is visible
    /// after the fact, and an hour that earned normally is not flagged.
    func testNonEarningHoursAreIdentified() async {
        let store = makeStore()

        await store.recordWatching(accountID: "a", seconds: 3500, at: hour(0).addingTimeInterval(60))
        await store.recordEarned(accountID: "a", minutes: 58, at: hour(0).addingTimeInterval(120))

        await store.recordWatching(accountID: "a", seconds: 3500, at: hour(1).addingTimeInterval(60))

        // Too short a stretch to conclude anything.
        await store.recordWatching(accountID: "a", seconds: 120, at: hour(2).addingTimeInterval(60))

        let flagged = await store.nonEarningHours()
        XCTAssertEqual(flagged.map(\.hourStart), [hour(1)])
    }

    func testSummaryReportsEarningRateAcrossHours() async {
        let store = makeStore()

        await store.recordWatching(accountID: "a", seconds: 3600, at: hour(0).addingTimeInterval(60))
        await store.recordEarned(accountID: "a", minutes: 60, claims: 2, at: hour(0).addingTimeInterval(120))
        await store.recordWatching(accountID: "a", seconds: 3600, at: hour(1).addingTimeInterval(60))

        let summary = await store.summary(for: "a")
        XCTAssertEqual(summary.watchingSeconds, 7200)
        XCTAssertEqual(summary.earnedMinutes, 60)
        XCTAssertEqual(summary.claimedDrops, 2)
        XCTAssertEqual(summary.coveredHours, 2)
        XCTAssertEqual(summary.nonEarningHours, 1)
        XCTAssertEqual(summary.earnedMinutesPerWatchedHour, 30, accuracy: 0.001)
    }

    func testSummariesAreSeparatedPerMiner() async {
        let store = makeStore()

        await store.recordWatching(accountID: "a", seconds: 3600, at: hour(0).addingTimeInterval(60))
        await store.recordEarned(accountID: "a", minutes: 60, at: hour(0).addingTimeInterval(60))
        await store.recordWatching(accountID: "b", seconds: 3600, at: hour(0).addingTimeInterval(60))

        let summaries = await store.summaries()
        XCTAssertEqual(summaries.map(\.accountID), ["a", "b"])
        XCTAssertEqual(summaries.first?.earnedMinutes, 60)
        XCTAssertEqual(summaries.last?.earnedMinutes, 0)
        XCTAssertEqual(summaries.last?.nonEarningHours, 1)
    }

    func testLedgerSurvivesRestart() async throws {
        let store = makeStore()
        await store.recordWatching(accountID: "a", seconds: 1200, at: hour(0).addingTimeInterval(60))
        await store.recordEarned(accountID: "a", minutes: 20, at: hour(0).addingTimeInterval(120))
        try await store.flush()

        let reopened = makeStore()
        let buckets = await reopened.buckets(for: "a")
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets.first?.watchingSeconds, 1200)
        XCTAssertEqual(buckets.first?.earnedMinutes, 20)
    }

    func testBucketsOlderThanRetentionArePruned() async {
        let store = makeStore(retentionDays: 1)

        await store.recordWatching(accountID: "a", seconds: 600, at: hour(0))
        // Two days later — the first bucket is now outside the window.
        await store.recordWatching(accountID: "a", seconds: 600, at: hour(48))

        let buckets = await store.buckets(for: "a")
        XCTAssertEqual(buckets.map(\.hourStart), [hour(48)])
    }

    func testThrottlingDefersWritesButFlushForcesThem() async throws {
        let fileURL = directory.appendingPathComponent("throttled.json")
        let store = EarningLedgerStore(fileURL: fileURL, persistInterval: 3600)

        // The first write always persists, establishing the throttle window.
        await store.recordWatching(accountID: "a", seconds: 60, at: hour(0).addingTimeInterval(60))
        let afterFirst = try Data(contentsOf: fileURL)

        // Same hour, inside the interval: nothing new should reach disk.
        await store.recordWatching(accountID: "a", seconds: 60, at: hour(0).addingTimeInterval(120))
        XCTAssertEqual(try Data(contentsOf: fileURL), afterFirst)

        try await store.flush()
        XCTAssertNotEqual(try Data(contentsOf: fileURL), afterFirst)
    }

    func testHourRolloverForcesAWriteEvenWhenThrottled() async throws {
        let fileURL = directory.appendingPathComponent("rollover.json")
        let store = EarningLedgerStore(fileURL: fileURL, persistInterval: 86_400)

        await store.recordWatching(accountID: "a", seconds: 60, at: hour(0).addingTimeInterval(60))
        let afterFirst = try Data(contentsOf: fileURL)

        await store.recordWatching(accountID: "a", seconds: 60, at: hour(1).addingTimeInterval(60))
        XCTAssertNotEqual(try Data(contentsOf: fileURL), afterFirst)
    }
}
