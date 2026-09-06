import AppKit
import Foundation
import SwiftMinerCore
import UniformTypeIdentifiers

/// Builds a single plain-text diagnostic report covering app version,
/// per-miner state, settings, and the in-memory event log. Designed to be
/// attached to a GitHub issue when reporting a problem.
enum LogExporter {

    /// Snapshot inputs are kept primitive so `buildReport` can be unit-tested
    /// without standing up SwiftUI / NavigationModel.
    struct Snapshot: Sendable {
        struct Miner: Sendable {
            let id: String
            let username: String
            let nickname: String?
            let status: String
            let needsAuth: Bool
            let isRunning: Bool
            let dropsClaimed: Int
            let currentCampaign: String?
            let currentCampaignId: String?
            let priorityGames: [String]
            let statusChangedAt: Date
            let statusLabel: String?
            let health: String?
            let workerState: String?
            let workerTaskID: String?
            let isHealthy: Bool?
            let isStalled: Bool?
            let showsNoRecentActivityAttention: Bool?
            let showsNotEarningAttention: Bool?
            let lastEventAt: Date?
            let lastSuccessfulPollAt: Date?
            let lastCampaignRefreshAt: Date?
            let lastDropProgressAt: Date?
            let stallConfidencePercent: Int?
            let stallSignals: [String]

            init(
                id: String,
                username: String,
                nickname: String?,
                status: String,
                needsAuth: Bool,
                isRunning: Bool,
                dropsClaimed: Int,
                currentCampaign: String?,
                currentCampaignId: String?,
                priorityGames: [String],
                statusChangedAt: Date,
                statusLabel: String? = nil,
                health: String? = nil,
                workerState: String? = nil,
                workerTaskID: String? = nil,
                isHealthy: Bool? = nil,
                isStalled: Bool? = nil,
                showsNoRecentActivityAttention: Bool? = nil,
                showsNotEarningAttention: Bool? = nil,
                lastEventAt: Date? = nil,
                lastSuccessfulPollAt: Date? = nil,
                lastCampaignRefreshAt: Date? = nil,
                lastDropProgressAt: Date? = nil,
                stallConfidencePercent: Int? = nil,
                stallSignals: [String] = []
            ) {
                self.id = id
                self.username = username
                self.nickname = nickname
                self.status = status
                self.needsAuth = needsAuth
                self.isRunning = isRunning
                self.dropsClaimed = dropsClaimed
                self.currentCampaign = currentCampaign
                self.currentCampaignId = currentCampaignId
                self.priorityGames = priorityGames
                self.statusChangedAt = statusChangedAt
                self.statusLabel = statusLabel
                self.health = health
                self.workerState = workerState
                self.workerTaskID = workerTaskID
                self.isHealthy = isHealthy
                self.isStalled = isStalled
                self.showsNoRecentActivityAttention = showsNoRecentActivityAttention
                self.showsNotEarningAttention = showsNotEarningAttention
                self.lastEventAt = lastEventAt
                self.lastSuccessfulPollAt = lastSuccessfulPollAt
                self.lastCampaignRefreshAt = lastCampaignRefreshAt
                self.lastDropProgressAt = lastDropProgressAt
                self.stallConfidencePercent = stallConfidencePercent
                self.stallSignals = stallSignals
            }
        }

        struct Event: Sendable {
            let timestamp: Date
            let level: String
            let minerId: String?
            let message: String
        }

        let generatedAt: Date
        let appVersion: String
        let appBuild: String
        let osVersion: String
        let arch: String
        let miners: [Miner]
        let settings: [(String, String)]
        let resourceUsage: ResourceUsageMonitor.Diagnostics?
        let performance: PerformanceDiagnostics.Snapshot?
        /// Per-account earning totals over the ledger's retention window.
        let earningSummaries: [EarningLedgerSummary]
        /// Hours where a miner watched meaningfully and banked nothing, newest first.
        let nonEarningHours: [EarningLedgerBucket]
        /// Recent hourly buckets, oldest first, so the report shows the shape over time.
        let earningBuckets: [EarningLedgerBucket]
        /// Miner display names keyed by account ID, for labelling ledger rows.
        let accountNames: [String: String]
        /// Events in chronological order (oldest first).
        let events: [Event]

