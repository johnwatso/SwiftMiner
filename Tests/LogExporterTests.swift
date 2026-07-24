import XCTest
@testable import SwiftMinerCore
@testable import SwiftMiner

final class LogRedactorTests: XCTestCase {

    func testRedactsTwitchOAuthToken() {
        let input = "Authorizing miner with oauth:abcd1234efgh5678ijkl9012mnop3456 for stream"
        let output = LogRedactor.redact(input)
        XCTAssertFalse(output.contains("abcd1234"))
        XCTAssertTrue(output.contains("oauth:<redacted>"))
    }

    func testRedactsBearerHeader() {
        let input = "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payloadhere.signature"
        let output = LogRedactor.redact(input)
        XCTAssertFalse(output.contains("eyJhbGciOiJIUzI1NiJ9"))
        XCTAssertTrue(output.contains("Bearer <redacted>") || output.contains("<jwt-redacted>"))
    }

    func testRedactsCookieValues() {
        let input = "Cookie: auth-token=xy12abc34; persistent=98zzz76; login=user_name"
        let output = LogRedactor.redact(input)
        XCTAssertFalse(output.contains("xy12abc34"))
        XCTAssertFalse(output.contains("98zzz76"))
        XCTAssertTrue(output.contains("auth-token=<redacted>"))
        XCTAssertTrue(output.contains("persistent=<redacted>"))
    }

