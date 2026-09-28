import Foundation
import SwiftMinerCore

struct OperatorSessionRenewalSchedule {
    static let integrityLeadTime: TimeInterval = 5 * 60
    static let cookieLeadTime: TimeInterval = 10 * 60
    static let maximumCheckInterval: TimeInterval = 5 * 60

    static func renewalDate(
        for browser: TwitchAuthenticationContext.Browser
    ) -> Date {
        min(
            browser.expiresAt.addingTimeInterval(-integrityLeadTime),
            browser.cookieExpiresAt.addingTimeInterval(-cookieLeadTime)
        )
    }

    static func nextCheckDelay(
        for browser: TwitchAuthenticationContext.Browser,
        now: Date
    ) -> TimeInterval {
        max(1, min(maximumCheckInterval, renewalDate(for: browser).timeIntervalSince(now)))
    }
}

/// Keeps the Operator's private browser seed rotating without involving remote miners.
///
/// Each successful SDK issuance is persisted before it is applied to the running engine. A
/// generation check prevents an old background result from overwriting a newer manual reconnect.
@MainActor
final class OperatorSessionRenewalCoordinator {
    enum Outcome: Equatable {
        case noBrowserOperator
        case notDue(Date)
        case renewed(generation: Int)
        case superseded
    }

    enum RenewalError: LocalizedError {
        case replayedIntegrity
        case staleSDKCookie
        case invalidGeneration

        var errorDescription: String? {
            switch self {
            case .replayedIntegrity:
                return "Twitch returned an existing or non-advancing integrity token"
            case .staleSDKCookie:
                return "Twitch did not advance the browser renewal cookie"
            case .invalidGeneration:
                return "The browser session generation can no longer be incremented"
            }
        }
    }

    private weak var minerManager: MinerManager?
    private let issuer: any TwitchBrowserIntegrityIssuing
    private let validator: any TwitchBrowserIntegrityValidating
    private var loopTask: Task<Void, Never>?

    init(
        minerManager: MinerManager,
        issuer: any TwitchBrowserIntegrityIssuing = TwitchBrowserIntegrityIssuer(),
        validator: any TwitchBrowserIntegrityValidating = TwitchBrowserIntegrityValidator()
    ) {
        self.minerManager = minerManager
        self.issuer = issuer
        self.validator = validator
    }

    func start() {
        guard loopTask == nil else { return }
        loopTask = makeLoopTask()
    }

