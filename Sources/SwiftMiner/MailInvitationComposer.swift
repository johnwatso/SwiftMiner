import AppKit
import Foundation
import OSLog

private let mailComposerLogger = Logger(subsystem: "com.swiftminer", category: "invitation-mail")

/// Opens a branded SwiftMiner invitation as an Apple Mail draft.
///
/// Mail's share extension only accepts text, attributed text and URLs, and it
/// moves any inline image to the end of the body, so the share sheet cannot
/// produce the invitation card. Mail's own scripting interface can: an outgoing
/// message accepts `html content`, and its compose window renders it.
///
/// SwiftMiner only ever *composes*. The draft opens with no recipient and is
/// never sent programmatically — the user addresses and sends it themselves.
enum MailInvitationComposer {
    private static let mailBundleIdentifier = "com.apple.mail"

    enum Failure: Error {
        /// The user has not granted SwiftMiner permission to control Mail.
        case automationDenied
        /// Mail is missing, or refused to open the draft.
        case mailUnavailable(String)

        var message: String {
            switch self {
            case .automationDenied:
                return "SwiftMiner needs permission to control Mail. Allow it in System Settings › Privacy & Security › Automation, then try again."
            case .mailUnavailable(let detail):
                return detail.isEmpty ? "Mail could not open the invitation." : detail
            }
        }
    }

    /// Asks Mail to open a draft carrying the invitation card.
    static func composeDraft(for invitation: SwiftMinerInvitation, now: Date = Date()) async throws(Failure) {
        try await launchMail()

        // Two separate Apple Events. The first absorbs whatever Mail still has
        // to finish after launching; a compose window created while Mail is
        // still starting up gets torn down again a second later, which looks
        // like the draft flashing up and vanishing.
        if let failure = await runScript(prepareSource) { throw failure }
        try? await Task.sleep(for: .milliseconds(400))

        let source = composeSource(
            subject: invitation.subject,
            html: InvitationEmailBody.html(for: invitation, now: now)
        )
        if let failure = await runScript(source) { throw failure }

        await activateMail()
    }

    /// Brings Mail up before scripting it, so the Apple Events below run against
    /// a live app and return promptly instead of blocking on a cold launch.
    private static func launchMail() async throws(Failure) {
        guard let mailURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: mailBundleIdentifier) else {
            throw Failure.mailUnavailable("Apple Mail is not installed on this Mac. Use Share Invitation… instead.")
        }

        // macOS only lets the frontmost app hand activation to another app when
        // it yields first; without this, Mail is scripted while SwiftMiner stays
        // in front and the draft opens behind the sheet.
        await MainActor.run {
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: mailBundleIdentifier)
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let mail: NSRunningApplication
        do {
            mail = try await NSWorkspace.shared.openApplication(at: mailURL, configuration: configuration)
        } catch {
            throw Failure.mailUnavailable("Mail could not be opened: \(error.localizedDescription)")
        }

        // Give a cold launch a moment to finish before scripting it.
        for _ in 0..<20 where !mail.isFinishedLaunching {
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// Mail only realises a compose window while it has at least one message
    /// viewer open. With every window closed — a normal way to leave Mail
    /// running — the draft is created but never appears, and the app looks like
    /// it did nothing.
    private static let prepareSource = """
        with timeout of 30 seconds
            tell application "Mail"
                activate
                if (count of message viewers) is 0 then make new message viewer
            end tell
        end timeout
        """

    /// The subject, body and visibility are all set in the one `make new`, which
    /// matters: creating the message hidden and revealing it afterwards races
    /// with Mail's own window handling and often loses the window, and setting
    /// `html content` on an already-visible message leaves the body empty.
    private static func composeSource(subject: String, html: String) -> String {
        """
        with timeout of 30 seconds
            tell application "Mail"
                make new outgoing message with properties {subject:"\(appleScriptLiteral(subject))", html content:"\(appleScriptLiteral(html))", visible:true}
                activate
            end tell
        end timeout
        """
    }

    /// `NSAppleScript` is not thread-safe, and the Apple Event it sends needs a
    /// run loop on the calling thread to receive Mail's reply, so this runs on
    /// the main actor. Mail is already up by this point, which keeps it brief.
    @MainActor
    private static func runScript(_ source: String) -> Failure? {
        guard let script = NSAppleScript(source: source) else {
            return .mailUnavailable("SwiftMiner could not build the Mail invitation.")
        }

        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return nil }

        let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
        let detail = errorInfo[NSAppleScript.errorMessage] as? String ?? ""
        mailComposerLogger.error("Mail draft failed code=\(code, privacy: .public) detail=\(detail, privacy: .public)")

        // -1743 is the user (or MDM) refusing Automation access; -600 and -1728
        // mean Mail never came up or has no scripting interface.
        switch code {
        case -1743, -10004:
            return .automationDenied
        default:
            return .mailUnavailable(detail)
        }
    }

    /// A final nudge so the draft is what the user is looking at. Deliberately
    /// not `.activateAllWindows`, which would raise Mail's inbox over it.
    private static func activateMail() async {
        await MainActor.run {
            _ = NSRunningApplication
                .runningApplications(withBundleIdentifier: mailBundleIdentifier)
                .first?
                .activate()
        }
    }

    /// Escapes a value for inclusion in an AppleScript string literal.
    ///
    /// The HTML is generated as a single line, so only the quote and escape
    /// characters need handling; any stray newline would still be legal inside
    /// an AppleScript literal but is normalised for safety.
    private static func appleScriptLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
