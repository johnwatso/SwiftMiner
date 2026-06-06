import AppKit
import CryptoKit
import Foundation
import SwiftUI

/// Disk- and memory-backed cache for Discord profile pictures.
///
/// Discord avatar URLs embed the avatar hash, so the URL changes whenever a user
/// updates their picture — hashing the full URL gives a stable, change-aware cache
/// key without any extra invalidation logic. Cached files live in the user's Caches
/// directory so the OS can reclaim the space under pressure.
actor DiscordAvatarCache {
    static let shared = DiscordAvatarCache()

    /// Decoded images kept in memory to avoid re-reading/decoding from disk on every
    /// view appearance. Bounded by `NSCache`'s own eviction under memory pressure.
    private let memory = NSCache<NSString, NSImage>()

    /// In-flight downloads, so concurrent requests for the same avatar share one fetch.
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    private var cacheDirectory: URL? {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("SwiftMiner/DiscordAvatars", isDirectory: true)
    }

    func image(for url: URL) async -> NSImage? {
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
            let (data, response) = try await URLSession.shared.data(from: url)
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

    private static func key(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Renders a Discord avatar through `DiscordAvatarCache`, falling back to `fallback`
/// while loading or when no URL/image is available. A cached avatar appears instantly
/// on subsequent shows — no re-download and no network flicker.
struct CachedDiscordAvatar<Fallback: View>: View {
    let url: URL?
    @ViewBuilder var fallback: () -> Fallback

    @State private var image: NSImage?

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
            guard let url else {
                image = nil
                return
            }
            image = await DiscordAvatarCache.shared.image(for: url)
        }
    }
}
