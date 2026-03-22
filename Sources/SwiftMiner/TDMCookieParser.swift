import Foundation

/// Parser for TwitchDropsMiner cookie jar files.
/// TDM saves cookies as a Python pickle binary (defaultdict of SimpleCookie objects),
/// NOT as a Netscape text cookie jar despite the `.jar` extension.
enum TDMCookieParser {

    enum ParserError: LocalizedError {
        case invalidFormat
        case tokenNotFound(foundKeys: [String])

        var errorDescription: String? {
            switch self {
            case .invalidFormat:
                return "Could not read cookie jar file."
            case .tokenNotFound(let keys):
                if keys.isEmpty {
                    return "No Twitch cookies found. Make sure this is a cookies.jar from TwitchDropsMiner and that you were logged into Twitch within TDM."
                }
                return "Auth token not found. Found cookie keys: \(keys.joined(separator: ", "))"
            }
        }
    }

    /// Extracts the Twitch `auth-token` from a TDM cookies.jar file.
    /// Supports both the Python pickle format (TDM default) and the
    /// Mozilla/Netscape text format as a fallback.
    static func parseToken(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)

        // Try pickle binary format first (TDM's actual format)
        if let token = parsePickleToken(from: data) {
            print("[TDMCookieParser] Parsed auth-token from pickle format")
            return token
        }

        // Fall back to Netscape text format
        if let token = parseNetscapeToken(from: data) {
            print("[TDMCookieParser] Parsed auth-token from Netscape text format")
            return token
        }

        // Collect visible cookie names for the error message
        let keys = collectCookieKeys(from: data)
        print("[TDMCookieParser] Token not found. Visible keys: \(keys)")
        throw ParserError.tokenNotFound(foundKeys: keys)
    }

    // MARK: - Pickle format

    /// Extracts auth-token from Python pickle binary.
    /// Strategy: find the literal "auth-token" bytes in the binary, then use regex
    /// to find the first alphanumeric string of 28-50 chars immediately following it.
    /// Twitch auth tokens are always ~30 lowercase alphanumeric characters.
    /// The fields between the key and value (expires, path, etc.) are all ≤ 9 chars,
    /// so the token is reliably the first long alphanumeric sequence after the key.
    private static func parsePickleToken(from data: Data) -> String? {
        // Use ISO Latin-1 to get a 1:1 byte→char mapping — preserves ASCII substrings
        guard let raw = String(data: data, encoding: .isoLatin1) else { return nil }

        // Find the literal "auth-token" string in the binary
        guard let authRange = raw.range(of: "auth-token") else { return nil }

        // Scan up to 512 chars ahead for the first 28–50 char alphanumeric run (the token)
        let lookAheadEnd = raw.index(authRange.upperBound,
                                     offsetBy: 512,
                                     limitedBy: raw.endIndex) ?? raw.endIndex
        let window = String(raw[authRange.upperBound..<lookAheadEnd])

        guard let regex = try? NSRegularExpression(pattern: "[a-zA-Z0-9]{28,50}"),
              let match = regex.firstMatch(in: window,
                                           range: NSRange(window.startIndex..., in: window)),
              let range = Range(match.range, in: window) else { return nil }

        let token = String(window[range])
        print("[TDMCookieParser] Found candidate token: \(token.prefix(10))... (len=\(token.count))")
        return token
    }

    // MARK: - Netscape text format (fallback)

    private static func parseNetscapeToken(from data: Data) -> String? {
        let content: String
        if let s = String(data: data, encoding: .utf8) { content = s }
        else if let s = String(data: data, encoding: .isoLatin1) { content = s }
        else { return nil }

        guard content.hasPrefix("# Netscape") || content.hasPrefix("# HTTP") else { return nil }

        for line in content.components(separatedBy: .newlines) {
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 7 else { continue }
            let name  = parts[5]
            let value = parts[6].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard !value.isEmpty else { continue }
            if name == "auth-token" || name == "passport.oauth.access_token" {
                return value
            }
        }
        return nil
    }

    // MARK: - Diagnostics

    /// Collects all SHORT_BINUNICODE strings from the binary that look like cookie names.
    private static func collectCookieKeys(from data: Data) -> [String] {
        let knownKeys = ["auth-token", "unique_id", "unique_id_durable", "persistent",
                         "server_session_id", "twitch.lohp.countryCode",
                         "passport.oauth.access_token", "passport.oauth.refresh_token"]
        var found: [String] = []
        for key in knownKeys {
            let needle = Data(Array(key.utf8))
            if data.range(of: needle) != nil {
                found.append(key)
            }
        }
        return found
    }
}
