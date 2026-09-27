#if DEBUG
import AppKit
import SwiftMinerCore
import SwiftUI
import WebKit

/// Debug-only spike for the September 2026 Twitch sign-in lockdown.
///
/// Twitch stopped accepting device-code sign-in for the Android client on 2026-09-18, and
/// protected queries (the drops dashboard, campaign details, claiming) now need a
/// `Client-Integrity` token that plain HTTP issuance no longer satisfies. Other miners
/// found that a token issued inside a real browser, with Twitch's own SDK and its
/// `KP_UIDz-ssn` cookie present, is accepted.
///
/// This probe answers the question the fix depends on: does an embedded `WKWebView`
/// count as a real browser to Twitch? The person signs in to twitch.tv in the window,
/// then "Run Checks":
///
/// 1. reads the web session cookies from the probe's own data store,
/// 2. validates the web `auth-token`,
/// 3. asks for an integrity token from inside the page, so Twitch's SDK can attach its proof,
/// 4. runs `ViewerDropsDashboard` and `Inventory` twice: replayed from `URLSession` (how the
///    miner would work) and from inside the page (the browser's own request).
///
/// Credential values are never written to the report — only presence, lengths and expiry —
/// so the report can be copied into an issue or a chat safely. The probe keeps its own
/// persistent website data store, separate from Safari and from SwiftMiner's accounts.
@MainActor
final class TwitchWebSessionProbe: NSObject, ObservableObject {
    static let shared = TwitchWebSessionProbe()

    /// Twitch's web client ID — the one twitch.tv itself uses and issues `auth-token` to.
    nonisolated static let webClientID = "kimne78kx3ncx6brgo4mv6wki5h1ko"

    /// Fixed so the probe's sign-in survives relaunches of the Debug build.
    private static let dataStoreID = UUID(uuidString: "6D1B5C2E-7A43-4F0B-9C1E-2B5E8F3A4D71")!

    @Published private(set) var report: [String] = []
    @Published private(set) var isRunning = false

    let webView: WKWebView
    private let dataStore: WKWebsiteDataStore
    private var window: NSWindow?

    override init() {
        dataStore = WKWebsiteDataStore(forIdentifier: Self.dataStoreID)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
    }

