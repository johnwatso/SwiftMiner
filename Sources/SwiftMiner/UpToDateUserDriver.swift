#if canImport(Sparkle)
import AppKit
import Foundation
import Sparkle

/// Sparkle's standard update UI with one sentence rewritten.
///
/// When the running build is newer than the newest build in the appcast — every
/// development build is, because `CURRENT_PROJECT_VERSION` moves on every commit
/// — Sparkle disambiguates by appending both build numbers and a second
/// sentence: "SwiftMiner 1.40.6 (2026090610) is currently the newest version
/// available.\n(You are currently running version 1.40.6 (2026090708).)". It is
/// accurate and unreadable, and it is the only case where build numbers surface:
/// `SPUStandardVersionDisplay` adds them solely to tell two identical marketing
/// versions apart.
///
/// This rewrites the recovery suggestion to the plain sentence a released build
/// already gets, then hands the patched error back to `SPUStandardUserDriver`,
/// which keeps ownership of the alert, of dismissing the "Checking for updates…"
/// window first, and of the acknowledgement. Only the sentence changes.
///
/// The reasons that mean "an update exists but this Mac cannot install it"
/// (macOS too old or too new, Apple silicon required) pass through untouched:
/// those sentences carry information the user needs, and replacing them with
/// "you're up to date" would be a lie.
final class UpToDateUserDriver: SPUStandardUserDriver {

    override func showUpdateNotFoundWithError(
        _ error: any Error,
        acknowledgement: @escaping () -> Void
    ) {
        let nsError = error as NSError

        guard let suggestion = Self.plainRecoverySuggestion(for: nsError) else {
            super.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
            return
        }

        var userInfo = nsError.userInfo
        userInfo[NSLocalizedRecoverySuggestionErrorKey] = suggestion

        super.showUpdateNotFoundWithError(
            NSError(domain: nsError.domain, code: nsError.code, userInfo: userInfo),
            acknowledgement: acknowledgement
        )
    }

    /// The single "you are on the newest version" sentence, or `nil` when
    /// Sparkle's own wording should stand.
    static func plainRecoverySuggestion(for error: NSError, bundle: Bundle = .main) -> String? {
        guard let rawReason = error.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber,
              let reason = SPUNoUpdateFoundReason(rawValue: OSStatus(rawReason.intValue)) else {
            return nil
        }

        switch reason {
        case .unknown, .onLatestVersion, .onNewerThanLatestVersion:
            break
        case .systemIsTooOld, .systemIsTooNew, .hardwareDoesNotSupportARM64:
            return nil
        @unknown default:
            return nil
        }

        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "SwiftMiner"
        let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !version.isEmpty else { return nil }

        return "\(name) \(version) is currently the newest version available."
    }
}
#endif
