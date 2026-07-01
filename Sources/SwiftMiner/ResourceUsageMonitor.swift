import Foundation
import Darwin

/// Cheap, self-contained sampler for this process's own CPU time and memory
/// footprint using Mach `task_info`. Each call is a couple of syscalls and
/// allocates nothing, so sampling on a slow interval has no meaningful cost.
enum ProcessResourceSampler {
    /// Resident memory footprint in bytes — the value Activity Monitor shows as
    /// "Memory" (`phys_footprint`), which is more representative than raw resident size.
    static func memoryFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }

    /// Cumulative CPU time (user + system) the whole process has consumed, in
    /// seconds. Combines terminated-thread time (`MACH_TASK_BASIC_INFO`) with
    /// live-thread time (`TASK_THREAD_TIMES_INFO`). Differencing two readings
    /// over wall-clock time yields the CPU% used during the interval.
    static func cumulativeCPUSeconds() -> Double? {
        func seconds(_ time: time_value_t) -> Double {
            Double(time.seconds) + Double(time.microseconds) / 1_000_000
        }

        var basic = mach_task_basic_info()
        var basicCount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let basicResult = withUnsafeMutablePointer(to: &basic) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) { intPointer in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPointer, &basicCount)
            }
        }
        guard basicResult == KERN_SUCCESS else { return nil }

        var times = task_thread_times_info()
        var timesCount = mach_msg_type_number_t(MemoryLayout<task_thread_times_info>.size / MemoryLayout<natural_t>.size)
        let timesResult = withUnsafeMutablePointer(to: &times) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(timesCount)) { intPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), intPointer, &timesCount)
            }
        }
        guard timesResult == KERN_SUCCESS else { return nil }

        return seconds(basic.user_time) + seconds(basic.system_time)
            + seconds(times.user_time) + seconds(times.system_time)
    }
}

/// Opt-in diagnostic that accumulates this app's average/peak CPU and memory
/// usage while enabled, for surfacing in a small Advanced popup. It does nothing
/// (and starts no timer) unless `start()` is called, so it adds zero cost to the
/// normal app. CPU% is expressed relative to a single core, matching Activity
/// Monitor (it can exceed 100% when multiple threads are busy).
@MainActor
@Observable
final class ResourceUsageMonitor {
    struct Snapshot: Equatable {
        var currentCPUPercent: Double = 0
        var averageCPUPercent: Double = 0
        var peakCPUPercent: Double = 0
        var currentMemoryBytes: UInt64 = 0
        var averageMemoryBytes: UInt64 = 0
        var peakMemoryBytes: UInt64 = 0
        var sampleCount: Int = 0
        var startedAt: Date?
    }

    /// One recorded reading, retained so the accumulated series can be exported.
    struct Sample: Equatable {
        let timestamp: Date
        let cpuPercent: Double
        let memoryBytes: UInt64
    }

    struct Diagnostics: Equatable {
        let isRunning: Bool
        let startedAt: Date?
        let durationSeconds: TimeInterval?
        let sampleCount: Int
        let currentCPUPercent: Double
        let averageCPUPercent: Double
        let peakCPUPercent: Double
        let currentMemoryBytes: UInt64
        let averageMemoryBytes: UInt64
        let peakMemoryBytes: UInt64
        let firstSampleAt: Date?
        let lastSampleAt: Date?
        let memoryDeltaBytes: Int64?
        let memoryGrowthMBPerHour: Double?
        let topCPUSamples: [Sample]
        let topMemorySamples: [Sample]
    }

    /// Latest accumulated snapshot. Observed by the diagnostics popup.
    private(set) var snapshot = Snapshot()

    var isRunning: Bool { task != nil }

    /// Sample every 15s: frequent enough for a stable average, infrequent enough
    /// that the cost is immeasurable.
    private let intervalNanoseconds: UInt64 = 15 * 1_000_000_000

    /// Retained readings for CSV export. Capped so a long-running session stays
    /// bounded (5760 × 15s ≈ 24h); oldest samples drop off first.
    private var history: [Sample] = []
    private let maxHistory = 5760

    private var task: Task<Void, Never>?
    private var cpuSum: Double = 0
    private var memorySum: Double = 0
    private var lastCPUSeconds: Double?
    private var lastSampleAt: Date?

