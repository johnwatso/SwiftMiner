import Foundation
import SwiftMinerCore
import WebKit

struct TwitchBrowserIntegrityIssuance: Sendable, Equatable {
    let token: String
    let expiresAt: Date
    let sdkCookieValue: String
    let cookieExpiresAt: Date
}

struct TwitchBrowserSDKCookie: Sendable, Equatable {
    let value: String
    let expiresAt: Date
}

@MainActor
protocol TwitchBrowserIntegrityIssuing: AnyObject {
    func issue(
        oauthToken: String,
        clientID: String,
        deviceID: String,
        previousCookie: TwitchBrowserSDKCookie?
    ) async throws -> TwitchBrowserIntegrityIssuance
}

@MainActor
protocol TwitchBrowserIntegrityValidating: AnyObject {
    func validate(
        account: Account,
        browser: TwitchAuthenticationContext.Browser,
        issuance: TwitchBrowserIntegrityIssuance
    ) async throws
}

/// Proves a rotated session against Twitch before it replaces the last working generation.
@MainActor
final class TwitchBrowserIntegrityValidator: TwitchBrowserIntegrityValidating {
    enum ValidationError: LocalizedError {
        case identity
        case dashboard
        case inventory

        var errorDescription: String? {
            switch self {
            case .identity:
                return "Twitch did not confirm the Operator identity"
            case .dashboard:
                return "Twitch rejected the rotated session for the Drops dashboard"
            case .inventory:
                return "Twitch rejected the rotated session for the Drops inventory"
            }
        }
    }

    private struct Identity: Decodable {
        let clientID: String
        let userID: String

        private enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
            case userID = "user_id"
        }
    }

    func validate(
        account: Account,
        browser: TwitchAuthenticationContext.Browser,
        issuance: TwitchBrowserIntegrityIssuance
    ) async throws {
        var identityRequest = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/validate")!)
        identityRequest.timeoutInterval = 30
        identityRequest.setValue("OAuth \(account.accessToken)", forHTTPHeaderField: "Authorization")
        let (identityData, identityResponse) = try await URLSession.shared.data(for: identityRequest)
        guard (identityResponse as? HTTPURLResponse)?.statusCode == 200,
              let identity = try? JSONDecoder().decode(Identity.self, from: identityData),
              identity.clientID == browser.clientID,
              identity.userID == account.id else {
            throw ValidationError.identity
        }

        let dashboard = try await protectedQuery(
            .viewerDropsDashboard,
            account: account,
            browser: browser,
            integrityToken: issuance.token
        )
        guard GQLQuery.viewerDropsDashboard.responseSatisfiesContract(dashboard) else {
            throw ValidationError.dashboard
        }

        let inventory = try await protectedQuery(
            .inventory,
            account: account,
            browser: browser,
            integrityToken: issuance.token
        )
        guard GQLQuery.inventory.responseSatisfiesContract(inventory) else {
            throw ValidationError.inventory
        }
    }

    private func protectedQuery(
        _ query: GQLQuery,
        account: Account,
        browser: TwitchAuthenticationContext.Browser,
        integrityToken: String
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
        request.timeoutInterval = 30
        request.httpMethod = "POST"
        request.setValue("OAuth \(account.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(browser.clientID, forHTTPHeaderField: "Client-Id")
        request.setValue(integrityToken, forHTTPHeaderField: "Client-Integrity")
        request.setValue(browser.origin, forHTTPHeaderField: "Origin")
        request.setValue("\(browser.origin)/", forHTTPHeaderField: "Referer")
        request.setValue(browser.userAgent, forHTTPHeaderField: "User-Agent")
        if let value = browser.xDeviceID { request.setValue(value, forHTTPHeaderField: "X-Device-Id") }
        if let value = browser.deviceID { request.setValue(value, forHTTPHeaderField: "Device-ID") }
        if let value = browser.clientSessionID { request.setValue(value, forHTTPHeaderField: "Client-Session-Id") }
        if let value = browser.clientVersion { request.setValue(value, forHTTPHeaderField: "Client-Version") }
        if let value = browser.acceptLanguage { request.setValue(value, forHTTPHeaderField: "Accept-Language") }
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw query == .inventory ? ValidationError.inventory : ValidationError.dashboard
        }
        return data
    }
}

/// Issues Twitch browser integrity material in an app-owned WebKit data store.
///
/// WebKit blocks the SDK's cookie when it is a third-party resource on twitch.tv. The helper
/// view therefore uses k.twitchcdn.net as its top-level origin. It remains invisible and shares
/// only SwiftMiner's persistent browser store; Safari profiles are never opened or inspected.
@MainActor
final class TwitchBrowserIntegrityIssuer: TwitchBrowserIntegrityIssuing {
    static let dataStoreID = UUID(uuidString: "BC84D78C-5850-4C22-A462-0C52AD91F395")!

