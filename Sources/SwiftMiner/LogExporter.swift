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
        /// Events in chronological order (oldest first).
        let events: [Event]
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

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return "\(s)s" }
        if s < 3_600 { return "\(s / 60)m\(s % 60)s" }
        let h = s / 3_600
        let m = (s % 3_600) / 60
        return "\(h)h\(m)m"
    }

    // MARK: - App-side capture + save

    @MainActor
    static func makeSnapshot(navigation: NavigationModel) -> Snapshot {
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
            Snapshot.Miner(
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
                statusChangedAt: m.statusChangedAt
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
            events: events
        )
    }

    @MainActor
    static func presentSavePanel(navigation: NavigationModel) {
        let snapshot = makeSnapshot(navigation: navigation)
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
