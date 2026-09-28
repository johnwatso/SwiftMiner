import AppKit
import Foundation
import Observation
import SwiftMinerCore
import SwiftUI
import WebKit

/// Owns the first-account Twitch browser session used to bootstrap a full-access operator.
///
/// The website data store belongs to SwiftMiner rather than Safari. Twitch receives the
/// password and two-factor prompts directly; SwiftMiner reads only the resulting Twitch
/// session material after the person explicitly chooses Connect This Account.
@MainActor
@Observable
final class OperatorBrowserLoginService {
    enum State: Equatable {
        case idle
        case signingIn
        case verifying
        case succeeded(Account)
        case failed(String)
    }

    private static let webClientID = TwitchClientIDs.web

    private(set) var state: State = .idle
    let webView: WKWebView

    private let dataStore: WKWebsiteDataStore
    private let integrityIssuer: TwitchBrowserIntegrityIssuer
    private var verificationTask: Task<Void, Never>?

    init() {
        let integrityIssuer = TwitchBrowserIntegrityIssuer()
        self.integrityIssuer = integrityIssuer
        dataStore = integrityIssuer.dataStore
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: configuration)
    }

    func start() {
        guard state == .idle || isFailed else { return }
        state = .signingIn
        guard webView.url == nil else { return }
        load(path: "/login")
    }

    func load(path: String = "/drops/inventory") {
        guard let url = URL(string: "https://www.twitch.tv\(path)") else { return }
        webView.load(URLRequest(url: url))
    }

    func connect() {
        guard state != .verifying else { return }
        verificationTask?.cancel()
        state = .verifying
        verificationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let account = try await buildValidatedAccount()
                guard !Task.isCancelled else { return }
                state = .succeeded(account)
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed(Self.friendlyMessage(for: error))
            }
            verificationTask = nil
        }
    }

    func retry() {
        verificationTask?.cancel()
        verificationTask = nil
        state = .signingIn
        load()
    }

    func cancel() {
        verificationTask?.cancel()
        verificationTask = nil
    }

    func clearSession() async {
        cancel()
        await dataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        )
        state = .signingIn
        load(path: "/login")
    }

    func fail(message: String) {
        cancel()
        state = .failed(message)
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    // MARK: - Validation

    private struct ValidatedIdentity: Decodable {
        let clientID: String
        let login: String
        let scopes: [String]
        let userID: String
        let expiresIn: Int

        private enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
            case login
            case scopes
            case userID = "user_id"
            case expiresIn = "expires_in"
        }
    }

    private enum LoginError: Error {
        case notSignedIn
        case missingDeviceIdentity
        case missingSDKCookie
        case invalidToken
        case wrongClient
        case integrityUnavailable
        case dashboardUnavailable
        case inventoryUnavailable
        case pageUnavailable
    }

    private func buildValidatedAccount() async throws -> Account {
        let cookies = await dataStore.httpCookieStore.allCookies()
        guard let authCookie = cookies.first(where: {
            $0.name == "auth-token" && $0.domain.hasSuffix("twitch.tv") && !$0.value.isEmpty
        }) else {
            throw LoginError.notSignedIn
        }

        if webView.url?.host() != "www.twitch.tv" || webView.url?.path().hasPrefix("/login") == true {
            load()
        }
        await waitForPageLoad()

        let userAgent = try await browserString("navigator.userAgent")
        let acceptLanguage = try? await browserString("navigator.language")
        let deviceID = cookies.first(where: {
            $0.name == "unique_id" && $0.domain.hasSuffix("twitch.tv")
        })?.value
        guard let deviceID, !deviceID.isEmpty else {
            throw LoginError.missingDeviceIdentity
        }

        let identity = try await validate(oauthToken: authCookie.value)
        guard identity.clientID == Self.webClientID else { throw LoginError.wrongClient }

        let integrity = try await integrityIssuer.issue(
            oauthToken: authCookie.value,
            clientID: Self.webClientID,
            deviceID: deviceID
        )

        let dashboard = try await protectedQuery(
            .viewerDropsDashboard,
            oauthToken: authCookie.value,
            integrityToken: integrity.token,
            deviceID: deviceID,
            userAgent: userAgent,
            acceptLanguage: acceptLanguage
        )
        guard GQLQuery.viewerDropsDashboard.responseSatisfiesContract(dashboard) else {
            throw LoginError.dashboardUnavailable
        }

        let inventory = try await protectedQuery(
            .inventory,
            oauthToken: authCookie.value,
            integrityToken: integrity.token,
            deviceID: deviceID,
            userAgent: userAgent,
            acceptLanguage: acceptLanguage
        )
        guard GQLQuery.inventory.responseSatisfiesContract(inventory) else {
            throw LoginError.inventoryUnavailable
        }

        let now = Date()
        let advertisedLifetime = identity.expiresIn > 0
            ? TimeInterval(identity.expiresIn)
            : 30 * 24 * 60 * 60
        let context = TwitchAuthenticationContext.browser(.init(
            clientID: Self.webClientID,
            origin: TwitchClientIDs.webOrigin,
            userAgent: userAgent,
            xDeviceID: deviceID,
            acceptLanguage: acceptLanguage,
            integrityToken: integrity.token,
            capturedAt: now,
            expiresAt: integrity.expiresAt,
            sdkCookieValue: integrity.sdkCookieValue,
            cookieExpiresAt: integrity.cookieExpiresAt,
            generation: 1
        ))

        return Account(
            id: identity.userID,
            username: identity.login,
            accessToken: authCookie.value,
            refreshToken: "",
            tokenExpiry: now.addingTimeInterval(advertisedLifetime),
            scopes: identity.scopes,
            isOperator: true,
            authenticationContext: context
        )
    }

    private func browserString(_ expression: String) async throws -> String {
        guard let value = try await webView.evaluateJavaScript(expression) as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LoginError.pageUnavailable
        }
        return value
    }

    private func validate(oauthToken: String) async throws -> ValidatedIdentity {
        var request = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/validate")!)
        request.setValue("OAuth \(oauthToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let identity = try? JSONDecoder().decode(ValidatedIdentity.self, from: data),
              !identity.userID.isEmpty,
              !identity.login.isEmpty else {
            throw LoginError.invalidToken
        }
        return identity
    }

    private func protectedQuery(
        _ query: GQLQuery,
        oauthToken: String,
        integrityToken: String,
        deviceID: String,
        userAgent: String,
        acceptLanguage: String?
    ) async throws -> Data {
        let body: [String: Any] = [
            "operationName": query.rawValue,
            "variables": ["fetchRewardCampaigns": false],
            "extensions": [
                "persistedQuery": [
                    "version": 1,
                    "sha256Hash": TwitchQueryHashStore.standard.resolution(for: query).hash,
                ],
            ],
        ]
        var request = URLRequest(url: URL(string: "https://gql.twitch.tv/gql")!)
        request.httpMethod = "POST"
        request.setValue("OAuth \(oauthToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.webClientID, forHTTPHeaderField: "Client-Id")
        request.setValue(integrityToken, forHTTPHeaderField: "Client-Integrity")
        request.setValue(deviceID, forHTTPHeaderField: "X-Device-Id")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(acceptLanguage ?? "en-US", forHTTPHeaderField: "Accept-Language")
        request.setValue(TwitchClientIDs.webOrigin, forHTTPHeaderField: "Origin")
        request.setValue("https://www.twitch.tv/", forHTTPHeaderField: "Referer")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode,
              (200 ... 299).contains(status) else {
            throw LoginError.integrityUnavailable
        }
        return data
    }

    private func waitForPageLoad(timeout: TimeInterval = 20) async {
        let deadline = Date().addingTimeInterval(timeout)
        try? await Task.sleep(for: .milliseconds(300))
        while webView.isLoading, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
        try? await Task.sleep(for: .seconds(2))
    }

    private static func friendlyMessage(for error: Error) -> String {
        switch error {
        case LoginError.notSignedIn:
            return "Sign in to Twitch in the window above, then choose Connect This Account."
        case LoginError.missingDeviceIdentity:
            return "Twitch did not finish creating this browser session. Reload Twitch and try again."
        case LoginError.missingSDKCookie:
            return "Twitch did not provide the browser integrity cookie needed for unattended renewal. Reload the Drops page and try again."
        case LoginError.invalidToken:
            return "Twitch did not accept this login. Sign out in the browser above and try again."
        case LoginError.wrongClient:
            return "This login was not issued to Twitch's web client, so SwiftMiner left it unchanged."
        case LoginError.integrityUnavailable:
            return "Twitch did not approve this browser session for protected Drops requests. Reload and try again."
        case LoginError.dashboardUnavailable:
            return "The login worked, but Twitch did not return the complete campaign dashboard. Nothing was saved."
        case LoginError.inventoryUnavailable:
            return "The login worked, but Twitch did not return this account's Drops inventory. Nothing was saved."
        case LoginError.pageUnavailable:
            return "The Twitch page was not ready. Wait for it to finish loading and try again."
        case TwitchBrowserIntegrityIssuer.IssuanceError.missingSDKCookie:
            return "Twitch did not provide the browser integrity cookie needed for unattended renewal. Reload the Drops page and try again."
        case TwitchBrowserIntegrityIssuer.IssuanceError.pageUnavailable:
            return "Twitch's integrity page was not ready. Wait a moment and try again."
        case TwitchBrowserIntegrityIssuer.IssuanceError.sdkUnavailable,
             TwitchBrowserIntegrityIssuer.IssuanceError.integrityUnavailable:
            return "Twitch did not approve this browser session for protected Drops requests. Reload and try again."
        default:
            return "The operator login could not be verified: \(error.localizedDescription)"
        }
    }
}

struct OperatorBrowserWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
