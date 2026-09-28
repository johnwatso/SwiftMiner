import Foundation
import SwiftMinerCore

struct OperatorSessionRenewalSchedule {
    static let integrityLeadTime: TimeInterval = 5 * 60
    static let cookieLeadTime: TimeInterval = 10 * 60
    static let maximumCheckInterval: TimeInterval = 5 * 60

    /// Renews ahead of the integrity token's expiry, and ahead of the SDK cookie's expiry
    /// while renewing might still extend it. Twitch often leaves the cookie's expiry fixed; a
    /// generation captured inside the cookie's lead window has already tried, so chasing that
    /// deadline again would re-run WebKit every check until the cookie lapsed.
    static func renewalDate(
        for browser: TwitchAuthenticationContext.Browser
    ) -> Date {
        let integrityDeadline = browser.expiresAt.addingTimeInterval(-integrityLeadTime)
        let cookieDeadline = browser.cookieExpiresAt.addingTimeInterval(-cookieLeadTime)
        guard cookieDeadline > browser.capturedAt else { return integrityDeadline }
        return min(integrityDeadline, cookieDeadline)
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
        case expiredSDKCookie
        case invalidGeneration

        var errorDescription: String? {
            switch self {
            case .replayedIntegrity:
                return "Twitch returned an existing or non-advancing integrity token"
            case .expiredSDKCookie:
                return "The Operator's Twitch browser session has expired. Choose Reconnect Twitch on the Operator and sign in again"
            case .invalidGeneration:
                return "The browser session generation can no longer be incremented"
            }
        }
    }

    /// A rejected token asks for renewal from every request that carried it; one forced
    /// renewal per window is enough.
    static let rejectionRenewalInterval: TimeInterval = 2 * 60

    private weak var minerManager: MinerManager?
    private let issuer: any TwitchBrowserIntegrityIssuing
    private let validator: any TwitchBrowserIntegrityValidating
    private var loopTask: Task<Void, Never>?
    private var rejectionObserver: NSObjectProtocol?
    private var lastRejectionRenewalAt: Date?
    /// Scheduled and rejection-driven renewals share the one WebKit issuer, so only one runs.
    private var isRenewing = false

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
        rejectionObserver = NotificationCenter.default.addObserver(
            forName: TwitchAPIClient.integrityRejectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let accountId = notification.userInfo?["accountId"] as? String
            Task { @MainActor [weak self] in
                await self?.integrityWasRejected(accountId: accountId)
            }
        }
    }

    /// Re-evaluate immediately after an account is added, removed, or manually reconnected.
    func accountCollectionDidChange() {
        loopTask?.cancel()
        loopTask = makeLoopTask()
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        if let rejectionObserver {
            NotificationCenter.default.removeObserver(rejectionObserver)
        }
        rejectionObserver = nil
    }

    /// Twitch refused the Operator's current integrity token before its scheduled renewal.
    /// Waiting for the schedule left the Operator unable to read the Drops dashboard for
    /// hours, so renew now — at most once per ``rejectionRenewalInterval``.
    func integrityWasRejected(accountId: String?, now: Date = Date()) async {
        guard let operatorMiner = browserOperatorMiner(),
              accountId == nil || accountId == operatorMiner.accountId else { return }
        if let lastRejectionRenewalAt,
           now.timeIntervalSince(lastRejectionRenewalAt) < Self.rejectionRenewalInterval {
            return
        }
        lastRejectionRenewalAt = now
        do {
            // A successful renewal logs itself; a non-browser Operator has nothing to renew.
            _ = try await renewNowIfNeeded(force: true)
        } catch {
            logToOperator("[Operator session] Twitch rejected the browser security check and renewing it failed: \(error.localizedDescription). Retrying automatically.")
        }
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
        // A renewal already in flight will apply a newer generation; this one would only be
        // superseded by it.
        guard !isRenewing else { return .superseded }
        isRenewing = true
        defer { isRenewing = false }

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
        // Twitch commonly returns the same SDK cookie with the same expiry. That is a normal
        // renewal, not a stale one: requiring the expiry to advance discarded every working
        // renewal and left the Operator unable to read the Drops dashboard for hours. The
        // validator below still proves the new integrity token against Twitch. Only a cookie
        // that can no longer seed the next renewal is refused.
        guard issuance.cookieExpiresAt > now.addingTimeInterval(60) else {
            Logger.auth.warning(
                "Rejected Operator cookie renewal: cookie expiry=\(issuance.cookieExpiresAt)"
            )
            throw RenewalError.expiredSDKCookie
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
            // A miner blocked by the rejected token would otherwise wait for its next
            // scheduled scan, minutes away, before noticing the session works again.
            if miner.status == .error || miner.workerState == .failed {
                await engine.forceRefresh()
            }
        }
        Logger.auth.info(
            "Rotated Operator browser integrity seed to generation \(renewedBrowser.generation); next integrity expiry is \(renewedBrowser.expiresAt)"
        )
        logToOperator(
            "[Operator session] Renewed browser security check (generation \(renewedBrowser.generation)); valid until \(renewedBrowser.expiresAt.formatted(date: .omitted, time: .shortened))"
        )
        return .renewed(generation: renewedBrowser.generation)
    }

    private func browserOperatorMiner() -> MinerManager.ManagedMiner? {
        minerManager?.miners.first { $0.isOperator }
    }

    /// Renewal runs outside the engine, so without this its outcome reached only the Xcode
    /// console and an overnight failure left nothing in the Operator's Activity Log.
    private func logToOperator(_ message: String) {
        guard let minerManager, let miner = browserOperatorMiner() else { return }
        minerManager.onLogMessage?(miner.id, message)
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
                    logToOperator(
                        "[Operator session] Renewal failed (attempt \(failureCount)): \(error.localizedDescription). Retrying in \(Int(delay / 60)) min."
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