    // MARK: - Window

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1100, height: 860),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Twitch Web Session Probe"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: TwitchWebSessionProbeView(probe: self))
            window.center()
            self.window = window
        }
        if webView.url == nil {
            loadTwitch(path: "/login")
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func loadTwitch(path: String = "/") {
        guard let url = URL(string: "https://www.twitch.tv\(path)") else { return }
        webView.load(URLRequest(url: url))
    }

    /// Signs the probe out by deleting everything in its own data store.
    func clearSession() async {
        await dataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        )
        report = ["Probe session cleared. Sign in again to re-run."]
        loadTwitch(path: "/login")
    }

    func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.joined(separator: "\n"), forType: .string)
    }

    // MARK: - Checks

    func runChecks() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        report = []

        let macOS = ProcessInfo.processInfo.operatingSystemVersionString
        note("Twitch Web Session Probe · \(Date().formatted(.iso8601)) · macOS \(macOS)")

        // 1. Session cookies.
        let cookies = await dataStore.httpCookieStore.allCookies()
            .filter { $0.domain.hasSuffix("twitch.tv") || $0.domain.hasSuffix("twitchcdn.net") }
        let authCookie = cookies.first { $0.name == "auth-token" }
        let deviceCookie = cookies.first { $0.name == "unique_id" }
        let sdkCookies = cookies.filter { $0.name.hasPrefix("KP_UID") }
        note("")
        note("1. Cookies (\(cookies.count) Twitch cookies in the probe store)")
        note("   auth-token: \(Self.describe(authCookie))")
        note("   unique_id (device ID): \(Self.describe(deviceCookie))")
        if sdkCookies.isEmpty {
            note("   KP_UID* SDK cookie: missing")
        } else {
            for cookie in sdkCookies {
                note("   \(cookie.name): \(Self.describe(cookie))")
            }
        }
        guard let authToken = authCookie?.value, !authToken.isEmpty else {
            note("   ✗ Not signed in. Sign in to twitch.tv in the window above, then run again.")
            return
        }
        let deviceID = deviceCookie?.value ?? ""

        // Twitch's SDK only runs on www.twitch.tv; make sure the page is there and settled.
        if webView.url?.host() != "www.twitch.tv" || webView.url?.path().hasPrefix("/login") == true {
            loadTwitch(path: "/drops/inventory")
        }
        await waitForPageLoad()
        let userAgent = (try? await webView.evaluateJavaScript("navigator.userAgent") as? String) ?? ""
        note("   Page: \(webView.url?.absoluteString ?? "none")")
        note("   User-Agent: \(userAgent)")

        // 2. Token validation.
        note("")
        note("2. Validate auth-token")
        let validation = await validate(token: authToken)
        note("   \(validation)")

        // 3. Integrity from inside the page.
        note("")
        note("3. Integrity token from the page (Twitch SDK attaches its proof)")
        let integrityResult = await pageFetch(
            url: "https://gql.twitch.tv/integrity",
            body: nil,
            authToken: authToken,
            deviceID: deviceID,
            integrity: nil
        )
        var integrityToken: String?
        switch integrityResult {
        case .failure(let message):
            note("   ✗ \(message)")
        case .success(let status, let body):
            let parsed = Self.parseIntegrity(body)
            integrityToken = parsed.token
            note("   HTTP \(status) · \(parsed.summary)")
        }

        // 4. Protected queries, both ways.
        let queries: [(String, GQLQuery)] = [
            ("ViewerDropsDashboard", .viewerDropsDashboard),
            ("Inventory", .inventory),
        ]
        for (label, query) in queries {
            let body = Self.persistedQueryBody(for: query)
            note("")
            note("4. \(label)")

            let replay = await urlSessionGQL(
                body: body,
                authToken: authToken,
                deviceID: deviceID,
                userAgent: userAgent,
                integrity: integrityToken
            )
            note("   A. URLSession replay: \(Self.summarize(replay, query: query))")

            let inPage = await pageFetch(
                url: "https://gql.twitch.tv/gql",
                body: body,
                authToken: authToken,
                deviceID: deviceID,
                integrity: integrityToken
            )
            note("   B. From the page:     \(Self.summarize(inPage, query: query))")
        }

        note("")
        note("Done. Copy this report and send it back — it contains no token or cookie values.")
    }

    // MARK: - Requests

    enum FetchResult {
        case success(status: Int, body: String)
        case failure(String)
    }

    private func validate(token: String) async -> String {
        var request = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/validate")!)
        request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return "✗ HTTP \(status), unreadable response"
            }
            let clientID = json["client_id"] as? String ?? "?"
            let login = json["login"] as? String ?? "?"
            let expiresIn = json["expires_in"] as? Int ?? -1
            let scopes = (json["scopes"] as? [String])?.count ?? 0
            let clientLabel = clientID == Self.webClientID ? "web client" : "client \(clientID)"
            return "\(status == 200 ? "✓" : "✗") HTTP \(status) · \(clientLabel) · login \(login) · expires_in \(expiresIn)s · \(scopes) scopes"
        } catch {
            return "✗ \(error.localizedDescription)"
        }
    }

    private func urlSessionGQL(
        body: String,
        authToken: String,
        deviceID: String,
        userAgent: String,
        integrity: String?
    ) async -> FetchResult {
        var request = URLRequest(url: URL(string: "https://gql.twitch.tv/gql")!)
        request.httpMethod = "POST"
        request.setValue("OAuth \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.webClientID, forHTTPHeaderField: "Client-Id")
        request.setValue("text/plain;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.twitch.tv", forHTTPHeaderField: "Origin")
        request.setValue("https://www.twitch.tv/", forHTTPHeaderField: "Referer")
        if !userAgent.isEmpty { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        if !deviceID.isEmpty { request.setValue(deviceID, forHTTPHeaderField: "X-Device-Id") }
        if let integrity { request.setValue(integrity, forHTTPHeaderField: "Client-Integrity") }
        request.httpBody = Data(body.utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return .success(status: status, body: String(decoding: data, as: UTF8.self))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// Runs `fetch` in the page's own JavaScript world, so any request hooks Twitch's SDK
    /// installs on `window.fetch` apply exactly as they do for twitch.tv's own requests.
    private func pageFetch(
        url: String,
        body: String?,
        authToken: String,
        deviceID: String,
        integrity: String?
    ) async -> FetchResult {
        let script = """
        const headers = { 'Client-Id': clientId, 'Authorization': 'OAuth ' + authToken };
        if (deviceId) { headers['X-Device-Id'] = deviceId; }
        if (integrity) { headers['Client-Integrity'] = integrity; }
        const init = { method: 'POST', headers: headers };
        if (body) { init.body = body; headers['Content-Type'] = 'text/plain;charset=UTF-8'; }
        try {
            const response = await fetch(url, init);
            return JSON.stringify({ status: response.status, body: await response.text() });
        } catch (error) {
            return JSON.stringify({ status: 0, body: '', error: String(error) });
        }
        """
        do {
            let raw = try await webView.callAsyncJavaScript(
                script,
                arguments: [
                    "url": url,
                    "body": body ?? "",
                    "clientId": Self.webClientID,
                    "authToken": authToken,
                    "deviceId": deviceID,
                    "integrity": integrity ?? "",
                ],
                in: nil,
                contentWorld: .page
            )
            guard let text = raw as? String,
                  let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                return .failure("page returned no result")
            }
            if let error = json["error"] as? String {
                return .failure("page fetch threw: \(error)")
            }
            return .success(status: json["status"] as? Int ?? 0, body: json["body"] as? String ?? "")
        } catch {
            return .failure("script failed: \(error.localizedDescription)")
        }
    }

    private func waitForPageLoad(timeout: TimeInterval = 20) async {
        let deadline = Date().addingTimeInterval(timeout)
        try? await Task.sleep(for: .milliseconds(300))
        while webView.isLoading, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
        // Give the page's scripts, including Twitch's SDK, a moment to initialise.
        try? await Task.sleep(for: .seconds(2))
    }

    private func note(_ line: String) {
        report.append(line)
    }

    // MARK: - Formatting (never prints credential values)

    nonisolated static func describe(_ cookie: HTTPCookie?) -> String {
        guard let cookie else { return "missing" }
        let expiry = cookie.expiresDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "session"
        return "present · \(cookie.value.count) chars · domain \(cookie.domain) · expires \(expiry)"
    }

    nonisolated static func persistedQueryBody(for query: GQLQuery) -> String {
        let hash = TwitchQueryHashStore.standard.resolution(for: query).hash
        let object: [String: Any] = [
            "operationName": query.rawValue,
            "variables": ["fetchRewardCampaigns": false],
            "extensions": ["persistedQuery": ["version": 1, "sha256Hash": hash]],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads the integrity response. The token is a PASETO `v4.public` token whose payload
    /// is plain JSON; `is_bad_bot` is Twitch's own verdict on the session.
    nonisolated static func parseIntegrity(_ body: String) -> (token: String?, summary: String) {
        guard let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else {
            return (nil, "✗ unreadable response: \(body.prefix(160))")
        }
        guard let token = json["token"] as? String, !token.isEmpty else {
            let message = json["message"] as? String ?? json["error"] as? String ?? "\(json.keys.sorted())"
            return (nil, "✗ no token · \(message)")
        }
        var parts = ["✓ token issued (\(token.count) chars)"]
        if let expiration = json["expiration"] as? Double {
            let minutes = Int((expiration / 1000 - Date().timeIntervalSince1970) / 60)
            parts.append("valid ~\(minutes) min")
        }
        if let payload = decodePasetoPayload(token) {
            if let badBot = payload["is_bad_bot"] { parts.append("is_bad_bot=\(badBot)") }
            if let clientID = payload["client_id"] as? String {
                parts.append(clientID == webClientID ? "bound to web client" : "bound to client \(clientID)")
            }
        }
        return (token, parts.joined(separator: " · "))
    }

    nonisolated static func decodePasetoPayload(_ token: String) -> [String: Any]? {
        let pieces = token.split(separator: ".")
        guard pieces.count >= 3 else { return nil }
        var base64 = String(pieces[2])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64) else { return nil }
        // v4.public payloads carry a 64-byte Ed25519 signature after the JSON message.
        let message = data.count > 64 ? data.dropLast(64) : data
        return try? JSONSerialization.jsonObject(with: Data(message)) as? [String: Any]
    }

    nonisolated static func summarize(_ result: FetchResult, query: GQLQuery) -> String {
        switch result {
        case .failure(let message):
            return "✗ \(message)"
        case .success(let status, let body):
            guard let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else {
                return "✗ HTTP \(status), unreadable: \(body.prefix(160))"
            }
            if let errors = json["errors"] as? [[String: Any]], !errors.isEmpty {
                let messages = errors.compactMap { $0["message"] as? String }.joined(separator: "; ")
                return "✗ HTTP \(status) · errors: \(messages)"
            }
            if let error = json["error"] as? String {
                return "✗ HTTP \(status) · \(error): \(json["message"] as? String ?? "")"
            }
            let user = (json["data"] as? [String: Any])?["currentUser"] as? [String: Any]
            switch query {
            case .viewerDropsDashboard:
                guard let user else { return "✗ HTTP \(status) · currentUser null" }
                guard let campaigns = user["dropCampaigns"] as? [Any] else {
                    return "✗ HTTP \(status) · dropCampaigns null (integrity not accepted)"
                }
                return "✓ HTTP \(status) · \(campaigns.count) campaigns"
            case .inventory:
                guard let inventory = user?["inventory"] as? [String: Any] else {
                    return "✗ HTTP \(status) · inventory null"
                }
                let inProgress = (inventory["dropCampaignsInProgress"] as? [Any])?.count ?? 0
                let events = (inventory["gameEventDrops"] as? [Any])?.count ?? 0
                return "✓ HTTP \(status) · \(inProgress) in progress · \(events) claimed"
            default:
                return "HTTP \(status)"
            }
        }
    }
}

// MARK: - View

private struct TwitchWebSessionProbeView: View {
    @ObservedObject var probe: TwitchWebSessionProbe

    var body: some View {
        VStack(spacing: 0) {
            ProbeWebView(webView: probe.webView)
                .frame(minHeight: 420)

            Divider()

            HStack(spacing: 10) {
                Button {
                    Task { await probe.runChecks() }
                } label: {
                    Label(probe.isRunning ? "Running…" : "Run Checks", systemImage: "checkmark.shield")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(probe.isRunning)

                Button("Copy Report") { probe.copyReport() }
                    .disabled(probe.report.isEmpty)

                Spacer()

                Button("Twitch Home") { probe.loadTwitch() }
                Button("Clear Session", role: .destructive) {
                    Task { await probe.clearSession() }
                }
                .disabled(probe.isRunning)
            }
            .padding(12)

            ScrollView {
                Text(probe.report.isEmpty
                     ? "Sign in to Twitch above, then press Run Checks."
                     : probe.report.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(minHeight: 240)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

private struct ProbeWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#endif
