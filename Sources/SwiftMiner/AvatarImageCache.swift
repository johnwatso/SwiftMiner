import AppKit
import CryptoKit
import Foundation
import SwiftUI

/// Disk- and memory-backed cache for miner profile pictures, from Discord or Twitch.
///
/// Both services embed the picture's identity in its URL — Discord the avatar hash,
/// Twitch a per-upload path — so the URL changes whenever a user swaps their picture.
/// Hashing the full URL therefore gives a stable, change-aware cache key without any
/// extra invalidation logic. Cached files live in the user's Caches directory so the
/// OS can reclaim the space under pressure.
actor AvatarImageCache {
    static let shared = AvatarImageCache()

    private let urlSession: URLSession

    /// Decoded images kept in memory to avoid re-reading/decoding from disk on every
    /// view appearance. Bounded by `NSCache`'s own eviction under memory pressure.
    private let memory = NSCache<NSString, NSImage>()

    /// In-flight downloads, so concurrent requests for the same avatar share one fetch.
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    /// True once the pre-Twitch cache folder has been cleared this launch.
    private var hasPrunedLegacyDirectory = false

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    private var cacheDirectory: URL? {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("SwiftMiner/Avatars", isDirectory: true)
    }

    func image(for url: URL) async -> NSImage? {
        pruneLegacyDirectoryIfNeeded()
        let key = Self.key(for: url)

        if let cached = memory.object(forKey: key as NSString) {
            return cached
        }

        // Disk hit: load, promote to memory.
        if let localURL = cacheDirectory?.appendingPathComponent(key),
           FileManager.default.fileExists(atPath: localURL.path),
           let image = NSImage(contentsOf: localURL) {
            memory.setObject(image, forKey: key as NSString)
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
                try? data.write(to: localURL, options: .atomic)
            }
            memory.setObject(image, forKey: key as NSString)
            return image
        } catch {
            return nil
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