        init(
            generatedAt: Date,
            appVersion: String,
            appBuild: String,
            osVersion: String,
            arch: String,
            miners: [Miner],
            settings: [(String, String)],
            resourceUsage: ResourceUsageMonitor.Diagnostics? = nil,
            performance: PerformanceDiagnostics.Snapshot? = nil,
            earningSummaries: [EarningLedgerSummary] = [],
            nonEarningHours: [EarningLedgerBucket] = [],
            earningBuckets: [EarningLedgerBucket] = [],
            accountNames: [String: String] = [:],
            events: [Event]
        ) {
            self.generatedAt = generatedAt
            self.appVersion = appVersion
            self.appBuild = appBuild
            self.osVersion = osVersion
            self.arch = arch
            self.miners = miners
            self.settings = settings
            self.resourceUsage = resourceUsage
            self.performance = performance
            self.earningSummaries = earningSummaries
            self.nonEarningHours = nonEarningHours
            self.earningBuckets = earningBuckets
            self.accountNames = accountNames
            self.events = events
        }
    }

    // MARK: - Building

    static func buildReport(_ snapshot: Snapshot, now: Date? = nil) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let reference = now ?? snapshot.generatedAt

        var out = ""
        out += "=== SwiftMiner Diagnostic Report ===\n"
        out += "Generated: \(iso.string(from: snapshot.generatedAt))\n"
        out += "App: \(snapshot.appVersion) (build \(snapshot.appBuild))\n"
        out += "Engine: \(MinerEngineVersion.current) (updated \(MinerEngineVersion.updated))\n"
        out += "OS: \(snapshot.osVersion) · arch \(snapshot.arch)\n"
        out += "\n"

        out += "=== Miners (\(snapshot.miners.count)) ===\n"
        if snapshot.miners.isEmpty {
            out += "(none)\n"
        } else {
            for miner in snapshot.miners {
                let label = miner.nickname.flatMap { $0.isEmpty ? nil : $0 } ?? miner.username
                let stuckFor = formatDuration(reference.timeIntervalSince(miner.statusChangedAt))
                out += "[\(LogRedactor.redact(label))] status=\(miner.status) running=\(miner.isRunning) needsAuth=\(miner.needsAuth)\n"
                out += "  drops=\(miner.dropsClaimed) inStatusFor=\(stuckFor)\n"
                if let statusLabel = miner.statusLabel {
                    out += "  statusLabel=\"\(LogRedactor.redact(statusLabel))\"\n"
                }
                let healthParts = [
                    miner.health.map { "health=\($0)" },
                    miner.workerState.map { "workerState=\($0)" },
                    miner.isHealthy.map { "isHealthy=\($0)" },
                    miner.isStalled.map { "isStalled=\($0)" },
                    miner.showsNoRecentActivityAttention.map { "showsNoRecentActivityAttention=\($0)" },
                    miner.showsNotEarningAttention.map { "showsNotEarningAttention=\($0)" }
                ].compactMap { $0 }
                if !healthParts.isEmpty {
                    out += "  \(healthParts.joined(separator: " "))\n"
                }
                if let taskID = miner.workerTaskID, !taskID.isEmpty {
                    out += "  workerTaskID=\(taskID)\n"
                }
                let livenessParts = [
                    formatTimestampField("lastEventAt", miner.lastEventAt, reference: reference, formatter: iso),
                    formatTimestampField("lastSuccessfulPollAt", miner.lastSuccessfulPollAt, reference: reference, formatter: iso),
                    formatTimestampField("lastCampaignRefreshAt", miner.lastCampaignRefreshAt, reference: reference, formatter: iso),
                    formatTimestampField("lastDropProgressAt", miner.lastDropProgressAt, reference: reference, formatter: iso)
                ].compactMap { $0 }
                if !livenessParts.isEmpty {
                    out += "  \(livenessParts.joined(separator: " "))\n"
                }
                if let confidence = miner.stallConfidencePercent {
                    out += "  stallConfidence=\(confidence)%"
                    if !miner.stallSignals.isEmpty {
                        out += " signals=[\(miner.stallSignals.joined(separator: "; "))]"
                    }
                    out += "\n"
                }
                if let campaign = miner.currentCampaign {
                    out += "  campaign=\"\(LogRedactor.redact(campaign))\""
                    if let cid = miner.currentCampaignId {
                        out += " id=\(cid)"
                    }
                    out += "\n"
                }
                if !miner.priorityGames.isEmpty {
                    let joined = miner.priorityGames.joined(separator: ", ")
                    out += "  priorityGames=[\(joined)]\n"
                }
            }
        }
        out += "\n"