    /// Re-evaluate immediately after an account is added, removed, or manually reconnected.
    func accountCollectionDidChange() {
        loopTask?.cancel()
        loopTask = makeLoopTask()
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    @discardableResult
    func renewNowIfNeeded(
        now: Date = Date(),
        force: Bool = false
    ) async throws -> Outcome {
        guard let minerManager else { return .noBrowserOperator }
        let accounts = try await minerManager.tokenStore.loadAllAccounts()
        guard let account = accounts.first(where: { account in
            guard account.isOperator, case .browser = account.authenticationContext else {
                return false
            }
            return true
        }), case .browser(let browser) = account.authenticationContext else {
            return .noBrowserOperator
        }

        let renewalDate = OperatorSessionRenewalSchedule.renewalDate(for: browser)
        guard force || renewalDate <= now else { return .notDue(renewalDate) }
        guard browser.generation < Int.max else { throw RenewalError.invalidGeneration }

        let issuance = try await issuer.issue(
            oauthToken: account.accessToken,
            clientID: browser.clientID,
            deviceID: browser.xDeviceID ?? browser.deviceID ?? "",
            previousCookie: TwitchBrowserSDKCookie(
                value: browser.sdkCookieValue,
                expiresAt: browser.cookieExpiresAt
            )
        )
        try Task.checkCancellation()

        guard issuance.token != browser.integrityToken,
              issuance.expiresAt > max(now.addingTimeInterval(30), browser.expiresAt) else {
            Logger.auth.warning(
                "Rejected Operator integrity renewal: token changed=\(issuance.token != browser.integrityToken), previous expiry=\(browser.expiresAt), new expiry=\(issuance.expiresAt)"
            )
            throw RenewalError.replayedIntegrity
        }
        guard issuance.cookieExpiresAt > max(browser.cookieExpiresAt, issuance.expiresAt) else {
            Logger.auth.warning(
                "Rejected Operator cookie renewal: previous expiry=\(browser.cookieExpiresAt), new expiry=\(issuance.cookieExpiresAt), integrity expiry=\(issuance.expiresAt)"
            )
            throw RenewalError.staleSDKCookie
        }

        // A structurally plausible SDK response is not enough. Prove that Twitch accepts the
        // candidate for both protected Drops surfaces before replacing the working generation.
        try await validator.validate(account: account, browser: browser, issuance: issuance)
        try Task.checkCancellation()

        // Reload immediately before saving. A manual reconnect can replace the account while
        // WebKit is issuing proof; its higher generation must always win.
        guard let latest = try await minerManager.tokenStore.loadAccount(twitchUserId: account.id),
              latest.isOperator,
              latest.accessToken == account.accessToken,
              case .browser(let latestBrowser) = latest.authenticationContext,
              latestBrowser.generation == browser.generation else {
            return .superseded
        }

        let renewedBrowser = TwitchAuthenticationContext.Browser(
            schemaVersion: latestBrowser.schemaVersion,
            clientID: latestBrowser.clientID,
            origin: latestBrowser.origin,
            userAgent: latestBrowser.userAgent,
            xDeviceID: latestBrowser.xDeviceID,
            deviceID: latestBrowser.deviceID,
            clientSessionID: latestBrowser.clientSessionID,
            clientVersion: latestBrowser.clientVersion,
            acceptLanguage: latestBrowser.acceptLanguage,
            integrityToken: issuance.token,
            capturedAt: now,
            expiresAt: issuance.expiresAt,
            sdkCookieValue: issuance.sdkCookieValue,
            cookieExpiresAt: issuance.cookieExpiresAt,
            generation: latestBrowser.generation + 1
        )
        let updatedAccount = Account(
            id: latest.id,
            username: latest.username,
            nickname: latest.nickname,
            ownerDiscordId: latest.ownerDiscordId,
            accessToken: latest.accessToken,
            refreshToken: latest.refreshToken,
            tokenExpiry: latest.tokenExpiry,
            scopes: latest.scopes,
            isOperator: true,
            authenticationContext: .browser(renewedBrowser)
        )

        try Task.checkCancellation()
        try await minerManager.tokenStore.save(account: updatedAccount)
        if let miner = minerManager.miners.first(where: { $0.accountId == latest.id }),
           let engine = minerManager.getEngine(minerId: miner.id) {
            await engine.setAccount(updatedAccount)
        }
        Logger.auth.info(
            "Rotated Operator browser integrity seed to generation \(renewedBrowser.generation); next integrity expiry is \(renewedBrowser.expiresAt)"
        )
        return .renewed(generation: renewedBrowser.generation)
    }

    private func makeLoopTask() -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            guard let self else { return }
            var failureCount = 0
            while !Task.isCancelled {
                let delay: TimeInterval
                do {
                    let outcome = try await renewNowIfNeeded()
                    failureCount = 0
                    delay = try await delayAfter(outcome)
                } catch is CancellationError {
                    return
                } catch {
                    failureCount += 1
                    delay = min(30 * 60, 60 * pow(2, Double(min(failureCount - 1, 5))))
                    Logger.auth.error(
                        "Operator browser seed rotation failed; retrying in \(Int(delay))s: \(error.localizedDescription)"
                    )
                }

                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
            }
        }
    }

    private func delayAfter(_ outcome: Outcome) async throws -> TimeInterval {
        switch outcome {
        case .notDue(let date):
            return max(1, min(
                OperatorSessionRenewalSchedule.maximumCheckInterval,
                date.timeIntervalSinceNow
            ))
        case .renewed:
            guard let minerManager,
                  let account = try await minerManager.tokenStore.loadAllAccounts().first(where: \.isOperator),
                  case .browser(let browser) = account.authenticationContext else {
                return OperatorSessionRenewalSchedule.maximumCheckInterval
            }
            return OperatorSessionRenewalSchedule.nextCheckDelay(for: browser, now: Date())
        case .noBrowserOperator, .superseded:
            return OperatorSessionRenewalSchedule.maximumCheckInterval
        }
    }
}
