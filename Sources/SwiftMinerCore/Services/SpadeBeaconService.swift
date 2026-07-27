import Foundation

/// Handles the Twitch "Spade" analytics beacon used to simulate watching a stream.
///
/// Twitch registers watch-time by receiving a `minute-watched` event every ~59 seconds.
/// The beacon is a base64-encoded JSON payload POSTed to a dynamic URL extracted from
/// the Twitch channel page (falling back to the canonical spade endpoint).
///
/// Reference: TwitchDropsMiner Python implementation (channel.py / twitch.py)
public actor SpadeBeaconService {

    // MARK: - Constants

    /// How often to send the beacon (Python ref: WATCH_INTERVAL = 59s)
    public static let watchInterval: TimeInterval = 59

    /// Fallback spade URL if extraction from the channel page fails
    private static let fallbackSpadeURL = URL(string: "https://spade.twitch.tv/track")!

    // MARK: - State

    private let urlSession: URLSession

    /// Android User-Agent for this service instance. Starts as a random pick
    /// and is swapped to the sticky-per-account allocation via
    /// `setAccountId(_:)` once the authenticated account is known, so all
    /// Spade traffic for a miner shares a fingerprint with its auth/API.
    private var userAgent = TwitchClientFingerprint.randomAndroidUserAgent()

    /// Switches this service's UA to the sticky allocation for `accountId`.
    public func setAccountId(_ accountId: String) {
        userAgent = TwitchClientFingerprint.shared.userAgent(for: accountId)
    }

    /// Cache: channel login → spade URL
    private var spadeURLCache: [String: URL] = [:]

    // MARK: - Init

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    // MARK: - Public API

    /// Send a single `minute-watched` beacon for the given channel.
    ///
    /// - Parameters:
    ///   - channelLogin:  Lowercase channel login name (e.g. `"shroud"`)
    ///   - channelId:     Numeric channel/user ID string
    ///   - broadcastId:   Live stream broadcast ID (pass `"0"` if unknown)
    ///   - userId:        Authenticated viewer's user ID string
    ///   - gameName:      Current stream category name
    ///   - gameId:        Current stream category ID
    public func sendBeacon(
        channelLogin: String,
        channelId: String,
        broadcastId: String,
        userId: String,
        gameName: String = "",
        gameId: String = "",
        at date: Date = Date()
    ) async throws {
        traceSpade("minute-watched → channel=\(channelLogin) broadcast=\(broadcastId) user=\(userId)")
        let spadeURL = await resolveSpadeURL(for: channelLogin)
        let payload = buildPayload(
            channelLogin: channelLogin,
            channelId: channelId,
            broadcastId: broadcastId,
            userId: userId,
            gameName: gameName,
            gameId: gameId,
            date: date
        )
        try await post(payload: payload, to: spadeURL, channelLogin: channelLogin)
    }

    /// Clears the cached spade URL for a channel (call if extraction ever returns stale data).
    public func clearCache(for channelLogin: String) {
        spadeURLCache.removeValue(forKey: channelLogin)
    }

    // MARK: - Spade URL Resolution

    /// Returns the spade URL for a channel, extracting and caching it from the channel page.
    private func resolveSpadeURL(for channelLogin: String) async -> URL {
        if let cached = spadeURLCache[channelLogin] {
            return cached
        }
        let resolved = (try? await extractSpadeURL(channelLogin: channelLogin)) ?? Self.fallbackSpadeURL
        spadeURLCache[channelLogin] = resolved
        return resolved
    }

    /// Fetches the Twitch channel page and extracts the Spade beacon URL.
    ///
    /// Steps:
    ///   1. GET `https://www.twitch.tv/<login>`
    ///   2. Check if `spade_url` is directly in the HTML (typical for mobile/minimal views)
    ///   3. Find the `settings.js`-style bundle URL in the page HTML
    ///   4. GET that bundle and regex-extract `spade_url`
    private func extractSpadeURL(channelLogin: String) async throws -> URL {
        // Step 1: fetch the channel page
        let pageURL = URL(string: "https://www.twitch.tv/\(channelLogin)")!
        var pageRequest = URLRequest(url: pageURL)
        pageRequest.timeoutInterval = 15
        // TDM PARITY: Use Android User-Agent consistently
        pageRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (pageData, _) = try await urlSession.data(for: pageRequest)
        let pageHTML = String(data: pageData, encoding: .utf8) ?? ""
        let pageRange = NSRange(pageHTML.startIndex..., in: pageHTML)

        // Step 2: Check if spade_url is directly in the page HTML (TDM Step #1)
        let spadePattern = #""spade_url"\s*:\s*"(https://[^"]+)""#
        let spadeRegex = try NSRegularExpression(pattern: spadePattern, options: [.caseInsensitive])
        
        if let match = spadeRegex.firstMatch(in: pageHTML, options: [], range: pageRange),
           let urlRange = Range(match.range(at: 1), in: pageHTML),
           let url = URL(string: String(pageHTML[urlRange])) {
            return url
        }

        // Step 3: find the settings/assets bundle that contains the spade URL
        //
        // The Twitch page embeds several <script src="..."> tags. We look for
        // one that contains "settings" in the name (historically "settings.js")
        // or just iterate all script sources and find the one with spade_url.
        let scriptPattern = #"<script[^>]+src="(https://[^"]+\.js[^"]*)"[^>]*>"#
        let scriptRegex = try NSRegularExpression(pattern: scriptPattern, options: [])
        let scriptMatches = scriptRegex.matches(in: pageHTML, options: [], range: pageRange)

        var scriptURLs: [String] = scriptMatches.compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: pageHTML) else { return nil }
            return String(pageHTML[range])
        }

        // Prioritise any URL that has "settings" in it, like older Twitch bundles did.
        if let settingsURL = scriptURLs.first(where: { $0.contains("settings") }) {
            scriptURLs = [settingsURL] + scriptURLs.filter { $0 != settingsURL }
        }

        // Step 4: scan each bundle for spade_url
        for scriptURLString in scriptURLs.prefix(5) { // check at most 5 bundles
            guard let scriptURL = URL(string: scriptURLString) else { continue }
            var scriptRequest = URLRequest(url: scriptURL)
            scriptRequest.timeoutInterval = 15
            guard let (scriptData, _) = try? await urlSession.data(for: scriptRequest) else { continue }
            let scriptContent = String(data: scriptData, encoding: .utf8) ?? ""
            let scriptRange = NSRange(scriptContent.startIndex..., in: scriptContent)

            if let match = spadeRegex.firstMatch(in: scriptContent, options: [], range: scriptRange),
               let urlRange = Range(match.range(at: 1), in: scriptContent),
               let url = URL(string: String(scriptContent[urlRange])) {
                return url
            }
        }

        throw SpadeError.urlNotFound
    }

    // MARK: - Beacon Construction

    /// Builds the base64-encoded `minute-watched` event payload.
    ///
    /// Twitch expects the body as `data=<base64_string>` where the decoded
    /// value is a JSON array containing one event object.
    private func buildPayload(
        channelLogin: String,
        channelId: String,
        broadcastId: String,
        userId: String,
        gameName: String,
        gameId: String,
        date: Date
    ) -> Data {
        // TDM PARITY: user_id must be an Integer in the JSON payload.
        let userIdInt: Int64
        if let parsed = Int64(userId) {
            userIdInt = parsed
        } else {
            traceSpade("WARNING: Invalid user_id '\(userId)' — falling back to 0")
            userIdInt = 0
        }

        // TDM PARITY: To match TwitchDropsMiner's `json_minify` (compact, specific key order),
        // we build the JSON manually. Twitch accepts the legacy, shorter event with HTTP 204
        // but does not credit it as watched time, so keep this full property set aligned with
        // TwitchDropsMiner's current `Stream._watch_payload`.
        let clientTime = ISO8601DateFormatter.string(
            from: date,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            formatOptions: [.withInternetDateTime, .withFractionalSeconds]
        )
        let json = "[{\"event\":\"minute-watched\",\"properties\":{\"broadcast_id\":\(jsonString(broadcastId)),\"channel_id\":\(jsonString(channelId)),\"channel\":\(jsonString(channelLogin)),\"client_time\":\(jsonString(clientTime)),\"game\":\(jsonString(gameName)),\"game_id\":\(jsonString(gameId)),\"hidden\":false,\"is_live\":true,\"live\":true,\"logged_in\":true,\"minutes_logged\":1,\"muted\":false,\"user_id\":\(userIdInt)}}]"

        let base64 = Data(json.utf8).base64EncodedString()
        let formAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encodedBase64 = base64.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? base64
        let formBody = "data=\(encodedBase64)"
        return formBody.data(using: .utf8) ?? Data()
    }

    /// Returns one JSON string value, including quotes and any required escaping.
    private func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let arrayJSON = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return String(arrayJSON.dropFirst().dropLast())
    }

    // MARK: - Network

    private func post(payload: Data, to url: URL, channelLogin: String) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // TDM PARITY: Use Android User-Agent to match the Client ID. 
        // Referer is not sent by the Android app.
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = payload

        let (_, response) = try await urlSession.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw SpadeError.invalidResponse
        }

        // Twitch returns 204 No Content on success; 200 is also acceptable
        guard http.statusCode == 204 || http.statusCode == 200 else {
            throw SpadeError.unexpectedStatus(http.statusCode)
        }
    }
}

// MARK: - Errors

public enum SpadeError: Error, LocalizedError, Sendable {
    case urlNotFound
    case invalidResponse
    case unexpectedStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .urlNotFound:
            return "Could not extract Spade beacon URL from channel page"
        case .invalidResponse:
            return "Received non-HTTP response from Spade endpoint"
        case .unexpectedStatus(let code):
            return "Spade beacon returned unexpected HTTP \(code)"
        }
    }
}
