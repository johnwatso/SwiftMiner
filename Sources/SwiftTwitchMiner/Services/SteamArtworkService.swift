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
    
    // MARK: - Init

    init() {
        if let saved = UserDefaults.standard.dictionary(forKey: Self.manualOverridesDefaultsKey) as? [String: String] {
            manualOverrides = saved
        }
    }

    // MARK: - Public API

    /// Manually pin a Steam App ID to a game name.
    /// Persists across launches and takes priority over auto-lookup.
    /// Pass an empty string to remove an existing override.
    public func setManualAppId(for gameName: String, appId: String) {
        let key = gameName.lowercased().trimmingCharacters(in: .whitespaces)
        if appId.trimmingCharacters(in: .whitespaces).isEmpty {
            manualOverrides.removeValue(forKey: key)
        } else {
            manualOverrides[key] = appId.trimmingCharacters(in: .whitespaces)
        }
        // Clear any cached state so the new override takes effect immediately
        appIdCache.removeValue(forKey: key)
        failedLookups.remove(key)
        UserDefaults.standard.set(manualOverrides, forKey: Self.manualOverridesDefaultsKey)
        print("[SteamArtworkService] Manual override set for '\(gameName)': appId=\(appId)")
    }

    /// Get portrait (600x900) artwork URL for a game
    /// - Parameter gameName: The game name from Twitch
    /// - Returns: Steam CDN URL if found, nil otherwise
    public func portraitURL(for gameName: String) async -> URL? {
        guard let appId = await lookupAppId(for: gameName) else {
            return nil
        }
        return URL(string: "\(steamCDNBaseURL)\(appId)/library_600x900.jpg")
    }
    
    /// Get landscape header artwork URL for a game
    /// - Parameter gameName: The game name from Twitch
    /// - Returns: Steam CDN URL if found, nil otherwise
    public func landscapeURL(for gameName: String) async -> URL? {
        guard let appId = await lookupAppId(for: gameName) else {
            return nil
        }
        return URL(string: "\(steamCDNBaseURL)\(appId)/header.jpg")
    }
    
    /// Clear the lookup cache (useful for testing or memory pressure)
    public func clearCache() {
        appIdCache.removeAll()
        failedLookups.removeAll()
    }
    
    // MARK: - Private Methods
    
    /// Look up Steam App ID from game name
    /// Uses Steam Store search API and caches results
    private func lookupAppId(for gameName: String) async -> String? {
        let normalizedName = gameName.lowercased().trimmingCharacters(in: .whitespaces)
        
        print("[SteamArtworkService] Looking up: '\(gameName)' (normalized: '\(normalizedName)')")
        
        // Manual overrides take priority — always used, never skipped
        if let manualId = manualOverrides[normalizedName] {
            print("[SteamArtworkService] Manual override for '\(gameName)': appId=\(manualId)")
            return manualId
        }

        // Auto-lookup cache
        if let cachedId = appIdCache[normalizedName] {
            print("[SteamArtworkService] Cache hit for '\(gameName)': appId=\(cachedId)")
            return cachedId
        }
        
        // Don't retry failed lookups in this session
        if failedLookups.contains(normalizedName) {
            print("[SteamArtworkService] Previously failed lookup for '\(gameName)', skipping")
            return nil
        }
        
        do {
            let appId = try await performSearch(gameName: gameName)
            if let appId = appId {
                print("[SteamArtworkService] Found match for '\(gameName)': appId=\(appId)")
                appIdCache[normalizedName] = appId
                return appId
            } else {
                print("[SteamArtworkService] No match found for '\(gameName)'")
                failedLookups.insert(normalizedName)
                return nil
            }
        } catch {
            // Transient errors (cancellation, network timeout) must NOT poison the negative cache.
            // Only confirmed "no match / no valid CDN art" results belong in failedLookups.
            let isCancellation = error is CancellationError
                || (error as NSError).code == NSURLErrorCancelled
            if isCancellation {
                print("[SteamArtworkService] Lookup cancelled for '\(gameName)' (transient, will retry)")
            } else {
                print("[SteamArtworkService] Lookup failed for '\(gameName)': \(error)")
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
            print("[SteamArtworkService] Invalid JSON response for '\(gameName)'")
            return nil
        }
        
        print("[SteamArtworkService] Steam returned \(items.count) items for '\(gameName)'")
        
        // Log first few results for debugging
        for (index, item) in items.prefix(3).enumerated() {
            if let name = item["name"] as? String, let appId = item["id"] as? Int {
                print("[SteamArtworkService] Result \(index + 1): '\(name)' (appId: \(appId))")
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
                print("[SteamArtworkService] Exact match '\(exact.name)' (appId=\(exact.id)) verified")
                return exact.id
            }
        }

        // 2. First candidate whose portrait CDN URL actually returns 200
        for candidate in candidates {
            if await cdnPortraitExists(appId: candidate.id) {
                print("[SteamArtworkService] Using '\(candidate.name)' (appId=\(candidate.id)) for query '\(gameName)'")
                return candidate.id
            }
        }

        print("[SteamArtworkService] No valid portrait CDN URL found for '\(gameName)'")
        return nil
    }

    /// Returns true if the Steam CDN portrait image (library_600x900.jpg) is accessible.
    /// Prevents storing a URL that would silently 404 in the UI, replacing good Twitch artwork with nothing.
    private func cdnPortraitExists(appId: String) async -> Bool {
        guard let url = URL(string: "\(steamCDNBaseURL)\(appId)/library_600x900.jpg") else { return false }
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
