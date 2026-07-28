import Foundation

/// Rewrites Twitch box-art URLs to request a larger image.
///
/// Twitch serves box art from a size-templated path — the trailing `-WxH.jpg`,
/// or a `{width}`/`{height}` placeholder on Helix — and resizes server-side on
/// request. Asking for a bigger image returns genuinely more pixels rather than
/// an upscale, so there is no reason to interpolate locally.
///
/// The API hands out 120x160 by default, which is soft on anything larger than a
/// list thumbnail. Verified against the live CDN: the same asset returns real
/// 600x800 and 1920x2560 renders, all 3-channel colour.
public enum TwitchBoxArt {
    /// Sharp on Retina at card sizes (~120KB) without pulling megabytes per game
    /// for tiles that often render at thumbnail size.
    public static let preferredWidth = 600
    public static let preferredHeight = 800

    /// Twitch clamps each side at 2560 and stops preserving aspect ratio past it —
    /// a 2400x3200 request comes back 2400x2560, squashed — so requests must stay
    /// under the ceiling rather than asking for the largest possible image.
    public static let maximumDimension = 2560

    public static func sized(
        _ url: URL?,
        width: Int = preferredWidth,
        height: Int = preferredHeight
    ) -> URL? {
        guard let url else { return nil }
        return URL(string: sized(url.absoluteString, width: width, height: height)) ?? url
    }

    public static func sized(
        _ raw: String,
        width: Int = preferredWidth,
        height: Int = preferredHeight
    ) -> String {
        let w = min(max(1, width), maximumDimension)
        let h = min(max(1, height), maximumDimension)

        // Helix returns an explicit template.
        if raw.contains("{width}") || raw.contains("{height}") {
            return raw
                .replacingOccurrences(of: "{width}", with: "\(w)")
                .replacingOccurrences(of: "{height}", with: "\(h)")
        }

        // GraphQL bakes the size into the filename, in both the `_IGDB-120x160.jpg`
        // and bare `-120x160.jpg` forms. Anything else is left untouched.
        guard let range = raw.range(
            of: #"-\d+x\d+(?=\.[a-zA-Z]+$)"#,
            options: .regularExpression
        ) else {
            return raw
        }

        return raw.replacingCharacters(in: range, with: "-\(w)x\(h)")
    }
}