    func testRedactsCookieJsonForm() {
        let input = #"{"auth-token":"sekrit-value","other":"ok"}"#
        let output = LogRedactor.redact(input)
        XCTAssertFalse(output.contains("sekrit-value"))
        XCTAssertTrue(output.contains(#""auth-token":"<redacted>""#))
    }

    func testRedactsEmailAddresses() {
        let input = "User johnhendersonnet@icloud.com signed in"
        let output = LogRedactor.redact(input)
        XCTAssertFalse(output.contains("johnhendersonnet"))
        XCTAssertFalse(output.contains("icloud.com"))
        XCTAssertTrue(output.contains("<email>"))
    }

    func testRedactsDiscordIdHinted() {
        let input = "discord_id=123456789012345678 reported in"
        let output = LogRedactor.redact(input)
        XCTAssertFalse(output.contains("123456789012345678"))
        XCTAssertTrue(output.contains("<discord-id>"))
    }

    func testLeavesShortIdentifiersAlone() {
        // Short ids and ordinary words must not be redacted by the generic rule.
        let input = "campaign id=loh-launch-week-2 status=watching"
        let output = LogRedactor.redact(input)
        XCTAssertEqual(output, input)
    }
}

final class LogExporterTests: XCTestCase {

    private func event(
        _ message: String,
        level: String = "info",
        miner: String? = nil,
        offset: TimeInterval = 0
    ) -> LogExporter.Snapshot.Event {
        LogExporter.Snapshot.Event(
            timestamp: Date(timeIntervalSince1970: 1_730_000_000 + offset),
            level: level,
            minerId: miner,
            message: message
        )
    }

    private func snapshot(
        miners: [LogExporter.Snapshot.Miner] = [],
        events: [LogExporter.Snapshot.Event] = [],
        settings: [(String, String)] = [("logLevel", "info")],
        resourceUsage: ResourceUsageMonitor.Diagnostics? = nil,
        performance: PerformanceDiagnostics.Snapshot? = nil,
        earningSummaries: [EarningLedgerSummary] = [],
        nonEarningHours: [EarningLedgerBucket] = [],
        earningBuckets: [EarningLedgerBucket] = [],
        minerNames: [String: String] = [:]
    ) -> LogExporter.Snapshot {
        LogExporter.Snapshot(
            generatedAt: Date(timeIntervalSince1970: 1_730_000_500),
            appVersion: "1.21",
            appBuild: "2026050414",
            osVersion: "macOS 15.0",
            arch: "arm64",
            miners: miners,
            settings: settings,
            resourceUsage: resourceUsage,
            performance: performance,
            earningSummaries: earningSummaries,
            nonEarningHours: nonEarningHours,
            earningBuckets: earningBuckets,
            minerNames: minerNames,
            events: events
        )
    }

    func testReportRendersWithEmptyInputs() {
        let report = LogExporter.buildReport(snapshot())
        XCTAssertTrue(report.contains("=== SwiftMiner Diagnostic Report ==="))
        XCTAssertTrue(report.contains("App: 1.21 (build 2026050414)"))
        XCTAssertTrue(report.contains("=== Miners (0) ==="))
        XCTAssertTrue(report.contains("=== Events (oldest → newest, 0) ==="))
    }

    func testReportRedactsSecretsInsideEvents() {
        let snap = snapshot(events: [
            event("connecting with oauth:abcd1234efgh5678ijkl9012mnop3456", miner: "gabe")
        ])
        let report = LogExporter.buildReport(snap)
        XCTAssertFalse(report.contains("abcd1234"))
        XCTAssertTrue(report.contains("oauth:<redacted>"))
        XCTAssertTrue(report.contains("gabe"))
    }

    func testReportIncludesMinerStuckDuration() {
        let now = Date(timeIntervalSince1970: 1_730_000_500)
        let miner = LogExporter.Snapshot.Miner(
            id: "gabe",
            username: "gabe",
            nickname: "Gabe",
            status: "watching",
            needsAuth: false,
            isRunning: true,
            dropsClaimed: 12,
            currentCampaign: "LoH Launch Drops Week 2",
            currentCampaignId: "abc-123",
            priorityGames: ["Skull and Bones"],
            statusChangedAt: now.addingTimeInterval(-2_820), // 47m ago
            statusLabel: "Waiting — Refreshing campaigns",
            health: "idle",
            workerState: "running",
            workerTaskID: "task-123",
            isHealthy: false,
            isStalled: false,
            showsNoRecentActivityAttention: false,
            lastEventAt: now.addingTimeInterval(-120),
            lastSuccessfulPollAt: now.addingTimeInterval(-240),
            lastCampaignRefreshAt: now.addingTimeInterval(-360),
            stallConfidencePercent: 50,
            stallSignals: ["No successful poll in 15m"]
        )
        let report = LogExporter.buildReport(snapshot(miners: [miner]), now: now)
        XCTAssertTrue(report.contains("[Gabe]"))
        XCTAssertTrue(report.contains("status=watching"))
        XCTAssertTrue(report.contains("inStatusFor=47m0s"))
        XCTAssertTrue(report.contains(#"statusLabel="Waiting — Refreshing campaigns""#))
        XCTAssertTrue(report.contains("health=idle workerState=running isHealthy=false isStalled=false showsNoRecentActivityAttention=false"))
        XCTAssertTrue(report.contains("workerTaskID=task-123"))
        XCTAssertTrue(report.contains("lastEventAt=2024-10-27T03:39:40Z (age=2m0s)"))
        XCTAssertTrue(report.contains("lastSuccessfulPollAt=2024-10-27T03:37:40Z (age=4m0s)"))
        XCTAssertTrue(report.contains("lastCampaignRefreshAt=2024-10-27T03:35:40Z (age=6m0s)"))
        XCTAssertTrue(report.contains("stallConfidence=50% signals=[No successful poll in 15m]"))
        XCTAssertTrue(report.contains("LoH Launch Drops Week 2"))
    }

    func testReportIncludesPerformanceDiagnostics() async {
        let now = Date(timeIntervalSince1970: 1_730_000_500)
        await PerformanceDiagnostics.shared.reset()
        await PerformanceDiagnostics.shared.recordRequest(
            operation: "ViewerDropsDashboard",
            durationSeconds: 1.25,
            succeeded: true,
            retryCount: 1,
            rateLimitWaitSeconds: 0.2,
            finishedAt: now.addingTimeInterval(-30)
        )
        await PerformanceDiagnostics.shared.recordMiningCycle(
            PerformanceDiagnostics.MiningCycleTiming(
                minerId: "miner-1",
                minerLabel: "Gabe",
                startedAt: now.addingTimeInterval(-120),
                finishedAt: now.addingTimeInterval(-118),
                outcome: "watching",
                totalSeconds: 2.0,
                campaignFetchSeconds: 0.8,
                claimCheckSeconds: 0.1,
                channelSelectionSeconds: 0.9,
                watchStartupSeconds: 0.2,
                candidateCount: 3,
                selectedCampaign: "LoH Launch Drops Week 2",
                selectedChannel: "StreamerOne"
            )
        )
        let performance = await PerformanceDiagnostics.shared.snapshot()
        let usage = ResourceUsageMonitor.Diagnostics(
            isRunning: true,
            startedAt: now.addingTimeInterval(-3600),
            durationSeconds: 3600,
            sampleCount: 2,
            currentCPUPercent: 12.25,
            averageCPUPercent: 8.5,
            peakCPUPercent: 24.0,
            currentMemoryBytes: 130 * 1024 * 1024,
            averageMemoryBytes: 125 * 1024 * 1024,
            peakMemoryBytes: 132 * 1024 * 1024,
            firstSampleAt: now.addingTimeInterval(-1800),
            lastSampleAt: now.addingTimeInterval(-900),
            memoryDeltaBytes: 4 * 1024 * 1024,
            memoryGrowthMBPerHour: 16.0,
            topCPUSamples: [
                ResourceUsageMonitor.Sample(
                    timestamp: now.addingTimeInterval(-900),
                    cpuPercent: 24.0,
                    memoryBytes: 132 * 1024 * 1024
                )
            ],
            topMemorySamples: [
                ResourceUsageMonitor.Sample(
                    timestamp: now.addingTimeInterval(-900),
                    cpuPercent: 24.0,
                    memoryBytes: 132 * 1024 * 1024
                )
            ]
        )

        let report = LogExporter.buildReport(
            snapshot(resourceUsage: usage, performance: performance),
            now: now
        )

        XCTAssertTrue(report.contains("=== Performance Diagnostics ==="))
        XCTAssertTrue(report.contains("Resource usage: monitoring=true samples=2"))
        XCTAssertTrue(report.contains("cpu current=12.25% avg=8.50% peak=24.00%"))
        XCTAssertTrue(report.contains("memory current=130.00 MB avg=125.00 MB peak=132.00 MB delta=+4.00 MB growth=+16.00 MB/hour"))
        XCTAssertTrue(report.contains("ViewerDropsDashboard: count=1 ok=1 fail=0 avg=1.25s p95=1.25s max=1.25s retries=1 rateLimitWait=200ms"))
        XCTAssertTrue(report.contains("[Gabe] cycles=1 avg=2.00s p95=2.00s max=2.00s"))
        XCTAssertTrue(report.contains("outcome=watching total=2.00s campaigns=800ms claims=100ms channels=900ms watchStart=200ms candidates=3"))

        await PerformanceDiagnostics.shared.reset()
    }

    func testDefaultFilenameUsesUTCTimestamp() {
        let date = Date(timeIntervalSince1970: 1_730_000_000)
        let name = LogExporter.defaultFilename(for: date)
        XCTAssertTrue(name.hasPrefix("SwiftMiner-logs-"))
        XCTAssertTrue(name.hasSuffix(".txt"))
    }

    // MARK: - Earning ledger

    private func bucket(
        _ minerID: String,
        hourOffset: Int,
        watching: TimeInterval,
        earned: Int = 0,
        claims: Int = 0
    ) -> EarningLedgerBucket {
        EarningLedgerBucket(
            minerID: minerID,
            hourStart: Date(timeIntervalSince1970: 1_699_999_200 + Double(hourOffset) * 3600),
            watchingSeconds: watching,
            earnedMinutes: earned,
            claimedDrops: claims
        )
    }

    func testReportRendersEmptyEarningLedger() {
        let report = LogExporter.buildReport(snapshot())
        XCTAssertTrue(report.contains("=== Earning Ledger ==="))
        XCTAssertTrue(report.contains("(no earning history recorded)"))
    }

    func testReportRendersEarningRateAndNonEarningHours() {
        let good = bucket("gabe", hourOffset: 0, watching: 3600, earned: 58, claims: 1)
        let bad = bucket("gabe", hourOffset: 1, watching: 3600)
        let snap = snapshot(
            earningSummaries: [EarningLedgerSummary.make(minerID: "gabe", buckets: [good, bad])],
            nonEarningHours: [bad],
            earningBuckets: [good, bad],
            minerNames: ["gabe": "Gabe"]
        )

        let report = LogExporter.buildReport(snap)
        XCTAssertTrue(report.contains("[Gabe] watched=2h0m earned=58min claims=1 rate=29.0min/h"))
        XCTAssertTrue(report.contains("coveredHours=2 nonEarningHours=1"))
        XCTAssertTrue(report.contains("Non-earning hours (newest first, 1):"))
        XCTAssertTrue(report.contains("Hourly detail (oldest \u{2192} newest, 2):"))
    }

    func testReportRedactsMinerNamesInLedgerRows() {
        let bad = bucket("gabe", hourOffset: 0, watching: 3600)
        let snap = snapshot(
            earningSummaries: [EarningLedgerSummary.make(minerID: "gabe", buckets: [bad])],
            nonEarningHours: [bad],
            minerNames: ["gabe": "user@example.com"]
        )

        let report = LogExporter.buildReport(snap)
        XCTAssertFalse(report.contains("user@example.com"))
        XCTAssertTrue(report.contains("<email>"))
    }

    func testReportIncludesNotEarningFlagAndProgressTimestamp() {
        let now = Date(timeIntervalSince1970: 1_730_000_500)
        let miner = LogExporter.Snapshot.Miner(
            id: "gabe",
            username: "gabe",
            nickname: "Gabe",
            status: "watching",
            needsAuth: false,
            isRunning: true,
            dropsClaimed: 3,
            currentCampaign: nil,
            currentCampaignId: nil,
            priorityGames: [],
            statusChangedAt: now.addingTimeInterval(-7200),
            showsNotEarningAttention: true,
            lastDropProgressAt: now.addingTimeInterval(-3600)
        )

        let report = LogExporter.buildReport(snapshot(miners: [miner]), now: now)
        XCTAssertTrue(report.contains("showsNotEarningAttention=true"))
        XCTAssertTrue(report.contains("lastDropProgressAt="))
    }
}
