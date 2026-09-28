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

    private static let dataStoreID = UUID(uuidString: "BC84D78C-5850-4C22-A462-0C52AD91F395")!
    private static let webClientID = TwitchClientIDs.web

    private(set) var state: State = .idle
    let webView: WKWebView

    private let dataStore: WKWebsiteDataStore
    private var verificationTask: Task<Void, Never>?

    init() {
        dataStore = WKWebsiteDataStore(forIdentifier: Self.dataStoreID)
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
        var cookies = await dataStore.httpCookieStore.allCookies()
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

        let integrity = try await fetchIntegrityInPage(
            oauthToken: authCookie.value,
            deviceID: deviceID
        )

        // The SDK cookie is normally written by the integrity request, so refresh the store
        // after that request rather than trusting the snapshot taken before it.
        cookies = await dataStore.httpCookieStore.allCookies()
        guard let sdkCookie = cookies.first(where: {
            $0.name == RemoteBrowserSessionBundle.sdkCookieName
                && $0.domain.hasSuffix("twitchcdn.net")
                && !$0.value.isEmpty
        }) else {
            throw LoginError.missingSDKCookie
        }

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
        // WebKit represents a browser-session cookie with no expiresDate. Its real lifetime is
        // the owned persistent data store, so use the OAuth revalidation window as a conservative
        // renewal horizon rather than pretending the cookie has already expired.
        let cookieExpiry = sdkCookie.expiresDate ?? now.addingTimeInterval(advertisedLifetime)
        let context = TwitchAuthenticationContext.browser(.init(
            clientID: Self.webClientID,
            origin: TwitchClientIDs.webOrigin,
            userAgent: userAgent,
            xDeviceID: deviceID,
            acceptLanguage: acceptLanguage,
            integrityToken: integrity.token,
            capturedAt: now,
            expiresAt: integrity.expiresAt,
            sdkCookieValue: sdkCookie.value,
            cookieExpiresAt: cookieExpiry,
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

    private func fetchIntegrityInPage(
        oauthToken: String,
        deviceID: String
    ) async throws -> (token: String, expiresAt: Date) {
        let result = try await pageFetch(
            url: "https://gql.twitch.tv/integrity",
            body: nil,
            oauthToken: oauthToken,
            deviceID: deviceID,
            integrityToken: nil
        )
        guard result.status == 200 || result.status == 429,
              let json = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any],
              let token = json["token"] as? String,
              !token.isEmpty else {
            throw LoginError.integrityUnavailable
        }
        let expiryMilliseconds = json["expiration"] as? Double
            ?? (Date().timeIntervalSince1970 + 300) * 1_000
        let expiresAt = Date(timeIntervalSince1970: expiryMilliseconds / 1_000)
        guard expiresAt > Date() else { throw LoginError.integrityUnavailable }
        return (token, expiresAt)
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

    private func pageFetch(
        url: String,
        body: String?,
        oauthToken: String,
        deviceID: String,
        integrityToken: String?
    ) async throws -> (status: Int, data: Data) {
        let script = """
        const headers = { 'Client-Id': clientId, 'Authorization': 'OAuth ' + authToken };
        if (deviceId) headers['X-Device-Id'] = deviceId;
        if (integrity) headers['Client-Integrity'] = integrity;
        const init = { method: 'POST', headers };
        if (body) { init.body = body; headers['Content-Type'] = 'application/json; charset=UTF-8'; }
        const response = await fetch(url, init);
        return JSON.stringify({ status: response.status, body: await response.text() });
        """
        let raw = try await webView.callAsyncJavaScript(
            script,
            arguments: [
                "url": url,
                "body": body ?? "",
                "clientId": Self.webClientID,
                "authToken": oauthToken,
                "deviceId": deviceID,
                "integrity": integrityToken ?? "",
            ],
            in: nil,
            contentWorld: .page
        )
        guard let text = raw as? String,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let status = object["status"] as? Int,
              let body = object["body"] as? String else {
            throw LoginError.pageUnavailable
        }
        return (status, Data(body.utf8))
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
