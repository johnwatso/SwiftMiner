import Foundation

/// Persists hourly earning accounting so a slow failure can be read back after the fact.
///
/// Writes are throttled: watch time accumulates on every supervisor snapshot, which arrives
/// every few seconds per running miner, and persisting each one would be a disk-write storm
/// for numbers nobody reads until something goes wrong. State is flushed on an interval, on
/// every hour rollover, and on demand via `flush()`.
public actor EarningLedgerStore {
    private struct PersistedState: Codable {
        static let currentSchemaVersion = 1

        var schemaVersion = currentSchemaVersion
        var buckets: [String: EarningLedgerBucket] = [:]
    }

    private let fileURL: URL
    private let retention: TimeInterval
    private let persistInterval: TimeInterval
    private var state: PersistedState
    private var lastPersistAt: Date?
    private var isDirty = false

    public init(
        fileURL: URL,
        retentionDays: Int = 7,
        persistInterval: TimeInterval = 60
    ) {
        self.fileURL = fileURL
        self.retention = TimeInterval(max(1, retentionDays)) * 24 * 60 * 60
        self.persistInterval = max(0, persistInterval)
        self.state = Self.loadState(from: fileURL)
    }

    public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("SwiftMiner", isDirectory: true)
            .appendingPathComponent("earning-ledger.json")
    }

    // MARK: - Recording

    /// Credits observed watching time to the hour it fell in.
    public func recordWatching(minerID: String, seconds: TimeInterval, at date: Date = Date()) {
        guard seconds > 0 else { return }
        mutateBucket(minerID: minerID, at: date) { $0.watchingSeconds += seconds }
    }

    /// Credits drop minutes and claims that Twitch confirmed during the hour.
    public func recordEarned(
        minerID: String,
        minutes: Int = 0,
        claims: Int = 0,
        at date: Date = Date()
    ) {
        guard minutes > 0 || claims > 0 else { return }
        mutateBucket(minerID: minerID, at: date) {
            $0.earnedMinutes += max(0, minutes)
            $0.claimedDrops += max(0, claims)
        }
    }

    // MARK: - Reading

    public func buckets(for minerID: String, since date: Date? = nil) -> [EarningLedgerBucket] {
        state.buckets.values
            .filter { $0.minerID == minerID && (date == nil || $0.hourStart >= date!) }
            .sorted { $0.hourStart < $1.hourStart }
    }

    public func allBuckets(since date: Date? = nil) -> [EarningLedgerBucket] {
        state.buckets.values
            .filter { date == nil || $0.hourStart >= date! }
            .sorted {
                $0.hourStart == $1.hourStart ? $0.minerID < $1.minerID : $0.hourStart < $1.hourStart
            }
    }

    public func summaries(since date: Date? = nil) -> [EarningLedgerSummary] {
        Dictionary(grouping: allBuckets(since: date), by: \.minerID)
            .map { EarningLedgerSummary.make(minerID: $0.key, buckets: $0.value) }
            .sorted { $0.minerID < $1.minerID }
    }

    public func summary(for minerID: String, since date: Date? = nil) -> EarningLedgerSummary {
        EarningLedgerSummary.make(minerID: minerID, buckets: buckets(for: minerID, since: date))
    }

    /// Hours where a miner watched meaningfully and banked nothing, newest first.
    public func nonEarningHours(since date: Date? = nil) -> [EarningLedgerBucket] {
        allBuckets(since: date)
            .filter { $0.isNonEarning() }
            .sorted { $0.hourStart > $1.hourStart }
    }

    // MARK: - Lifecycle

    /// Writes any pending changes immediately. Call before reading the ledger for export
    /// and when the app is going away.
    public func flush() throws {
        guard isDirty else { return }
        try persist()
    }

    public func reset() throws {
        state = PersistedState()
        isDirty = true
        try persist()
    }

    // MARK: - Internals

    private func mutateBucket(
        minerID: String,
        at date: Date,
        _ body: (inout EarningLedgerBucket) -> Void
    ) {
        let hourStart = EarningLedgerBucket.hourStart(for: date)
        let key = EarningLedgerBucket.id(minerID: minerID, hourStart: hourStart)
        var bucket = state.buckets[key] ?? EarningLedgerBucket(minerID: minerID, hourStart: hourStart)
        body(&bucket)
        state.buckets[key] = bucket
        isDirty = true

        persistIfNeeded(at: date, rolledOverInto: hourStart)
    }

    /// Persist when the interval has elapsed, or as soon as writes land in a new hour so a
    /// completed hour is never lost to a crash.
    private func persistIfNeeded(at date: Date, rolledOverInto hourStart: Date) {
        guard let lastPersistAt else {
            try? persist(at: date)
            return
        }

        let intervalElapsed = date.timeIntervalSince(lastPersistAt) >= persistInterval
        let rolledOver = EarningLedgerBucket.hourStart(for: lastPersistAt) != hourStart
        guard intervalElapsed || rolledOver else { return }
        try? persist(at: date)
    }

    private func persist(at date: Date = Date()) throws {
        // Pruning here rather than on every write keeps the hot path O(1); between flushes
        // the ledger holds at most a few extra hours of buckets.
        state.buckets = state.buckets.filter {
            $0.value.hourStart >= date.addingTimeInterval(-retention)
        }

        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: fileURL, options: .atomic)
        lastPersistAt = date
        isDirty = false
    }

    private static func loadState(from fileURL: URL) -> PersistedState {
        guard let data = try? Data(contentsOf: fileURL) else {
            return PersistedState()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(PersistedState.self, from: data),
              decoded.schemaVersion == PersistedState.currentSchemaVersion else {
            return PersistedState()
        }
        return decoded
    }
}
