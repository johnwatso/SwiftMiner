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
    struct Snapshot {
        struct Miner {
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
            let lastEventAt: Date?
            let lastSuccessfulPollAt: Date?
            let lastCampaignRefreshAt: Date?
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
                lastEventAt: Date? = nil,
                lastSuccessfulPollAt: Date? = nil,
                lastCampaignRefreshAt: Date? = nil,
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
                self.lastEventAt = lastEventAt
                self.lastSuccessfulPollAt = lastSuccessfulPollAt
                self.lastCampaignRefreshAt = lastCampaignRefreshAt
                self.stallConfidencePercent = stallConfidencePercent
                self.stallSignals = stallSignals
            }
        }

        struct Event {
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
                    miner.showsNoRecentActivityAttention.map { "showsNoRecentActivityAttention=\($0)" }
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
                    formatTimestampField("lastCampaignRefreshAt", miner.lastCampaignRefreshAt, reference: reference, formatter: iso)
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

        var out = "Runtime metrics: generated=\(formatter.string(from: performance.generatedAt))\n"
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
                lastEventAt: healthSnapshot.lastEventAt,
                lastSuccessfulPollAt: healthSnapshot.lastSuccessfulPollAt,
                lastCampaignRefreshAt: healthSnapshot.lastCampaignRefreshAt,
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
            events: events
        )
    }

    @MainActor
    static func presentSavePanel(navigation: NavigationModel) async {
        let snapshot = await makeSnapshot(navigation: navigation)
        let report = buildReport(snapshot)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = defaultFilename(for: snapshot.generatedAt)
        panel.title = "Export Diagnostic Logs"
        panel.message = "Save a redacted diagnostic report you can attach to a GitHub issue."
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

        guard panel.runModal() == .OK, let url = panel.url else { return }

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

    static func defaultFilename(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "SwiftMiner-logs-\(formatter.string(from: date)).txt"
    }
}
