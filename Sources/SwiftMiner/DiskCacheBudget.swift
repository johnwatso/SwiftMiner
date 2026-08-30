import Foundation
import SwiftMinerCore

/// Enforces a bounded footprint for flat, rebuildable cache directories.
///
/// Files are evicted by modification date, oldest first. Cache reads deliberately
/// do not touch metadata, avoiding a disk write just to maintain exact LRU order.
enum DiskCacheBudget {
    struct Result: Equatable {
        let filesBefore: Int
        let bytesBefore: Int64
        let filesAfter: Int
        let bytesAfter: Int64

        var removedFiles: Int { filesBefore - filesAfter }
        var removedBytes: Int64 { bytesBefore - bytesAfter }
    }

    private struct Entry {
        let url: URL
        let size: Int64
        let modifiedAt: Date
    }

    static func prune(
        directory: URL,
        maximumBytes: Int64,
        maximumFileCount: Int,
        fileManager: FileManager = .default
    ) -> Result {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []

        var entries = urls.compactMap { url -> Entry? in
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            return Entry(
                url: url,
                size: Int64(max(0, values.fileSize ?? 0)),
                modifiedAt: values.contentModificationDate ?? .distantPast
            )
        }
        entries.sort {
            if $0.modifiedAt == $1.modifiedAt {
                return $0.url.lastPathComponent < $1.url.lastPathComponent
            }
            return $0.modifiedAt < $1.modifiedAt
        }

        let filesBefore = entries.count
        let bytesBefore = entries.reduce(Int64(0)) { $0 + $1.size }
        var filesAfter = filesBefore
        var bytesAfter = bytesBefore
        let byteLimit = max(0, maximumBytes)
        let fileLimit = max(0, maximumFileCount)

        for entry in entries where filesAfter > fileLimit || bytesAfter > byteLimit {
            do {
                try fileManager.removeItem(at: entry.url)
                filesAfter -= 1
                bytesAfter = max(0, bytesAfter - entry.size)
            } catch {
                Logger.artwork.warning("Could not prune cached image \(entry.url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        return Result(
            filesBefore: filesBefore,
            bytesBefore: bytesBefore,
            filesAfter: filesAfter,
            bytesAfter: bytesAfter
        )
    }
}