        out += "=== Settings ===\n"
        if snapshot.settings.isEmpty {
            out += "(none)\n"
        } else {
            for (key, value) in snapshot.settings {
                out += "\(key)=\(value)\n"
            }
        }
        out += "\n"

        out += "=== Performance Diagnostics ===\n"
        out += renderResourceUsage(snapshot.resourceUsage, formatter: iso, reference: reference)
        out += renderPerformanceMetrics(snapshot.performance, formatter: iso, reference: reference)
        out += "\n"

        out += renderEarningLedger(snapshot, formatter: iso)
        out += "\n"

        out += "=== Events (oldest → newest, \(snapshot.events.count)) ===\n"
        if snapshot.events.isEmpty {
            out += "(none)\n"
        } else {
            for event in snapshot.events {
                let ts = iso.string(from: event.timestamp)
                let miner = event.minerId.map { "  \($0)" } ?? ""
                let level = event.level.uppercased().padding(toLength: 7, withPad: " ", startingAt: 0)
                out += "\(ts)  \(level)\(miner)  \(LogRedactor.redact(event.message))\n"
            }
        }

        return out
    }

    /// Renders the earning ledger: what each miner banked per hour actually spent watching.
    /// A healthy miner sits near 60 min/h; a flat line next to a climbing watch count is the
    /// signature of a miner that looks alive and earns nothing.
    private static func renderEarningLedger(
        _ snapshot: Snapshot,
        formatter: ISO8601DateFormatter
    ) -> String {
        var out = "=== Earning Ledger ===\n"
        guard !snapshot.earningSummaries.isEmpty else {
            return out + "(no earning history recorded)\n"
        }

        func label(_ accountID: String) -> String {
            LogRedactor.redact(snapshot.accountNames[accountID] ?? accountID)
        }

        for summary in snapshot.earningSummaries {
            out += "[\(label(summary.accountID))]"
            out += " watched=\(formatDuration(summary.watchingSeconds))"
            out += " earned=\(summary.earnedMinutes)min"
            out += " claims=\(summary.claimedDrops)"
            out += " rate=\(String(format: "%.1f", summary.earnedMinutesPerWatchedHour))min/h\n"
            out += "  coveredHours=\(summary.coveredHours) nonEarningHours=\(summary.nonEarningHours)"
            if let first = summary.firstHourStart, let last = summary.lastHourStart {
                out += " window=\(formatter.string(from: first))...\(formatter.string(from: last))"
            }
            out += "\n"
        }

        if !snapshot.nonEarningHours.isEmpty {
            out += "Non-earning hours (newest first, \(snapshot.nonEarningHours.count)):\n"
            for bucket in snapshot.nonEarningHours {
                out += "  \(formatter.string(from: bucket.hourStart))  [\(label(bucket.accountID))]"
                out += " watched=\(formatDuration(bucket.watchingSeconds)) earned=0min\n"
            }
        }

        if !snapshot.earningBuckets.isEmpty {
            out += "Hourly detail (oldest → newest, \(snapshot.earningBuckets.count)):\n"
            for bucket in snapshot.earningBuckets {
                out += "  \(formatter.string(from: bucket.hourStart))  [\(label(bucket.accountID))]"
                out += " watched=\(formatDuration(bucket.watchingSeconds))"
                out += " earned=\(bucket.earnedMinutes)min claims=\(bucket.claimedDrops)\n"
            }
        }

        return out
    }

    private static func renderResourceUsage(
        _ usage: ResourceUsageMonitor.Diagnostics?,
        formatter: ISO8601DateFormatter,
        reference: Date
    ) -> String {
        guard let usage else {
            return "Resource usage: unavailable\n"
        }

        var out = "Resource usage: monitoring=\(usage.isRunning) samples=\(usage.sampleCount)\n"
        if let startedAt = usage.startedAt {
            out += "  startedAt=\(formatter.string(from: startedAt))"
            if let duration = usage.durationSeconds {
                out += " duration=\(formatDuration(duration))"
            }
            out += "\n"
        }
        guard usage.sampleCount > 0 else {
            out += "  cpu=not measured yet\n"
            out += "  memory=not measured yet\n"
            return out
        }
        if let firstSampleAt = usage.firstSampleAt,
           let lastSampleAt = usage.lastSampleAt {
            out += "  sampleWindow=\(formatter.string(from: firstSampleAt))...\(formatter.string(from: lastSampleAt))"
            out += " (age=\(formatDuration(reference.timeIntervalSince(lastSampleAt))))\n"
        }
        out += "  cpu current=\(formatPercent(usage.currentCPUPercent)) avg=\(formatPercent(usage.averageCPUPercent)) peak=\(formatPercent(usage.peakCPUPercent))\n"
        out += "  memory current=\(formatMB(usage.currentMemoryBytes)) avg=\(formatMB(usage.averageMemoryBytes)) peak=\(formatMB(usage.peakMemoryBytes))"
        if let delta = usage.memoryDeltaBytes {
            out += " delta=\(formatSignedMB(delta))"
        }
        if let growth = usage.memoryGrowthMBPerHour {
            out += " growth=\(String(format: "%+.2f", growth)) MB/hour"
        }
        out += "\n"

        if !usage.topCPUSamples.isEmpty {
            out += "  topCPU:\n"
            for sample in usage.topCPUSamples {
                out += "    - \(formatter.string(from: sample.timestamp)) cpu=\(formatPercent(sample.cpuPercent)) memory=\(formatMB(sample.memoryBytes))\n"
            }
        }
        if !usage.topMemorySamples.isEmpty {
            out += "  topMemory:\n"
            for sample in usage.topMemorySamples {
                out += "    - \(formatter.string(from: sample.timestamp)) memory=\(formatMB(sample.memoryBytes)) cpu=\(formatPercent(sample.cpuPercent))\n"
            }
        }
        return out
    }

    private static func renderPerformanceMetrics(
        _ performance: PerformanceDiagnostics.Snapshot?,
        formatter: ISO8601DateFormatter,
        reference: Date
    ) -> String {
        guard let performance else {
            return "Runtime metrics: unavailable\n"
        }

        let collectionDuration = max(0, reference.timeIntervalSince(performance.collectionStartedAt))
        var out = "Runtime metrics: collectedSince=\(formatter.string(from: performance.collectionStartedAt))"
        out += " duration=\(formatDuration(collectionDuration))"
        out += " generated=\(formatter.string(from: performance.generatedAt))\n"
        out += "Workload phases:\n"
        out += renderWorkloadPhase(
            "startup (first \(formatDuration(performance.startupWindowSeconds)))",
            performance.startup
        )
        out += renderWorkloadPhase("steady-state", performance.steadyState)
        if performance.requestOperations.isEmpty {
            out += "Twitch requests: none recorded\n"
        } else {
            let totalRequests = performance.requestOperations.reduce(0) { $0 + $1.requestCount }
            let totalFailures = performance.requestOperations.reduce(0) { $0 + $1.failureCount }
            out += "Twitch requests: operations=\(performance.requestOperations.count) total=\(totalRequests) failures=\(totalFailures)\n"
            for op in performance.requestOperations.prefix(12) {
                out += "  \(op.operation): count=\(op.requestCount) ok=\(op.successCount) fail=\(op.failureCount)"
                out += " avg=\(formatPerfDuration(op.averageLatencySeconds)) p95=\(formatPerfDuration(op.p95LatencySeconds)) max=\(formatPerfDuration(op.maxLatencySeconds))"
                if op.retryCount > 0 {
                    out += " retries=\(op.retryCount)"
                }
                if op.tokenRefreshCount > 0 {
                    out += " tokenRefreshes=\(op.tokenRefreshCount)"
                }
                if op.rateLimitWaitSeconds > 0 {
                    out += " rateLimitWait=\(formatPerfDuration(op.rateLimitWaitSeconds))"
                }
                if let lastAt = op.lastAt {
                    out += " last=\(formatter.string(from: lastAt))"
                }
                if let lastError = op.lastError, !lastError.isEmpty {
                    out += " lastError=\"\(LogRedactor.redact(lastError))\""
                }
                out += "\n"
            }
        }

        if !performance.slowRequests.isEmpty {
            out += "Slow requests:\n"
            for request in performance.slowRequests.prefix(5) {
                out += "  - \(formatter.string(from: request.finishedAt)) \(request.operation) duration=\(formatPerfDuration(request.durationSeconds))"
                out += " success=\(request.succeeded)"
                if request.retryCount > 0 {
                    out += " retries=\(request.retryCount)"
                }
                if let error = request.error, !error.isEmpty {
                    out += " error=\"\(LogRedactor.redact(error))\""
                }
                out += "\n"
            }
        }

        if !performance.transportHosts.isEmpty {
            out += "HTTP transport:\n"
            for host in performance.transportHosts {
                out += "  \(host.host): count=\(host.requestCount) reused=\(host.reusedConnectionCount)"
                out += " taskAvg=\(formatPerfDuration(host.averageTaskSeconds))"
                if let dns = host.averageDNSSeconds {
                    out += " dnsAvg=\(formatPerfDuration(dns))"
                }
                if let connect = host.averageConnectSeconds {
                    out += " connectAvg=\(formatPerfDuration(connect))"
                }
                if let tls = host.averageTLSSeconds {
                    out += " tlsAvg=\(formatPerfDuration(tls))"
                }
                if let response = host.averageResponseSeconds {
                    out += " responseAvg=\(formatPerfDuration(response))"
                }
                if !host.protocols.isEmpty {
                    out += " protocols=\(host.protocols.joined(separator: ","))"
                }
                out += "\n"
            }
        }

        if let outbox = performance.eventOutbox {
            out += "Event outbox: pending=\(outbox.pendingCount) delivering=\(outbox.deliveringCount) retryable=\(outbox.retryableCount) terminal=\(outbox.terminalCount) sent=\(outbox.sentCount)"
            if let oldestAge = outbox.oldestUndeliveredAgeSeconds {
                out += " oldestUndelivered=\(formatDuration(oldestAge))"
            }
            out += " observed=\(formatter.string(from: outbox.observedAt))\n"
            out += "  deliveries: attempts=\(outbox.deliveryAttemptCount) ok=\(outbox.successfulDeliveryCount) retryable=\(outbox.retryableFailureCount) terminal=\(outbox.terminalFailureCount)"
            out += " networkAvg=\(formatPerfDuration(outbox.averageNetworkSeconds)) networkMax=\(formatPerfDuration(outbox.maxNetworkSeconds))"
            out += " endToEndAvg=\(formatPerfDuration(outbox.averageEndToEndSeconds)) endToEndMax=\(formatPerfDuration(outbox.maxEndToEndSeconds))"
            if let lastFailure = outbox.lastFailure {
                out += " lastError=\"\(lastFailure)\""
                if let lastFailureAt = outbox.lastFailureAt {
                    out += " lastErrorAt=\(formatter.string(from: lastFailureAt))"
                }
            }
            out += "\n"
        }

        if performance.miningCycles.isEmpty {
            out += "Mining cycles: none recorded\n"
        } else {
            out += "Mining cycles:\n"
            for summary in performance.miningCycles {
                let label = LogRedactor.redact(summary.minerLabel.isEmpty ? summary.minerId : summary.minerLabel)
                out += "  [\(label)] cycles=\(summary.cycleCount) avg=\(formatPerfDuration(summary.averageSeconds)) p95=\(formatPerfDuration(summary.p95Seconds)) max=\(formatPerfDuration(summary.maxSeconds))\n"
                out += renderMiningCycle(summary.lastCycle, prefix: "    last", formatter: formatter, reference: reference)
                for slow in summary.slowCycles.prefix(3) where slow != summary.lastCycle {
                    out += renderMiningCycle(slow, prefix: "    slow", formatter: formatter, reference: reference)
                }
            }
        }
        return out
    }

    private static func renderWorkloadPhase(
        _ label: String,
        _ phase: PerformanceDiagnostics.WorkloadPhaseSummary
    ) -> String {
        var out = "  \(label): requests=\(phase.requestCount) failures=\(phase.requestFailureCount)"
        if phase.requestCount > 0 {
            out += " avg=\(formatPerfDuration(phase.averageRequestSeconds))"
            out += " max=\(formatPerfDuration(phase.maxRequestSeconds))"
        }
        out += " miningCycles=\(phase.miningCycleCount)"
        if phase.miningCycleCount > 0 {
            out += " cycleAvg=\(formatPerfDuration(phase.averageMiningCycleSeconds))"
            out += " cycleMax=\(formatPerfDuration(phase.maxMiningCycleSeconds))"
        }
        return out + "\n"
    }

    private static func renderMiningCycle(
        _ cycle: PerformanceDiagnostics.MiningCycleTiming,
        prefix: String,
        formatter: ISO8601DateFormatter,
        reference: Date
    ) -> String {
        var out = "\(prefix)=\(formatter.string(from: cycle.finishedAt))"
        out += " age=\(formatDuration(reference.timeIntervalSince(cycle.finishedAt)))"
        out += " outcome=\(cycle.outcome)"
        out += " total=\(formatPerfDuration(cycle.totalSeconds))"
        out += " campaigns=\(formatPerfDuration(cycle.campaignFetchSeconds))"
        out += " claims=\(formatPerfDuration(cycle.claimCheckSeconds))"
        out += " channels=\(formatPerfDuration(cycle.channelSelectionSeconds))"
        out += " watchStart=\(formatPerfDuration(cycle.watchStartupSeconds))"
        out += " candidates=\(cycle.candidateCount)"
        if let campaign = cycle.selectedCampaign, !campaign.isEmpty {
            out += " campaign=\"\(LogRedactor.redact(campaign))\""
        }
        if let channel = cycle.selectedChannel, !channel.isEmpty {
            out += " channel=\"\(LogRedactor.redact(channel))\""
        }
        return out + "\n"
    }

    private static func formatTimestampField(
        _ name: String,
        _ date: Date?,
        reference: Date,
        formatter: ISO8601DateFormatter
    ) -> String? {
        guard let date else { return nil }
        return "\(name)=\(formatter.string(from: date)) (age=\(formatDuration(reference.timeIntervalSince(date))))"
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return "\(s)s" }
        if s < 3_600 { return "\(s / 60)m\(s % 60)s" }
        let h = s / 3_600
        let m = (s % 3_600) / 60
        return "\(h)h\(m)m"
    }

    private static func formatPerfDuration(_ seconds: TimeInterval) -> String {
        let bounded = max(0, seconds)
        if bounded < 1 {
            return "\(Int((bounded * 1_000).rounded()))ms"
        }
        return String(format: "%.2fs", bounded)
    }

    private static func formatPercent(_ value: Double) -> String {
        String(format: "%.2f%%", value)
    }

    private static func formatMB(_ bytes: UInt64) -> String {
        String(format: "%.2f MB", Double(bytes) / (1024 * 1024))
    }

    private static func formatSignedMB(_ bytes: Int64) -> String {
        String(format: "%+.2f MB", Double(bytes) / (1024 * 1024))
    }

    // MARK: - App-side capture + save

    @MainActor
    static func makeSnapshot(navigation: NavigationModel) async -> Snapshot {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"

        let process = ProcessInfo.processInfo
        let os = process.operatingSystemVersionString
        var arch = "unknown"
        var sysinfo = utsname()
        if uname(&sysinfo) == 0 {
            arch = withUnsafePointer(to: &sysinfo.machine) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                    String(cString: $0)
                }
            }
        }

        let miners = navigation.minerManager.miners.map { m in
            let healthSnapshot = MinerHealthSnapshot.make(miner: m)
            return Snapshot.Miner(
                id: m.id,
                username: m.username,
                nickname: m.nickname,
                status: m.status.rawValue,
                needsAuth: m.needsAuth,
                isRunning: m.isRunning,
                dropsClaimed: m.dropsClaimed,
                currentCampaign: m.currentCampaign,
                currentCampaignId: m.currentCampaignId,
                priorityGames: m.priorityGames,
                statusChangedAt: m.statusChangedAt,
                statusLabel: healthSnapshot.statusLabel,
                health: healthSnapshot.health.rawValue,
                workerState: m.workerState.rawValue,
                workerTaskID: m.workerTaskID,
                isHealthy: m.isHealthy,
                isStalled: m.isStalled,
                showsNoRecentActivityAttention: m.showsNoRecentActivityAttention,
                showsNotEarningAttention: m.showsNotEarningAttention,
                lastEventAt: healthSnapshot.lastEventAt,
                lastSuccessfulPollAt: healthSnapshot.lastSuccessfulPollAt,
                lastCampaignRefreshAt: healthSnapshot.lastCampaignRefreshAt,
                lastDropProgressAt: healthSnapshot.lastDropProgressAt,
                stallConfidencePercent: healthSnapshot.stallConfidencePercent,
                stallSignals: healthSnapshot.stallSignals
            )
        }

        let settings = Settings.shared
        let settingsRows: [(String, String)] = [
            ("autoClaimEnabled", String(settings.autoClaimEnabled)),
            ("autoClaimPointsEnabled", String(settings.autoClaimPointsEnabled)),
            ("logLevel", settings.logLevel.rawValue),
            ("appPresenceMode", String(describing: settings.appPresenceMode)),
            ("autoStartOnLaunch", String(settings.autoStartOnLaunch)),
            ("startMinimized", String(settings.startMinimized)),
            ("avoidDuplicateStreams", String(settings.avoidDuplicateStreams)),
            ("antiStallRecoveryEnabled", String(settings.antiStallRecoveryEnabled)),
            ("prioritiseFollowedStreamers", String(settings.prioritiseFollowedStreamers)),
            ("syncMinersState", String(settings.syncMinersState)),
            ("runInBackground", String(settings.runInBackground))
        ]

        // Flush first: watch time accumulates in memory between throttled writes, and a
        // report that omits the last minute of a stall is the report you least want.
        let ledger = navigation.minerManager.earningLedgerStore
        try? await ledger?.flush()
        let earningSummaries = await ledger?.summaries() ?? []
        let nonEarningHours = await ledger?.nonEarningHours() ?? []
        // The last 48 hours of detail keeps an overnight session fully readable without
        // burying the report under a week of rows.
        let bucketWindowStart = Date().addingTimeInterval(-48 * 60 * 60)
        let earningBuckets = await ledger?.allBuckets(since: bucketWindowStart) ?? []
        let accountNames = Dictionary(
            navigation.minerManager.miners.map { ($0.accountId, $0.displayName) },
            uniquingKeysWith: { first, _ in first }
        )

        let events = navigation.events.reversed().map { entry in
            let raw = entry.rawMessage ?? entry.message
            return Snapshot.Event(
                timestamp: entry.timestamp,
                level: entry.level.rawValue,
                minerId: entry.minerId,
                message: raw
            )
        }

        return Snapshot(
            generatedAt: Date(),
            appVersion: version,
            appBuild: build,
            osVersion: os,
            arch: arch,
            miners: miners,
            settings: settingsRows,
            resourceUsage: navigation.resourceUsageMonitor.diagnostics(),
            performance: await PerformanceDiagnostics.shared.snapshot(),
            earningSummaries: earningSummaries,
            nonEarningHours: nonEarningHours,
            earningBuckets: earningBuckets,
            accountNames: accountNames,
            events: events
        )
    }

    @MainActor
    static func presentSavePanel(navigation: NavigationModel) async {
        let progressSheet = presentProgressSheet()
        defer { dismiss(progressSheet) }

        // Let AppKit present the sheet before snapshotting a potentially large activity log.
        // The report itself is built off the main actor below, so the Activity Log symbol
        // remains animated while redaction and string formatting run.
        await Task.yield()
        let snapshot = await makeSnapshot(navigation: navigation)
        let report = await Task.detached(priority: .userInitiated) {
            buildReport(snapshot)
        }.value

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = defaultFilename(for: snapshot.generatedAt)
        panel.title = "Export Diagnostic Logs"
        panel.message = "Save a redacted diagnostic report you can attach to a GitHub issue."
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

        guard await present(panel) == .OK, let url = panel.url else { return }

        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't save diagnostic logs"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    /// A save panel started from a SwiftUI command needs a window-attached sheet
    /// on current macOS releases. `runModal()` can return without presenting in
    /// that context, which made Export Diagnostic Logs appear to do nothing.
    @MainActor
    private static func present(_ panel: NSSavePanel) async -> NSApplication.ModalResponse {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            return panel.runModal()
        }

        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
    }

    private struct ProgressSheet {
        let panel: NSPanel
        let parentWindow: NSWindow?
        let symbolCycler: ActivityLogSymbolCycler
    }

    /// Displays immediately while a potentially large diagnostics export is snapshotted,
    /// redacted, and formatted. This avoids the appearance that the export action was ignored.
    @MainActor
    private static func presentProgressSheet() -> ProgressSheet {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 154),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "Export Diagnostic Logs"
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let content = NSView(frame: panel.contentView?.bounds ?? .zero)

        let symbolCycler = ActivityLogSymbolCycler(frame: NSRect(x: 27, y: 71, width: 30, height: 30))
        content.addSubview(symbolCycler)

        let title = NSTextField(labelWithString: "Preparing diagnostics…")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.frame = NSRect(x: 74, y: 90, width: 272, height: 22)
        content.addSubview(title)

        let detail = NSTextField(wrappingLabelWithString: "Collecting and redacting activity data. This can take a moment for a large log.")
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2
        detail.frame = NSRect(x: 74, y: 42, width: 272, height: 40)
        content.addSubview(detail)

        panel.contentView = content
        symbolCycler.start()

        if let parentWindow = NSApp.keyWindow ?? NSApp.mainWindow {
            parentWindow.beginSheet(panel)
            return ProgressSheet(panel: panel, parentWindow: parentWindow, symbolCycler: symbolCycler)
        }

        panel.center()
        panel.level = .floating
        panel.makeKeyAndOrderFront(nil)
        return ProgressSheet(panel: panel, parentWindow: nil, symbolCycler: symbolCycler)
    }

    @MainActor
    private static func dismiss(_ progressSheet: ProgressSheet) {
        progressSheet.symbolCycler.stop()
        if let parentWindow = progressSheet.parentWindow {
            parentWindow.endSheet(progressSheet.panel)
        } else {
            progressSheet.panel.orderOut(nil)
        }
    }

    static func defaultFilename(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "SwiftMiner-logs-\(formatter.string(from: date)).txt"
    }
}