    func start() {
        guard task == nil else { return }
        resetAccumulators(started: true)
        task = Task { [weak self] in
            guard let interval = self?.intervalNanoseconds else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                if Task.isCancelled { break }
                self?.sample()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Discards accumulated averages/peaks and restarts the window from now.
    func reset() {
        resetAccumulators(started: isRunning)
    }

    private func resetAccumulators(started: Bool) {
        cpuSum = 0
        memorySum = 0
        history.removeAll(keepingCapacity: true)
        lastCPUSeconds = ProcessResourceSampler.cumulativeCPUSeconds()
        lastSampleAt = Date()
        snapshot = Snapshot(startedAt: started ? Date() : nil)
    }

    /// CSV of the retained readings for export: one row per sample, plus a summary
    /// header block. CPU% is relative to a single core; memory is `phys_footprint`.
    func csvRepresentation() -> String {
        let formatter = ISO8601DateFormatter()
        func mb(_ bytes: UInt64) -> Double { Double(bytes) / (1024 * 1024) }

        var lines: [String] = []
        lines.append("# SwiftMiner resource usage")
        lines.append("# exported: \(formatter.string(from: Date()))")
        if let startedAt = snapshot.startedAt {
            lines.append("# started: \(formatter.string(from: startedAt))")
        }
        lines.append("# samples: \(snapshot.sampleCount)")
        lines.append(String(format: "# cpu_percent avg: %.2f, peak: %.2f (relative to one core)",
                            snapshot.averageCPUPercent, snapshot.peakCPUPercent))
        lines.append(String(format: "# memory_mb avg: %.2f, peak: %.2f",
                            mb(snapshot.averageMemoryBytes), mb(snapshot.peakMemoryBytes)))
        lines.append("timestamp,cpu_percent,memory_mb")
        for sample in history {
            lines.append(String(format: "%@,%.2f,%.2f",
                                formatter.string(from: sample.timestamp),
                                sample.cpuPercent,
                                mb(sample.memoryBytes)))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func diagnostics(now: Date = Date()) -> Diagnostics {
        let first = history.first
        let last = history.last
        let duration = snapshot.startedAt.map { max(0, now.timeIntervalSince($0)) }
        let memoryDelta = Self.memoryDelta(first: first, last: last)
        let memoryGrowth = Self.memoryGrowthMBPerHour(deltaBytes: memoryDelta, first: first, last: last)
        let topCPU = Array(history.sorted {
            if $0.cpuPercent == $1.cpuPercent {
                return $0.timestamp > $1.timestamp
            }
            return $0.cpuPercent > $1.cpuPercent
        }.prefix(5))
        let topMemory = Array(history.sorted {
            if $0.memoryBytes == $1.memoryBytes {
                return $0.timestamp > $1.timestamp
            }
            return $0.memoryBytes > $1.memoryBytes
        }.prefix(5))

        return Diagnostics(
            isRunning: isRunning,
            startedAt: snapshot.startedAt,
            durationSeconds: duration,
            sampleCount: snapshot.sampleCount,
            currentCPUPercent: snapshot.currentCPUPercent,
            averageCPUPercent: snapshot.averageCPUPercent,
            peakCPUPercent: snapshot.peakCPUPercent,
            currentMemoryBytes: snapshot.currentMemoryBytes,
            averageMemoryBytes: snapshot.averageMemoryBytes,
            peakMemoryBytes: snapshot.peakMemoryBytes,
            firstSampleAt: first?.timestamp,
            lastSampleAt: last?.timestamp,
            memoryDeltaBytes: memoryDelta,
            memoryGrowthMBPerHour: memoryGrowth,
            topCPUSamples: topCPU,
            topMemorySamples: topMemory
        )
    }

    private func sample() {
        let now = Date()

        var cpuPercent = snapshot.currentCPUPercent
        if let previousSeconds = lastCPUSeconds,
           let previousAt = lastSampleAt,
           let currentSeconds = ProcessResourceSampler.cumulativeCPUSeconds() {
            let wallElapsed = now.timeIntervalSince(previousAt)
            if wallElapsed > 0 {
                cpuPercent = max(0, (currentSeconds - previousSeconds) / wallElapsed * 100)
            }
            lastCPUSeconds = currentSeconds
        }
        lastSampleAt = now

        let memory = ProcessResourceSampler.memoryFootprintBytes() ?? snapshot.currentMemoryBytes

        var updated = snapshot
        updated.sampleCount += 1
        updated.currentCPUPercent = cpuPercent
        updated.currentMemoryBytes = memory
        cpuSum += cpuPercent
        memorySum += Double(memory)
        updated.averageCPUPercent = cpuSum / Double(updated.sampleCount)
        updated.averageMemoryBytes = UInt64(memorySum / Double(updated.sampleCount))
        updated.peakCPUPercent = max(updated.peakCPUPercent, cpuPercent)
        updated.peakMemoryBytes = max(updated.peakMemoryBytes, memory)
        snapshot = updated

        history.append(Sample(timestamp: now, cpuPercent: cpuPercent, memoryBytes: memory))
        if history.count > maxHistory {
            history.removeFirst(history.count - maxHistory)
        }
    }

    private static func memoryDelta(first: Sample?, last: Sample?) -> Int64? {
        guard let first, let last else { return nil }
        return Int64(last.memoryBytes) - Int64(first.memoryBytes)
    }

    private static func memoryGrowthMBPerHour(deltaBytes: Int64?, first: Sample?, last: Sample?) -> Double? {
        guard let deltaBytes, let first, let last else { return nil }
        let elapsed = last.timestamp.timeIntervalSince(first.timestamp)
        guard elapsed > 0 else { return nil }
        let deltaMB = Double(deltaBytes) / (1024 * 1024)
        return deltaMB / elapsed * 3_600
    }
}
