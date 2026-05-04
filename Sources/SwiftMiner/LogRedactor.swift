import Foundation

/// Scrubs secrets and PII from log lines before they are written to disk
/// for diagnostic export. Conservative by design: prefers over-redacting
/// to leaking a token. Each pattern is tested in `LogRedactorTests`.
enum LogRedactor {

    /// A single replacement rule. `replacement` may reference capture groups
    /// from `pattern` (e.g. `$1`) so the redacted output keeps useful shape.
    private struct Rule {
        let pattern: String
        let replacement: String
        let options: NSRegularExpression.Options

        init(_ pattern: String, _ replacement: String, _ options: NSRegularExpression.Options = [.caseInsensitive]) {
            self.pattern = pattern
            self.replacement = replacement
            self.options = options
        }
    }

    private static let rules: [Rule] = [
        // Twitch OAuth token shape: `oauth:abc123…`
        Rule(#"oauth:[A-Za-z0-9_\-]+"#, "oauth:<redacted>"),

        // Bearer authorization headers
        Rule(#"Bearer\s+[A-Za-z0-9_\-\.=]+"#, "Bearer <redacted>"),

        // Twitch session cookie names (auth-token, persistent, login). Match
        // either `name=value` or `"name":"value"` form.
        Rule(#"(auth-token|persistent|login)=[A-Za-z0-9_\-\.%]+"#, "$1=<redacted>"),
        Rule(#""(auth-token|persistent|login)"\s*:\s*"[^"]*""#, "\"$1\":\"<redacted>\""),

        // JWT-shaped tokens (three base64 segments separated by dots).
        Rule(#"\beyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\b"#, "<jwt-redacted>"),

        // Email addresses
        Rule(#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "<email>"),

        // Discord snowflakes after a "discord" hint (16-20 digit IDs).
        Rule(#"(discord[_\-]?(?:id|user)?)[=:\s]+\d{16,20}"#, "$1=<discord-id>"),

        // Generic 32+ char hex/base64 token-ish runs that look like secrets.
        // Kept last so the more specific rules above run first.
        Rule(#"\b[A-Za-z0-9]{40,}\b"#, "<redacted-token>", [])
    ]

    private static let compiledRules: [(NSRegularExpression, String)] = rules.compactMap { rule in
        guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: rule.options) else {
            return nil
        }
        return (regex, rule.replacement)
    }

    /// Returns `input` with every known secret pattern replaced.
    static func redact(_ input: String) -> String {
        var result = input
        for (regex, replacement) in compiledRules {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: replacement)
        }
        return result
    }
}
