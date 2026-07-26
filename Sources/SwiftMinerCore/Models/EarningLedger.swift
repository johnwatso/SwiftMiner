import Foundation

/// One hour of earning accounting for a single miner.
///
/// The health surface answers "is this miner earning right now?"; the ledger answers
/// "what did it earn, and when did it stop?" — the question you actually need after an
/// overnight session goes wrong, and the one a single overwritten timestamp cannot answer.
public struct EarningLedgerBucket: Codable, Sendable, Equatable, Identifiable {
    /// Wall-clock length of a bucket.
    public static let interval: TimeInterval = 60 * 60

    public let accountID: String
    /// Start of the hour this bucket covers.
    public let hourStart: Date
    /// Seconds this miner was observed in `.watching` during the hour.
    public var watchingSeconds: TimeInterval
    /// Drop minutes Twitch actually credited during the hour.
    public var earnedMinutes: Int
    /// Drops claimed during the hour.
    public var claimedDrops: Int

    public var id: String { Self.id(accountID: accountID, hourStart: hourStart) }

    public init(
        accountID: String,
        hourStart: Date,
        watchingSeconds: TimeInterval = 0,
        earnedMinutes: Int = 0,
        claimedDrops: Int = 0
    ) {
        self.accountID = accountID
        self.hourStart = hourStart
        self.watchingSeconds = watchingSeconds
        self.earnedMinutes = earnedMinutes
        self.claimedDrops = claimedDrops
    }

    public static func id(accountID: String, hourStart: Date) -> String {
        "\(accountID)|\(Int(hourStart.timeIntervalSince1970))"
    }

    /// The start of the bucket a timestamp belongs to.
    public static func hourStart(for date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / interval).rounded(.down) * interval)
    }

    /// A meaningful stretch of watching that banked nothing — the shape of a miner that
    /// looks healthy and earns nothing. Short slivers either side of an hour boundary are
    /// not evidence of anything, so they do not count.
    public func isNonEarning(minimumWatchingSeconds: TimeInterval = 20 * 60) -> Bool {
        watchingSeconds >= minimumWatchingSeconds && earnedMinutes == 0
    }
}

/// Totals across a span of buckets for one miner.
public struct EarningLedgerSummary: Sendable, Equatable, Identifiable {
    public let accountID: String
    public let watchingSeconds: TimeInterval
    public let earnedMinutes: Int
    public let claimedDrops: Int
    /// Hours in which the miner watched meaningfully and banked nothing.
    public let nonEarningHours: Int
    /// Hours with any recorded activity at all.
    public let coveredHours: Int
    public let firstHourStart: Date?
    public let lastHourStart: Date?

    public var id: String { accountID }

    public init(
        accountID: String,
        watchingSeconds: TimeInterval,
        earnedMinutes: Int,
        claimedDrops: Int,
        nonEarningHours: Int,
        coveredHours: Int,
        firstHourStart: Date?,
        lastHourStart: Date?
    ) {
        self.accountID = accountID
        self.watchingSeconds = watchingSeconds
        self.earnedMinutes = earnedMinutes
        self.claimedDrops = claimedDrops
        self.nonEarningHours = nonEarningHours
        self.coveredHours = coveredHours
        self.firstHourStart = firstHourStart
        self.lastHourStart = lastHourStart
    }

    /// The headline number: credited drop minutes per hour actually spent watching.
    /// A healthy miner sits near 60; anything near zero is the failure this exists to catch.
    public var earnedMinutesPerWatchedHour: Double {
        guard watchingSeconds > 0 else { return 0 }
        return Double(earnedMinutes) / (watchingSeconds / 3600)
    }

    public static func make(accountID: String, buckets: [EarningLedgerBucket]) -> EarningLedgerSummary {
        EarningLedgerSummary(
            accountID: accountID,
            watchingSeconds: buckets.reduce(0) { $0 + $1.watchingSeconds },
            earnedMinutes: buckets.reduce(0) { $0 + $1.earnedMinutes },
            claimedDrops: buckets.reduce(0) { $0 + $1.claimedDrops },
            nonEarningHours: buckets.filter { $0.isNonEarning() }.count,
            coveredHours: buckets.count,
            firstHourStart: buckets.map(\.hourStart).min(),
            lastHourStart: buckets.map(\.hourStart).max()
        )
    }
}
