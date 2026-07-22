// Deterministic avatar color swatches for campaign watcher stacks.
import SwiftUI
import SwiftMinerCore
import AppKit

struct AvatarColorSwatch {
    let top: Color
    let bottom: Color
    let text: Color

    var gradient: LinearGradient {
        LinearGradient(
            colors: [top, bottom],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

enum AvatarColorPalette {
    private static let palette: [NSColor] = [
        .systemBlue,
        .systemIndigo,
        .systemPurple,
        .systemPink,
        .systemOrange,
        .systemTeal,
        .systemGreen
    ]

    static func swatch(for userID: String?, username: String) -> AvatarColorSwatch {
        let base = softenedBaseColor(
            for: normalizedKey(userID: userID, username: username)
        )
        let top = base
            .mixed(with: .white, amount: 0.20)
            .adjusted(saturationFactor: 0.96, brightnessFactor: 1.03)
        let bottom = base
            .mixed(with: .black, amount: 0.08)
            .adjusted(saturationFactor: 0.97, brightnessFactor: 0.93)

        let text: Color = base.relativeLuminance > 0.64
            ? Color.black.opacity(0.72)
            : Color.white.opacity(0.93)

        return AvatarColorSwatch(
            top: Color(nsColor: top),
            bottom: Color(nsColor: bottom),
            text: text
        )
    }

    private static func softenedBaseColor(for userKey: String) -> NSColor {
        let hash = stableHash(for: userKey)
        let index = Int(hash % UInt64(palette.count))
        let variantA = CGFloat((hash >> 24) & 0xFF) / 255
        let variantB = CGFloat((hash >> 32) & 0xFF) / 255
        let variantC = CGFloat((hash >> 40) & 0xFF) / 255

        let saturationFactor = 0.70 + (variantA * 0.11)
        let brightnessFactor = 0.87 + (variantB * 0.09)
        let whiteMix = 0.08 + (variantC * 0.05)

        return palette[index]
            .adjusted(
                saturationFactor: saturationFactor,
                brightnessFactor: brightnessFactor
            )
            .mixed(with: .white, amount: whiteMix)
    }

    private static func stableHash(for value: String) -> UInt64 {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in value.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }

        // Finalize for stronger low-bit distribution before modulo palette size.
        hash ^= hash >> 30
        hash &*= 0xBF58_476D_1CE4_E5B9
        hash ^= hash >> 27
        hash &*= 0x94D0_49BB_1331_11EB
        hash ^= hash >> 31
        return hash
    }

    private static func normalizedKey(userID: String?, username: String) -> String {
        let normalizedID = (userID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !normalizedID.isEmpty {
            return normalizedID
        }
        return username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private extension NSColor {
    func adjusted(saturationFactor: CGFloat, brightnessFactor: CGFloat) -> NSColor {
        let color = (usingColorSpace(.deviceRGB) ?? self)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        return NSColor(
            hue: hue,
            saturation: max(0, min(1, saturation * saturationFactor)),
            brightness: max(0, min(1, brightness * brightnessFactor)),
            alpha: alpha
        )
    }

    func mixed(with color: NSColor, amount: CGFloat) -> NSColor {
        let start = usingColorSpace(.deviceRGB) ?? self
        let end = color.usingColorSpace(.deviceRGB) ?? color
        let t = max(0, min(1, amount))

        var sr: CGFloat = 0
        var sg: CGFloat = 0
        var sb: CGFloat = 0
        var sa: CGFloat = 0
        var er: CGFloat = 0
        var eg: CGFloat = 0
        var eb: CGFloat = 0
        var ea: CGFloat = 0
        start.getRed(&sr, green: &sg, blue: &sb, alpha: &sa)
        end.getRed(&er, green: &eg, blue: &eb, alpha: &ea)

        return NSColor(
            red: sr + ((er - sr) * t),
            green: sg + ((eg - sg) * t),
            blue: sb + ((eb - sb) * t),
            alpha: sa + ((ea - sa) * t)
        )
    }

    var relativeLuminance: CGFloat {
        let color = usingColorSpace(.deviceRGB) ?? self
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)

        func linearize(_ channel: CGFloat) -> CGFloat {
            if channel <= 0.04045 {
                return channel / 12.92
            }
            return pow((channel + 0.055) / 1.055, 2.4)
        }

        let lr = linearize(r)
        let lg = linearize(g)
        let lb = linearize(b)
        return (0.2126 * lr) + (0.7152 * lg) + (0.0722 * lb)
    }
}

func gameTintColor(forGameName gameName: String) -> Color {
    let name = gameName.lowercased()
    if name.contains("rust") { return .orange }
    if name.contains("fortnite") { return .blue }
    if name.contains("valorant") { return .red }
    if name.contains("finals") { return .pink }
    return .purple
}