    private static let sdkOrigin = URL(string: "https://k.twitchcdn.net/")!
    private static let integritySDKURL =
        "https://k.twitchcdn.net/149e9513-01fa-4fb0-aad4-566afd725d1b/" +
        "2d206a39-8ed7-437e-a3be-862e0f06eea3/p.js"

    enum IssuanceError: Error {
        case pageUnavailable
        case sdkUnavailable
        case integrityUnavailable
        case missingSDKCookie
    }

    let dataStore: WKWebsiteDataStore

    init(dataStore: WKWebsiteDataStore? = nil) {
        self.dataStore = dataStore ?? WKWebsiteDataStore(forIdentifier: Self.dataStoreID)
    }

    func issue(
        oauthToken: String,
        clientID: String,
        deviceID: String,
        previousCookie: TwitchBrowserSDKCookie? = nil
    ) async throws -> TwitchBrowserIntegrityIssuance {
        if let previousCookie {
            guard previousCookie.expiresAt > Date(),
                  let cookie = HTTPCookie(properties: [
                    .domain: RemoteBrowserSessionBundle.sdkCookieDomain,
                    .path: "/",
                    .name: RemoteBrowserSessionBundle.sdkCookieName,
                    .value: previousCookie.value,
                    .secure: "TRUE",
                    .expires: previousCookie.expiresAt,
                  ]) else {
                throw IssuanceError.missingSDKCookie
            }
            await dataStore.httpCookieStore.setCookie(cookie)
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let integrityWebView = WKWebView(frame: .zero, configuration: configuration)
        integrityWebView.load(URLRequest(url: Self.sdkOrigin))
        try await waitForPageLoad(integrityWebView)

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
                "clientId": clientID,
                "authToken": oauthToken,
                "deviceId": deviceID,
                "sdkURL": Self.integritySDKURL,
            ],
            in: nil,
            contentWorld: .page
        )
        guard let result = raw as? [String: Any] else {
            throw IssuanceError.sdkUnavailable
        }
        if let failure = result["failure"] as? String {
            Logger.auth.warning("Browser integrity SDK failed with safe code: \(failure)")
            throw IssuanceError.sdkUnavailable
        }
        guard let status = result["status"] as? Int,
              status == 200,
              let body = result["body"] as? String,
              let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              let token = json["token"] as? String,
              !token.isEmpty else {
            if let status = result["status"] as? Int {
                Logger.auth.warning("Browser integrity issuance returned HTTP \(status)")
            }
            throw IssuanceError.integrityUnavailable
        }

        let expiryMilliseconds = json["expiration"] as? Double
            ?? (Date().timeIntervalSince1970 + 300) * 1_000
        let expiresAt = Date(timeIntervalSince1970: expiryMilliseconds / 1_000)
        guard expiresAt > Date() else { throw IssuanceError.integrityUnavailable }

        // The HTTP-only cookie reaches the native store shortly after fetch completion.
        try? await Task.sleep(for: .milliseconds(500))
        let cookies = await dataStore.httpCookieStore.allCookies()
        guard let sdkCookie = cookies.first(where: {
            $0.name == RemoteBrowserSessionBundle.sdkCookieName
                && $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    == RemoteBrowserSessionBundle.sdkCookieDomain
                && !$0.value.isEmpty
        }) else {
            let observedCookies = Set(cookies.map { "\($0.name)@\($0.domain)" })
                .sorted()
                .joined(separator: ", ")
            Logger.auth.warning(
                "Browser integrity SDK completed without its renewal cookie; observed cookie names/domains: \(observedCookies)"
            )
            throw IssuanceError.missingSDKCookie
        }

        return TwitchBrowserIntegrityIssuance(
            token: token,
            expiresAt: expiresAt,
            sdkCookieValue: sdkCookie.value,
            cookieExpiresAt: sdkCookie.expiresDate
                ?? expiresAt.addingTimeInterval(24 * 60 * 60)
        )
    }

    private func waitForPageLoad(
        _ webView: WKWebView,
        timeout: TimeInterval = 20
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        try? await Task.sleep(for: .milliseconds(300))
        while webView.isLoading, Date() < deadline {
            try Task.checkCancellation()
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard !webView.isLoading, webView.url?.host() == Self.sdkOrigin.host() else {
            throw IssuanceError.pageUnavailable
        }
        try? await Task.sleep(for: .seconds(1))
    }
}
