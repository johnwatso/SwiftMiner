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
    private static let integritySDKURL = "https://k.twitchcdn.net/149e9513-01fa-4fb0-aad4-566afd725d1b/2d206a39-8ed7-437e-a3be-862e0f06eea3/p.js"

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

        // WebKit can publish an HTTP-only cross-site cookie to WKHTTPCookieStore a moment
        // after the JavaScript fetch has completed. Give that handoff a brief chance to settle.
        try? await Task.sleep(for: .milliseconds(500))
        cookies = await dataStore.httpCookieStore.allCookies()
        guard let sdkCookie = cookies.first(where: {
            $0.name == RemoteBrowserSessionBundle.sdkCookieName
                && $0.domain.hasSuffix("twitchcdn.net")
                && !$0.value.isEmpty
        }) else {
            let observedCookies = Set(cookies.map { "\($0.name)@\($0.domain)" })
                .sorted()
                .joined(separator: ", ")
            Logger.auth.warning(
                "Operator SDK bootstrap completed without its renewal cookie; observed cookie names/domains: \(observedCookies)"
            )
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
        // WebKit blocks third-party cookies even inside an app-owned WKWebView. Run the
        // official integrity SDK in a private helper view whose first-party origin matches
        // the SDK cookie, while sharing the same owned website data store. The visible
        // signed-in Twitch page and its credentials never leave SwiftMiner.
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let integrityWebView = WKWebView(frame: .zero, configuration: configuration)
        guard let sdkOrigin = URL(string: "https://k.twitchcdn.net/") else {
            throw LoginError.pageUnavailable
        }
        integrityWebView.load(URLRequest(url: sdkOrigin))
        await waitForPageLoad(integrityWebView)

        let script = """
        const headers = {
          'Client-Id': clientId,
          'Authorization': 'OAuth ' + authToken,
          'X-Device-Id': deviceId
        };

        return await new Promise(resolve => {
          let settled = false;
          let issued = false;
          let fallback;
          const deadline = setTimeout(
            () => finish({ failure: 'sdk_timeout' }),
            90000
          );
          const finish = value => {
            if (settled) return;
            settled = true;
            clearTimeout(deadline);
            if (fallback) clearTimeout(fallback);
            resolve(value);
          };
          const issue = async () => {
            if (issued || settled) return;
            issued = true;
            const controller = new AbortController();
            const fetchDeadline = setTimeout(() => controller.abort(), 30000);
            try {
              const response = await window.fetch('https://gql.twitch.tv/integrity', {
                method: 'POST',
                headers,
                body: null,
                credentials: 'omit',
                mode: 'cors',
                signal: controller.signal
              });
              finish({ status: response.status, body: await response.text() });
            } catch (_) {
              finish({ failure: 'issuance_fetch' });
            } finally {
              clearTimeout(fetchDeadline);
            }
          };
          const configure = () => {
            try {
              window.KPSDK.configure([{
                protocol: 'https:',
                method: 'POST',
                domain: 'gql.twitch.tv',
                path: '/integrity'
              }]);
              return true;
            } catch (_) {
              finish({ failure: 'sdk_configure' });
              return false;
            }
          };

          document.addEventListener('kpsdk-ready', issue, { once: true });
          if (window.KPSDK) {
            // Twitch may already have loaded the SDK before Connect was pressed. In that
            // case its ready event has also passed, so configure it and issue shortly after.
            if (configure()) fallback = setTimeout(issue, 250);
            return;
          }

          document.addEventListener('kpsdk-load', configure, { once: true });
          const sdkScript = document.createElement('script');
          sdkScript.onerror = () => finish({ failure: 'sdk_script' });
          sdkScript.src = sdkURL;
          (document.body || document.documentElement).appendChild(sdkScript);
        });
        """
        let raw = try await integrityWebView.callAsyncJavaScript(
            script,
            arguments: [
                "clientId": Self.webClientID,
                "authToken": oauthToken,
                "deviceId": deviceID,
                "sdkURL": Self.integritySDKURL,
            ],
            in: nil,
            contentWorld: .page
        )
        guard let result = raw as? [String: Any],
              let status = result["status"] as? Int,
              status == 200 || status == 429,
              let body = result["body"] as? String,
              let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
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

    private func waitForPageLoad(
        _ targetWebView: WKWebView? = nil,
        timeout: TimeInterval = 20
    ) async {
        let targetWebView = targetWebView ?? webView
        let deadline = Date().addingTimeInterval(timeout)
        try? await Task.sleep(for: .milliseconds(300))
        while targetWebView.isLoading, Date() < deadline {
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
