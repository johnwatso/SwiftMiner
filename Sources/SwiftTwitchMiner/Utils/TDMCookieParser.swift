import Foundation

/// Parser for TwitchDropsMiner cookie jar files (pickle binary format).
/// Public API — mirrors the implementation in SwiftTwitchMinerApp/TDMCookieParser.swift.
public enum TDMCookieParser {

    public enum ParserError: LocalizedError {
        case invalidFormat
        case tokenNotFound(foundKeys: [String])

        public var errorDescription: String? {
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

    public static func parseToken(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let token = parsePickleToken(from: data) { return token }
        if let token = parseNetscapeToken(from: data) { return token }
        let keys = collectCookieKeys(from: data)
        throw ParserError.tokenNotFound(foundKeys: keys)
    }

    private static func parsePickleToken(from data: Data) -> String? {
        // ISO Latin-1 gives a 1:1 byte→char mapping, preserving all ASCII substrings in the binary.
        // TDM stores "auth-token" literally in the pickle stream; the actual token
        // (30 lowercase alphanumeric chars) is reliably the first 28–50 char alphanumeric
        // run after it. Field names between key and value are all ≤ 9 chars, and the
        // "value" key itself may be a BINGET memo reference (not inline), so opcode
        // scanning is unreliable — regex is simpler and correct.
        guard let raw = String(data: data, encoding: .isoLatin1) else { return nil }
        guard let authRange = raw.range(of: "auth-token") else { return nil }
        let lookAheadEnd = raw.index(authRange.upperBound,
                                     offsetBy: 512,
                                     limitedBy: raw.endIndex) ?? raw.endIndex
        let window = String(raw[authRange.upperBound..<lookAheadEnd])
        guard let regex = try? NSRegularExpression(pattern: "[a-zA-Z0-9]{28,50}"),
              let match = regex.firstMatch(in: window,
                                           range: NSRange(window.startIndex..., in: window)),
              let range = Range(match.range, in: window) else { return nil }
        return String(window[range])
    }

    private static func parseNetscapeToken(from data: Data) -> String? {
        guard let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              content.hasPrefix("# Netscape") || content.hasPrefix("# HTTP") else { return nil }
        for line in content.components(separatedBy: .newlines) {
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 7 else { continue }
            let name = parts[5]
            let value = parts[6].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !value.isEmpty, name == "auth-token" || name == "passport.oauth.access_token" { return value }
        }
        return nil
    }

    private static func collectCookieKeys(from data: Data) -> [String] {
        ["auth-token", "unique_id", "persistent", "server_session_id",
         "passport.oauth.access_token", "passport.oauth.refresh_token"]
            .filter { data.range(of: Data(Array($0.utf8))) != nil }
    }
}
