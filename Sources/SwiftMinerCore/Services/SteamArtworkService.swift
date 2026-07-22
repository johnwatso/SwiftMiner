import Foundation

/// Service for fetching game artwork from Steam CDN.
/// Provides higher-quality artwork than Twitch's default images.
/// Uses Steam Store search API to find App ID from game name.
public actor SteamArtworkService {
    
    // MARK: - Singleton
    
    public static let shared = SteamArtworkService()
    
    // MARK: - Cache

    private var appIdCache: [String: String] = [:]   // gameName.lowercased() -> appId
    private var failedLookups: Set<String> = []       // gameName.lowercased() that failed (confirmed)
    /// User-supplied overrides — persisted across launches. Take priority over auto-lookup.
    private var manualOverrides: [String: String] = [:]

    // MARK: - Configuration

    private let steamSearchURL  = "https://store.steampowered.com/api/storesearch/"
    private let steamCDNBaseURL = "https://cdn.cloudflare.steamstatic.com/steam/apps/"
    private static let manualOverridesDefaultsKey = "steamArtworkManualOverrides"
    private static let appIdCacheDefaultsKey = "steamArtworkAppIdCache"
    
    // MARK: - Init

    init() {
        if let saved = UserDefaults.standard.dictionary(forKey: Self.manualOverridesDefaultsKey) as? [String: String] {
            manualOverrides = saved
        }
        if let saved = UserDefaults.standard.dictionary(forKey: Self.appIdCacheDefaultsKey) as? [String: String] {
            appIdCache = saved
        }
    }

    // MARK: - Public API

    /// Whether a Twitch category should use Steam artwork lookup/overrides.
    public nonisolated static func supportsSteamArtwork(forGameName gameName: String, gameId: String? = nil) -> Bool {
        if gameId?.trimmingCharacters(in: .whitespacesAndNewlines) == "509658" {
            return false
        }

        let normalizedName = gameName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return normalizedName != "just chatting"
    }

    /// Manually pin a Steam App ID to a game name.
    /// Persists across launches and takes priority over auto-lookup.
    /// Pass an empty string to remove an existing override.
    public func setManualAppId(for gameName: String, appId: String) {
        let key = gameName.lowercased().trimmingCharacters(in: .whitespaces)
        guard Self.supportsSteamArtwork(forGameName: gameName) else {
            manualOverrides.removeValue(forKey: key)
            appIdCache.removeValue(forKey: key)
            failedLookups.insert(key)
            UserDefaults.standard.set(manualOverrides, forKey: Self.manualOverridesDefaultsKey)
            UserDefaults.standard.set(appIdCache, forKey: Self.appIdCacheDefaultsKey)
            Logger.artwork.warning("Ignoring Steam override for unsupported category '\(gameName)'")
            return
        }

        if appId.trimmingCharacters(in: .whitespaces).isEmpty {
            manualOverrides.removeValue(forKey: key)
        } else {
            manualOverrides[key] = appId.trimmingCharacters(in: .whitespaces)
        }
        // Clear any cached state so the new override takes effect immediately
        appIdCache.removeValue(forKey: key)
        failedLookups.remove(key)
        UserDefaults.standard.set(manualOverrides, forKey: Self.manualOverridesDefaultsKey)
        Logger.artwork.info("Manual override set for '\(gameName)': appId=\(appId)")
    }

    /// Get portrait (600x900) artwork URL for a game.
    /// Returns a local `file://` URL after first fetch — subsequent calls load from disk instantly.
    public func portraitURL(for gameName: String) async -> URL? {
        guard let appId = await lookupAppId(for: gameName),
              let remoteURL = URL(string: "\(steamCDNBaseURL)\(appId)/library_600x900.jpg") else {
            return nil
        }
        return await resolveImageURL(remote: remoteURL, appId: appId, type: "portrait")
    }

    /// Get landscape header artwork URL for a game.
    /// Returns a local `file://` URL after first fetch — subsequent calls load from disk instantly.
    public func landscapeURL(for gameName: String) async -> URL? {
        guard let appId = await lookupAppId(for: gameName),
              let remoteURL = URL(string: "\(steamCDNBaseURL)\(appId)/header.jpg") else {
            return nil
        }
        return await resolveImageURL(remote: remoteURL, appId: appId, type: "landscape")
    }

    /// Get the Steam library hero banner URL (landscape, typically the freshest artwork).
    /// Checks disk cache first; downloads and caches on first call.
    public func heroURL(for gameName: String) async -> URL? {
        guard let appId = await lookupAppId(for: gameName) else { return nil }
        // Serve from disk if already cached — skip CDN availability check entirely
        if let localURL = localImageURL(appId: appId, type: "hero"),
           FileManager.default.fileExists(atPath: localURL.path) {
            return localURL
        }
        // First time: find a working CDN URL, then download and cache it
        let candidates = [
            "\(steamCDNBaseURL)\(appId)/library_hero_2x.jpg",
            "\(steamCDNBaseURL)\(appId)/library_hero.jpg"
        ]
        for urlString in candidates {
            if let url = URL(string: urlString), await cdnURLExists(urlString) {
                return await resolveImageURL(remote: url, appId: appId, type: "hero")
            }
        }
        return nil
    }
    
    /// Clear the lookup cache and disk image cache.
    public func clearCache() {
        appIdCache.removeAll()
        failedLookups.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.appIdCacheDefaultsKey)
        if let dir = imageCacheDirectory {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Disk Image Cache

    /// Root directory for cached Steam artwork on disk.
    /// Lives in the user's Caches folder so the OS can reclaim space if needed.
    private var imageCacheDirectory: URL? {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("SwiftMiner/SteamArtwork", isDirectory: true)
    }

    /// Stable local path for a given App ID and image type (e.g. "portrait", "hero").
    private func localImageURL(appId: String, type: String) -> URL? {
        imageCacheDirectory?.appendingPathComponent("\(appId)_\(type).jpg")
    }

    /// Returns a local `file://` URL for `remoteURL`, downloading and caching to disk on first call.
    /// Subsequent calls return the local file immediately — no network required.
    private func resolveImageURL(remote remoteURL: URL, appId: String, type: String) async -> URL? {
        guard let localURL = localImageURL(appId: appId, type: type) else { return remoteURL }
        if FileManager.default.fileExists(atPath: localURL.path) {
            return localURL
        }
        do {
            try FileManager.default.createDirectory(
                at: localURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let (data, response) = try await URLSession.shared.data(from: remoteURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            try data.write(to: localURL, options: .atomic)
            Logger.artwork.debug("Cached \(type) image for appId=\(appId)")
            return localURL
        } catch {
            Logger.artwork.error("Disk cache write failed for appId=\(appId) type=\(type): \(error)")
            return remoteURL
        }
    }
    
    // MARK: - Private Methods
    
    /// Look up Steam App ID from game name
    /// Uses Steam Store search API and caches results
    private func lookupAppId(for gameName: String) async -> String? {
        let normalizedName = gameName.lowercased().trimmingCharacters(in: .whitespaces)
        
        Logger.artwork.debug("Looking up: '\(gameName)' (normalized: '\(normalizedName)')")

        guard Self.supportsSteamArtwork(forGameName: gameName) else {
            manualOverrides.removeValue(forKey: normalizedName)
            appIdCache.removeValue(forKey: normalizedName)
            failedLookups.insert(normalizedName)
            UserDefaults.standard.set(manualOverrides, forKey: Self.manualOverridesDefaultsKey)
            UserDefaults.standard.set(appIdCache, forKey: Self.appIdCacheDefaultsKey)
            Logger.artwork.debug("Skipping Steam artwork for unsupported category '\(gameName)'")
            return nil
        }
        
        // Manual overrides take priority — always used, never skipped
        if let manualId = manualOverrides[normalizedName] {
            Logger.artwork.debug("Manual override for '\(gameName)': appId=\(manualId)")
            return manualId
        }

        // Auto-lookup cache
        if let cachedId = appIdCache[normalizedName] {
            Logger.artwork.debug("Cache hit for '\(gameName)': appId=\(cachedId)")
            return cachedId
        }
        
        // Don't retry failed lookups in this session
        if failedLookups.contains(normalizedName) {
            Logger.artwork.debug("Previously failed lookup for '\(gameName)', skipping")
            return nil
        }
        
        do {
            let appId = try await performSearch(gameName: gameName)
            if let appId = appId {
                Logger.artwork.info("Found match for '\(gameName)': appId=\(appId)")
                appIdCache[normalizedName] = appId
                UserDefaults.standard.set(appIdCache, forKey: Self.appIdCacheDefaultsKey)
                return appId
            } else {
                Logger.artwork.info("No match found for '\(gameName)'")
                failedLookups.insert(normalizedName)
                return nil
            }
        } catch {
            // Transient errors (cancellation, network timeout) must NOT poison the negative cache.
            // Only confirmed "no match / no valid CDN art" results belong in failedLookups.
            let isCancellation = error is CancellationError
                || (error as NSError).code == NSURLErrorCancelled
            if isCancellation {
                Logger.artwork.debug("Lookup cancelled for '\(gameName)' (transient, will retry)")
            } else {
                Logger.artwork.warning("Lookup failed for '\(gameName)': \(error)")
            }
            return nil
        }
    }
    
    /// Perform Steam Store search
    private func performSearch(gameName: String) async throws -> String? {
        var components = URLComponents(string: steamSearchURL)!
        components.queryItems = [
            URLQueryItem(name: "term", value: gameName),
            URLQueryItem(name: "cc", value: "US"), // Country code
            URLQueryItem(name: "l", value: "en"),  // Language
            URLQueryItem(name: "v", value: "1")    // API version
        ]
        
        guard let url = components.url else {
            throw SteamArtworkError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw SteamArtworkError.searchFailed
        }
        
        // Parse Steam search response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            Logger.artwork.warning("Invalid JSON response for '\(gameName)'")
            return nil
        }
        
        Logger.artwork.debug("Steam returned \(items.count) items for '\(gameName)'")
        
        // Log first few results for debugging
        for (index, item) in items.prefix(3).enumerated() {
            if let name = item["name"] as? String, let appId = item["id"] as? Int {
                Logger.artwork.debug("Result \(index + 1): '\(name)' (appId: \(appId))")
            }
        }
        
        // Extract (appId, name) pairs
        let candidates: [(id: String, name: String)] = items.compactMap { item in
            guard let appId = item["id"] as? Int,
                  let name  = item["name"] as? String else { return nil }
            return (String(appId), name)
        }
        guard !candidates.isEmpty else { return nil }

        let normalizedQuery = gameName.lowercased()

        // 1. Exact name match (case-insensitive) with CDN validation
        if let exact = candidates.first(where: { $0.name.lowercased() == normalizedQuery }) {
            if await cdnPortraitExists(appId: exact.id) {
                Logger.artwork.info("Exact match '\(exact.name)' (appId=\(exact.id)) verified")
                return exact.id
            }
        }

        // 2. First candidate whose portrait CDN URL actually returns 200
        for candidate in candidates {
            if await cdnPortraitExists(appId: candidate.id) {
                Logger.artwork.info("Using '\(candidate.name)' (appId=\(candidate.id)) for query '\(gameName)'")
                return candidate.id
            }
        }

        Logger.artwork.info("No valid portrait CDN URL found for '\(gameName)'")
        return nil
    }

    /// Returns true if a Steam CDN portrait image (library_600x900.jpg) is accessible for this appId.
    private func cdnPortraitExists(appId: String) async -> Bool {
        await cdnURLExists("\(steamCDNBaseURL)\(appId)/library_600x900.jpg")
    }

    /// Returns true if any Steam CDN URL returns HTTP 200.
    private func cdnURLExists(_ urlString: String) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}

// MARK: - Errors

enum SteamArtworkError: Error {
    case invalidURL
    case searchFailed
    case noResults
}
