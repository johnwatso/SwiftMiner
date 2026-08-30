import AppKit
import CryptoKit
import Foundation
import SwiftUI
import SwiftMinerCore

/// Disk- and memory-backed cache for miner profile pictures, from Discord or Twitch.
///
/// Both services embed the picture's identity in its URL — Discord the avatar hash,
/// Twitch a per-upload path — so the URL changes whenever a user swaps their picture.
/// Hashing the full URL therefore gives a stable, change-aware cache key without any
/// extra invalidation logic. Cached files live in the user's Caches directory so the
/// OS can reclaim the space under pressure.
actor AvatarImageCache {
    static let shared = AvatarImageCache()

    private static let defaultDiskByteLimit: Int64 = 64 * 1_024 * 1_024
    private static let defaultDiskFileLimit = 256
    private static let defaultBudgetCheckWriteInterval = 25

    private let urlSession: URLSession
    private let diskByteLimit: Int64
    private let diskFileLimit: Int
    private let budgetCheckWriteInterval: Int

    /// Decoded images kept in memory to avoid re-reading/decoding from disk on every
    /// view appearance. Bounded by `NSCache`'s own eviction under memory pressure.
    private let memory = NSCache<NSString, NSImage>()

    /// In-flight downloads, so concurrent requests for the same avatar share one fetch.
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    /// True once the pre-Twitch cache folder has been cleared this launch.
    private var hasPrunedLegacyDirectory = false
    private var hasAppliedDiskBudget = false

    /// Cached files written since the last budget sweep. Pruning enumerates the whole
    /// folder, so it runs once per launch and then only every `budgetCheckWriteInterval`
    /// writes rather than after each download.
    private var writesSinceBudgetCheck = 0

    init(
        urlSession: URLSession = .shared,
        diskByteLimit: Int64 = AvatarImageCache.defaultDiskByteLimit,
        diskFileLimit: Int = AvatarImageCache.defaultDiskFileLimit,
        budgetCheckWriteInterval: Int = AvatarImageCache.defaultBudgetCheckWriteInterval
    ) {
        self.urlSession = urlSession
        self.diskByteLimit = diskByteLimit
        self.diskFileLimit = diskFileLimit
        self.budgetCheckWriteInterval = max(1, budgetCheckWriteInterval)
        memory.countLimit = 64
        memory.totalCostLimit = 64 * 1_024 * 1_024
    }

    private var cacheDirectory: URL? {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("SwiftMiner/Avatars", isDirectory: true)
    }

    func image(for url: URL) async -> NSImage? {
        pruneLegacyDirectoryIfNeeded()
        applyDiskBudgetIfNeeded()
        let key = Self.key(for: url)

        if let cached = memory.object(forKey: key as NSString) {
            return cached
        }

        // Disk hit: load, promote to memory.
        if let localURL = cacheDirectory?.appendingPathComponent(key),
           FileManager.default.fileExists(atPath: localURL.path),
           let image = NSImage(contentsOf: localURL) {
            storeInMemory(image, key: key)
            return image
        }

        if let existing = inFlight[key] {
            return await existing.value
        }

        let task = Task<NSImage?, Never> { [weak self] in
            await self?.download(url: url, key: key) ?? nil
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    func clearCache() {
        memory.removeAllObjects()
        if let dir = cacheDirectory {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func download(url: URL, key: String) async -> NSImage? {
        do {
            let (data, response) = try await urlSession.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = NSImage(data: data) else { return nil }

            if let localURL = cacheDirectory?.appendingPathComponent(key) {
                try? FileManager.default.createDirectory(
                    at: localURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                do {
                    try data.write(to: localURL, options: .atomic)
                    applyDiskBudgetAfterWrite()
                } catch {
                    Logger.artwork.warning("Could not cache avatar: \(error.localizedDescription)")
                }
            }
            storeInMemory(image, key: key, cost: data.count)
            return image
        } catch {
            return nil
        }
    }

    private func storeInMemory(_ image: NSImage, key: String, cost: Int? = nil) {
        let estimatedCost = image.representations.first.map {
            max(1, $0.pixelsWide * $0.pixelsHigh * 4)
        } ?? 1
        memory.setObject(
            image,
            forKey: key as NSString,
            cost: max(cost ?? 0, estimatedCost)
        )
    }

    private func applyDiskBudgetIfNeeded() {
        guard !hasAppliedDiskBudget else { return }
        hasAppliedDiskBudget = true
        applyDiskBudget()
    }

    private func applyDiskBudgetAfterWrite() {
        writesSinceBudgetCheck += 1
        guard writesSinceBudgetCheck >= budgetCheckWriteInterval else { return }
        applyDiskBudget()
    }

    private func applyDiskBudget() {
        writesSinceBudgetCheck = 0
        guard let cacheDirectory else { return }
        let result = DiskCacheBudget.prune(
            directory: cacheDirectory,
            maximumBytes: diskByteLimit,
            maximumFileCount: diskFileLimit
        )
        if result.removedFiles > 0 {
            Logger.artwork.info("Pruned \(result.removedFiles) avatar cache file(s), freeing \(result.removedBytes) bytes")
        }
    }

    /// Discards the Discord-only cache folder this one replaced. Its contents are
    /// re-downloaded into the new folder on demand, so nothing is lost.
    private func pruneLegacyDirectoryIfNeeded() {
        guard !hasPrunedLegacyDirectory else { return }
        hasPrunedLegacyDirectory = true

        guard let legacy = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("SwiftMiner/DiscordAvatars", isDirectory: true) else { return }
        try? FileManager.default.removeItem(at: legacy)
    }

    private static func key(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Renders a profile picture through `AvatarImageCache`, falling back to `fallback`
/// while loading or when no URL/image is available. A cached avatar appears instantly
/// on subsequent shows — no re-download and no network flicker.
struct CachedAvatarImage<Fallback: View>: View {
    let url: URL?
    @ViewBuilder var fallback: () -> Fallback

    @State private var image: NSImage?
    /// The URL `image` was loaded from, so a re-run of the task for the same URL
    /// can keep drawing it.
    @State private var loadedURL: URL?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                fallback()
            }
        }
        .task(id: url) {
            // Drop the former service's image before loading the new one, so an
            // avatar-source switch doesn't briefly show a stale picture. The task
            // also re-runs on every re-appearance, though, and clearing there
            // would flash the fallback for a picture that is already in hand —
            // hence only clearing when the URL genuinely changed.
            if loadedURL != url {
                image = nil
                loadedURL = nil
            }
            guard let url else {
                return
            }
            guard image == nil else { return }
            let resolvedImage = await AvatarImageCache.shared.image(for: url)
            guard !Task.isCancelled else { return }
            image = resolvedImage
            loadedURL = resolvedImage == nil ? nil : url
        }
    }
}