/// Cycles through the same category symbols used by Activity Log rows while a
/// diagnostics report is prepared, making long exports feel visibly active.
private final class ActivityLogSymbolCycler: NSImageView {
    private let symbols = EventFilter.allCases.map { (symbol: $0.symbol, color: $0.diagnosticSymbolColor) }
    private var symbolIndex = 0
    private var timer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageScaling = .scaleProportionallyUpOrDown
        contentTintColor = .secondaryLabelColor
        setAccessibilityLabel("Preparing diagnostics")
        updateSymbol()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func start() {
        guard timer == nil else { return }

        let timer = Timer(
            timeInterval: 0.65,
            target: self,
            selector: #selector(advanceSymbol),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func advanceSymbol() {
        symbolIndex = (symbolIndex + 1) % symbols.count
        updateSymbol()
    }

    private func updateSymbol() {
        guard !symbols.isEmpty else { return }
        let symbol = symbols[symbolIndex]
        contentTintColor = symbol.color
        image = NSImage(systemSymbolName: symbol.symbol, accessibilityDescription: "Preparing diagnostics")
    }
}

private extension EventFilter {
    /// Matches the category colours used by Activity Log rows in SwiftUI.
    var diagnosticSymbolColor: NSColor {
        switch self {
        case .mining: return .systemBlue
        case .heartbeats: return .systemPink
        case .drops: return .systemGreen
        case .warnings: return .systemOrange
        case .errors: return .systemRed
        case .accountLink: return .systemPurple
        case .scan: return .systemTeal
        case .discord: return .systemIndigo
        case .audit: return .systemBrown
        case .updates: return .systemCyan
        case .system: return .systemGray
        }
    }
}
