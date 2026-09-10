import Foundation

/// The branded HTML invitation SwiftMiner hands to Apple Mail.
///
/// Mail's compose window is a WebKit editor, so a Mail draft can carry the same
/// card the SwiftMiner setup page shows. The markup is deliberately plain,
/// table-based and inline-styled — the shapes email clients agree on — and the
/// icon is the hosted app icon rather than an embedded data URI, which several
/// clients strip.
enum InvitationEmailBody {
    /// The app icon as served by the website, so the image survives sending.
    static let iconURL = "https://swiftminer.app/icon-192.png"

    /// Written for the recipient: what they are approving, what the inviter can
    /// see, and how to disconnect. Linked rather than summarised, so the mail
    /// stays short and the explanation stays honest.
    static let explainerURL = "https://swiftminer.app/help/invited-to-swiftminer/"

    private static let purple = "#7651d6"
    private static let ink = "#1c1822"
    private static let secondary = "#68616f"
    private static let tertiary = "#8c8494"
    private static let hairline = "rgba(43, 30, 55, 0.11)"
    private static let fontStack = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', Helvetica, Arial, sans-serif"

    static func html(for invitation: SwiftMinerInvitation, now: Date = Date()) -> String {
        let inviter = escaped(invitation.inviterDisplayName)
        let link = escaped(invitation.invitationURL.absoluteString)
        let expiry = escaped(expiryLine(for: invitation, now: now))

        return """
        <div style="margin:0;padding:0;background:#ffffff;">
        <table role="presentation" border="0" cellpadding="0" cellspacing="0" width="100%" style="border-collapse:collapse;background:#ffffff;">
        <tr><td align="left" style="padding:4px 0;">
        <table role="presentation" border="0" cellpadding="0" cellspacing="0" width="560" style="width:560px;max-width:100%;border-collapse:separate;border:1px solid \(hairline);border-radius:20px;background:#ffffff;">
        <tr><td style="padding:34px 38px 32px 38px;font-family:\(fontStack);color:\(ink);">
        <img src="\(iconURL)" width="56" height="56" alt="SwiftMiner" style="display:block;width:56px;height:56px;border-radius:13px;">
        <p style="margin:22px 0 7px 0;font-family:\(fontStack);font-size:11px;font-weight:700;letter-spacing:1.6px;color:\(purple);">INVITATION</p>
        <h1 style="margin:0 0 12px 0;font-family:\(fontStack);font-size:29px;line-height:1.15;font-weight:700;letter-spacing:-0.02em;color:\(ink);">You&rsquo;ve been invited to SwiftMiner</h1>
        <p style="margin:0 0 26px 0;font-family:\(fontStack);font-size:16px;line-height:1.5;color:\(secondary);">\(inviter) has invited you to connect your Twitch account.</p>
        <a href="\(link)" style="display:block;padding:15px 24px;border-radius:12px;background:\(purple);font-family:\(fontStack);font-size:16px;font-weight:600;color:#ffffff;text-align:center;text-decoration:none;">Connect to SwiftMiner</a>
        <p style="margin:10px 0 0 0;font-family:\(fontStack);font-size:12px;line-height:1.5;color:\(tertiary);text-align:center;">This opens swiftminer.app, not Twitch. You&rsquo;ll see what you&rsquo;re approving there first, then sign in with Twitch.</p>
        <table role="presentation" border="0" cellpadding="0" cellspacing="0" width="100%" style="border-collapse:separate;margin:24px 0 0 0;background:rgba(118, 81, 214, 0.08);border-radius:12px;">
        <tr><td style="padding:14px 16px;font-family:\(fontStack);font-size:13px;line-height:1.5;color:\(secondary);">
        <span style="color:\(ink);font-weight:600;">You sign in directly with Twitch.</span> Your Twitch password and credentials are never shared with the person who invited you.
        </td></tr>
        <tr><td style="padding:0 16px 14px 16px;font-family:\(fontStack);font-size:13px;line-height:1.5;">
        <a href="\(explainerURL)" style="color:\(purple);font-weight:600;text-decoration:none;">New to SwiftMiner? What this invitation means &rsaquo;</a>
        </td></tr></table>
        <p style="margin:18px 0 0 0;font-family:\(fontStack);font-size:12px;color:\(tertiary);">\(expiry)</p>
        </td></tr>
        <tr><td style="padding:15px 38px;border-top:1px solid \(hairline);font-family:\(fontStack);font-size:11px;color:\(tertiary);">
        <table role="presentation" border="0" cellpadding="0" cellspacing="0" width="100%" style="border-collapse:collapse;">
        <tr>
        <td align="left" style="font-family:\(fontStack);font-size:11px;color:\(tertiary);">Secure SwiftMiner invitation</td>
        <td align="right" style="font-family:\(fontStack);font-size:11px;color:\(tertiary);">swiftminer.app</td>
        </tr></table>
        </td></tr></table>
        <p style="margin:14px 0 0 0;width:560px;max-width:100%;font-family:\(fontStack);font-size:11px;line-height:1.5;color:\(tertiary);word-break:break-all;">If the button does not work, open <a href="\(link)" style="color:\(tertiary);">\(link)</a></p>
        </td></tr></table>
        </div>
        """
    }

    /// The wording SwiftBot and the plain-text fallback share, so every channel
    /// says the same thing about how long the invitation lasts.
    static func expiryLine(for invitation: SwiftMinerInvitation, now: Date = Date()) -> String {
        let minutes = Int(ceil(invitation.expiresAt.timeIntervalSince(now) / 60))
        guard minutes > 0 else { return "This invitation has expired." }
        return minutes == 1
            ? "This invitation expires in 1 minute."
            : "This invitation expires in \(minutes) minutes."
    }

    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
