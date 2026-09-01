// Web dashboard and integrations panes of the Settings window.
import SwiftUI
import SwiftMinerCore
import SwiftMinerService
import AppKit
import UniformTypeIdentifiers

// MARK: - Integrations Settings

struct WebDashboardSettingsView: View {
    @Bindable var settings: Settings
    @Environment(NavigationModel.self) private var navigation
    @State private var showingInternetSetup = false
    @State private var showingLocalSetup = false
    @State private var draftLocalUsername = ""
    @State private var draftLocalPassword = ""
    @State private var showLocalPassword = false
    @State private var localAccessErrorMessage: String?
    @State private var isRegisteringTunnel = false
    @State private var tunnelRegistrationMessage: String?
    @State private var tunnelRegistrationSucceeded = false
    @State private var swiftBotTunnelInfo: SwiftBotTunnelInfo?
    @State private var isFetchingTunnelInfo = false
    @State private var showingTwitchOAuthSetup = false
    @State private var draftTwitchClientID = ""
    @State private var draftTwitchClientSecret = ""

    /// Internet access (Twitch sign-in over a tunnel) is only offered when the
    /// Discord/SwiftBot integration is on or the host mines for several people —
    /// the cases where letting friends self-serve actually matters.
    private var internetEligible: Bool {
        settings.swiftBotEnabled || navigation.configuredMinerCount > 1
    }

    private var swiftBotIsConnected: Bool {
        settings.swiftBotEnabled && navigation.swiftBotState == .connected
    }

    private var swiftBotUnavailableReason: String {
        switch navigation.swiftBotState {
        case .connected:
            return "SwiftBot is connected"
        case .disconnected:
            return "SwiftBot is offline"
        case .unpaired:
            return "SwiftBot is reachable but not paired"
        case .notConfigured:
            return "SwiftBot has no valid endpoint"
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable Web Dashboard", isOn: $settings.webDashboardEnabled)
                SettingsSecondaryText("A browser dashboard for managing miners. Reach it locally with a username and password (below). When you run the Discord integration or mine for more than one person, you can also let users sign in over the internet to manage their own miner. Changes take effect after restarting SwiftMiner.")
            } header: {
                Text("Web Dashboard")
            }

            if settings.webDashboardEnabled {
                localAccessSection
                if internetEligible {
                    oauthSections
                } else {
                    Section {
                        Label("The dashboard is local-only right now. Internet access (Twitch sign-in) becomes available when the Discord integration is enabled or you have more than one miner.", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Internet Access")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .padding(.top, 10)
        .sheet(isPresented: $showingTwitchOAuthSetup) {
            twitchOAuthSetupSheet
        }
        .sheet(isPresented: $showingInternetSetup) {
            internetAccessSetupSheet
        }
        .sheet(isPresented: $showingLocalSetup) {
            localAccessSetupSheet
        }
        .task(id: settings.swiftBotEnabled) {
            guard settings.swiftBotEnabled else { return }
            await navigation.checkSwiftBotConnection()
            await loadSwiftBotTunnelInfo()
        }
    }

    // MARK: - Local Access

    private var localAccessSection: some View {
        Section {
            Toggle("Allow local sign-in", isOn: $settings.webDashboardLocalEnabled)

            if settings.webDashboardLocalEnabled {
                if settings.webDashboardLocalConfigured {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Local sign-in ready", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                            Text("Sign in as \(settings.webDashboardLocalUsername)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            openWebpage(localTarget)
                        } label: {
                            Label("Open Webpage", systemImage: "safari")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Open local dashboard")
                        .accessibilityLabel("Open local dashboard")
                        Button {
                            openLocalSetup()
                        } label: {
                            Label("Change Credentials", systemImage: "key.fill")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Change the local dashboard username or password")
                        .accessibilityLabel("Change local dashboard credentials")
                    }
                } else {
                    Button {
                        openLocalSetup()
                    } label: {
                        Label("Set Username and Password", systemImage: "person.badge.key.fill")
                    }
                    Label("Local sign-in is not configured yet.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            SettingsSecondaryText("These credentials sign you in from this Mac or your local network. They are never accepted on your public dashboard, so they stay off the internet. The operator view shows all miners.")
        } header: {
            Text("Local Access")
        }
    }

    private var localAccessSetupSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.tint)
                Text(settings.webDashboardLocalConfigured ? "Change Local Sign-In" : "Set Up Local Sign-In")
                    .font(.headline)
            }

            SettingsSecondaryText("Use these details at the local dashboard sign-in page. Your password stays in Keychain and is never accepted over your public dashboard.")
            if settings.webDashboardLocalConfigured {
                SettingsSecondaryText("Leave New password blank to keep your current password.")
            }

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Username")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Username", text: $draftLocalUsername)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.username)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(settings.webDashboardLocalConfigured ? "New password (optional)" : "Password")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Group {
                            if showLocalPassword {
                                TextField(localPasswordPrompt, text: $draftLocalPassword)
                            } else {
                                SecureField(localPasswordPrompt, text: $draftLocalPassword)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.password)
                        Button {
                            showLocalPassword.toggle()
                        } label: {
                            Image(systemName: showLocalPassword ? "eye.slash" : "eye")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.borderless)
                        .help(showLocalPassword ? "Hide password" : "Show password")
                        .accessibilityLabel(showLocalPassword ? "Hide password" : "Show password")
                    }
                }
            }
            .padding(14)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))

            if let localAccessErrorMessage {
                Label(localAccessErrorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    showingLocalSetup = false
                }
                Button(settings.webDashboardLocalConfigured ? "Save Changes" : "Save Credentials") {
                    saveLocalAccessDetails()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draftLocalIsValid)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private var draftLocalIsValid: Bool {
        let usernameOK = !draftLocalUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let passwordOK = settings.webDashboardLocalConfigured
            ? draftLocalPassword.isEmpty || draftLocalPassword.count >= 6
            : draftLocalPassword.count >= 6
        return usernameOK && passwordOK
    }

    private var localPasswordPrompt: String {
        settings.webDashboardLocalConfigured
            ? "New password (optional, 6+ characters)"
            : "Password (6+ characters)"
    }

    private func openLocalSetup() {
        draftLocalUsername = settings.webDashboardLocalUsername
        // Never show or require the saved password to make a small change.
        draftLocalPassword = ""
        showLocalPassword = false
        localAccessErrorMessage = nil
        showingLocalSetup = true
    }

    private func saveLocalAccessDetails() {
        let username = draftLocalUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if draftLocalPassword.isEmpty {
                if username != settings.webDashboardLocalUsername {
                    guard let savedPassword = settings.webDashboardLocalPassword(), !savedPassword.isEmpty else {
                        localAccessErrorMessage = "Enter a new password to change the username."
                        return
                    }
                    try settings.saveWebDashboardLocalPassword(savedPassword, username: username)
                }
            } else {
                try settings.saveWebDashboardLocalPassword(draftLocalPassword, username: username)
                settings.webDashboardLocalPasswordHash = WebSecurity.hashLocalPassword(draftLocalPassword)
            }
            settings.webDashboardLocalUsername = username
            draftLocalPassword = ""
            localAccessErrorMessage = nil
            showingLocalSetup = false
        } catch {
            localAccessErrorMessage = error.localizedDescription
        }
    }

    // MARK: - OAuth (internet access)

    @ViewBuilder private var oauthSections: some View {
        Section {
            if let origin = webDashboardOrigin {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(
                            swiftBotIsConnected || !settings.swiftBotEnabled
                                ? "Internet access configured"
                                : "Internet access configured, but \(swiftBotUnavailableReason)",
                            systemImage: swiftBotIsConnected || !settings.swiftBotEnabled
                                ? "checkmark.circle.fill"
                                : "exclamationmark.triangle.fill"
                        )
                            .font(.caption)
                            .foregroundStyle(swiftBotIsConnected || !settings.swiftBotEnabled ? .green : .orange)
                        // At-a-glance: just the domain in the UI font. The full
                        // copy-exact URL (mono) lives in the setup sheet.
                        Text(Settings.normalizedWebDashboardURL(from: settings.webDashboardBaseURL)?.host ?? origin)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button {
                        openWebpage(origin)
                    } label: {
                        Label("Open Webpage", systemImage: "safari")
                    }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Open web dashboard")
                        .accessibilityLabel("Open web dashboard")
                        .disabled(settings.swiftBotEnabled && !swiftBotIsConnected)
                    Button {
                        showingInternetSetup = true
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .help("Change internet access settings")
                    .accessibilityLabel("Change internet access settings")
                }
            } else {
                Button {
                    showingInternetSetup = true
                } label: {
                    Label("Set Up Internet Access", systemImage: "globe")
                }
                Label("Internet access is not configured yet.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            SettingsSecondaryText("Your dashboard's public address, carried on SwiftBot's existing Cloudflare tunnel — SwiftMiner doesn't run its own.")
        } header: {
            Text("Internet Access")
        }
        .task { await loadSwiftBotTunnelInfo() }
        .onChange(of: settings.webDashboardSubdomain) { _, _ in syncComposedBaseURL() }

        Section {
            Toggle("Allow Twitch OAuth sign-in", isOn: $settings.webDashboardTwitchOAuthEnabled)

            if settings.webDashboardTwitchOAuthEnabled {
                if settings.webDashboardTwitchConfigured {
                    HStack {
                        Label("Twitch sign-in configured", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                        Spacer()
                        Button {
                            openTwitchOAuthSetup()
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.borderless)
                        .help("Replace Twitch OAuth details")
                        .accessibilityLabel("Replace Twitch OAuth details")
                    }
                } else {
                    Button {
                        openTwitchOAuthSetup()
                    } label: {
                        Label("Set Up Twitch OAuth", systemImage: "key.fill")
                    }
                    Label("Twitch sign-in is not configured yet.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                Label("Twitch OAuth is off. Saved details will be kept.", systemImage: "pause.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SettingsSecondaryText("From your Twitch application (dev.twitch.tv/console → register an app with the redirect URL below). Enables “Sign in with Twitch”, letting users reach their own miner over the web.")
        } header: {
            HStack(spacing: 6) {
                TwitchLogo()
                    .frame(width: 13, height: 14)
                    .accessibilityHidden(true)
                Text("Twitch Sign-In")
            }
        }

        Section {
            Toggle("Allow Discord OAuth sign-in", isOn: $settings.webDashboardDiscordOAuthEnabled)

            if settings.webDashboardDiscordOAuthEnabled {
                if settings.webDashboardDiscordOAuthConfigured, swiftBotIsConnected {
                    Label("Discord sign-in is available through SwiftBot", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if settings.webDashboardDiscordOAuthConfigured {
                    Label("Discord sign-in is unavailable — \(swiftBotUnavailableReason).", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Label("Pair SwiftBot and finish Internet Access setup to use Discord sign-in.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                Label("Discord OAuth is off.", systemImage: "pause.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SettingsSecondaryText("Discord OAuth is completed by your paired SwiftBot, which verifies server membership before returning to the dashboard. No Discord application credentials are stored in SwiftMiner.")
        } header: {
            HStack(spacing: 6) {
                DiscordLogo()
                    .frame(width: 15, height: 15)
                    .accessibilityHidden(true)
                Text("Discord Sign-In")
            }
        }

    }

    private var internetAccessSetupSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.tint)
                Text(webDashboardOrigin == nil ? "Set Up Internet Access" : "Internet Access")
                    .font(.headline)
            }

            SettingsSecondaryText("Pick the public address for your dashboard. SwiftBot carries it on its Cloudflare tunnel — one click registers the route and DNS for you.")

            if settings.swiftBotEnabled {
                if let info = swiftBotTunnelInfo, !info.domain.isEmpty {
                    // Domain comes from SwiftBot — the user only picks a subdomain.
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Subdomain")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            TextField("swiftminer", text: $settings.webDashboardSubdomain)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 160)
                            Text(".\(info.domain)")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        SettingsSecondaryText("Your dashboard will be at https://\(composedHostname(domain: info.domain) ?? "…").")
                    }

                    if !info.internetAccessEnabled {
                        Label("SwiftBot's Internet Access isn't set up yet — finish that in SwiftBot first.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } else {
                    HStack(spacing: 8) {
                        if isFetchingTunnelInfo {
                            ProgressView().controlSize(.mini)
                            Text("Asking SwiftBot for your domain…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Label("Couldn't get the domain from SwiftBot (is it running and up to date?).", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Button("Retry") { Task { await loadSwiftBotTunnelInfo() } }
                                .controlSize(.small)
                        }
                        Spacer()
                    }
                    TextField("Public URL", text: $settings.webDashboardBaseURL, prompt: Text("https://swiftminer.example.com"))
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.URL)
                }

                Button {
                    registerTunnelHostname()
                } label: {
                    if isRegisteringTunnel {
                        ProgressView().controlSize(.mini)
                    } else {
                        Label("Register on SwiftBot's tunnel", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                .disabled(isRegisteringTunnel || webDashboardOrigin == nil)
                if let tunnelRegistrationMessage {
                    Label(tunnelRegistrationMessage, systemImage: tunnelRegistrationSucceeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(tunnelRegistrationSucceeded ? .green : .orange)
                }
            } else {
                TextField("Public URL", text: $settings.webDashboardBaseURL, prompt: Text("https://swiftminer.example.com"))
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.URL)
                copyableValueRow(label: "Local target", value: localTarget)
                SettingsSecondaryText("Add the address above as a public hostname on your Cloudflare tunnel, routed to this local target — or enable the Discord integration to register it through SwiftBot automatically.")
            }

            HStack {
                Spacer()
                Button("Done") {
                    showingInternetSetup = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .task { await loadSwiftBotTunnelInfo() }
    }

    private var twitchOAuthSetupSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                TwitchLogo()
                    .frame(width: 18, height: 20)
                    .accessibilityHidden(true)
                Text(settings.webDashboardTwitchConfigured ? "Replace Twitch OAuth Details" : "Set Up Twitch OAuth")
                    .font(.headline)
            }

            SettingsSecondaryText("Enter the client ID and client secret from your Twitch application. These are used only for web dashboard sign-in.")

            Form {
                TextField("Client ID", text: $draftTwitchClientID)
                    .textContentType(.username)
                SecureField("Client Secret", text: $draftTwitchClientSecret)
                    .textContentType(.password)
            }
            .formStyle(.grouped)

            if let redirect = webRedirectURL {
                copyableValueRow(label: "Redirect URL", value: redirect)
                SettingsSecondaryText("Register this exact URL under OAuth Redirect URLs in your Twitch application.")
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    showingTwitchOAuthSetup = false
                }
                Button("Save") {
                    saveTwitchOAuthDetails()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draftTwitchOAuthIsValid)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private var draftTwitchOAuthIsValid: Bool {
        !draftTwitchClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draftTwitchClientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func openTwitchOAuthSetup() {
        draftTwitchClientID = settings.webDashboardTwitchClientID
        draftTwitchClientSecret = settings.webDashboardTwitchClientSecret
        showingTwitchOAuthSetup = true
    }

    private func saveTwitchOAuthDetails() {
        settings.webDashboardTwitchClientID = draftTwitchClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.webDashboardTwitchClientSecret = draftTwitchClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        draftTwitchClientID = ""
        draftTwitchClientSecret = ""
        showingTwitchOAuthSetup = false
    }

    /// Trailing-slash-normalised public origin, or nil if empty/invalid.
    /// Lenient: a bare hostname is treated as https.
    private var webDashboardOrigin: String? {
        guard let url = Settings.normalizedWebDashboardURL(from: settings.webDashboardBaseURL) else { return nil }
        var s = url.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private var webRedirectURL: String? {
        webDashboardOrigin.map { $0 + "/oauth/callback" }
    }

    /// The local address a tunnel should route the subdomain to.
    private var localTarget: String {
        let port = URL(string: settings.swiftMinerAPIEndpoint)?.port ?? 8080
        return "http://localhost:\(port)"
    }

    private func openWebpage(_ value: String) {
        guard let url = Settings.normalizedWebDashboardURL(from: value) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Subdomain restricted to DNS-label characters, or nil if unusable.
    private var sanitizedSubdomain: String? {
        let cleaned = settings.webDashboardSubdomain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return cleaned.isEmpty ? nil : cleaned
    }

    private func composedHostname(domain: String) -> String? {
        guard let sub = sanitizedSubdomain else { return nil }
        return "\(sub).\(domain)"
    }

    /// Writes the composed https URL into `webDashboardBaseURL`, which stays the
    /// single source of truth for the redirect URL, the server config, and the
    /// tunnel registration call.
    private func syncComposedBaseURL() {
        guard let info = swiftBotTunnelInfo, !info.domain.isEmpty,
              let hostname = composedHostname(domain: info.domain) else { return }
        settings.webDashboardBaseURL = "https://\(hostname)"
    }

    private func loadSwiftBotTunnelInfo() async {
        guard settings.swiftBotEnabled, swiftBotIsConnected, !isFetchingTunnelInfo else { return }
        isFetchingTunnelInfo = true
        swiftBotTunnelInfo = await navigation.fetchSwiftBotTunnelInfo()
        isFetchingTunnelInfo = false
        if let host = swiftBotTunnelInfo?.swiftBotHostname, !host.isEmpty {
            // Cached so Discord-via-SwiftBot sign-in works from next launch.
            settings.webDashboardSwiftBotHostname = host
        }
        syncComposedBaseURL()
    }

    private func registerTunnelHostname() {
        isRegisteringTunnel = true
        tunnelRegistrationMessage = nil
        Task {
            let result = await navigation.registerWebDashboardHostnameWithSwiftBot()
            switch result {
            case .success(let publicURL):
                tunnelRegistrationSucceeded = true
                tunnelRegistrationMessage = "Registered — dashboard reachable at \(publicURL)"
            case .failure(let message):
                tunnelRegistrationSucceeded = false
                tunnelRegistrationMessage = message
            }
            isRegisteringTunnel = false
        }
    }

    /// A monospaced, selectable value with a copy button — used for the local
    /// target and the OAuth redirect URL.
    private func copyableValueRow(label: String, value: String) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Copy")
        }
    }
}

/// The Twitch wordmark glyph, drawn from its 24×24 SVG path so no image asset
/// is needed. Even-odd fill cuts out the screen and leaves the two purple eyes.
struct TwitchLogo: View {
    var color = Color(red: 0.5686, green: 0.2745, blue: 1.0) // #9146FF

    var body: some View {
        TwitchGlyphShape()
            .fill(color, style: FillStyle(eoFill: true))
    }
}

/// Discord's official mark, packaged with the app as an SVG rather than
/// approximated with an SF Symbol.
struct DiscordLogo: View {
    private static let officialMark = Bundle.main
        .url(forResource: "DiscordMarkOfficial", withExtension: "svg")
        .flatMap(NSImage.init(contentsOf:))

    private let discordBlurple = Color(red: 0.345, green: 0.396, blue: 0.949)

    var body: some View {
        if let officialMark = Self.officialMark {
            Image(nsImage: officialMark)
                .resizable()
                .renderingMode(.template)
                .foregroundStyle(discordBlurple)
                .scaledToFit()
        }
    }
}

struct TwitchGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x / 24 * rect.width,
                    y: rect.minY + y / 24 * rect.height)
        }
        let w = rect.width / 24, h = rect.height / 24
        var path = Path()
        // Body
        path.move(to: p(6, 0))
        path.addLine(to: p(1.714, 4.286))
        path.addLine(to: p(1.714, 19.714))
        path.addLine(to: p(6.857, 19.714))
        path.addLine(to: p(6.857, 24))
        path.addLine(to: p(11.143, 19.714))
        path.addLine(to: p(14.571, 19.714))
        path.addLine(to: p(22.286, 12))
        path.addLine(to: p(22.286, 0))
        path.closeSubpath()
        // Inner screen (hole)
        path.move(to: p(20.571, 11.143))
        path.addLine(to: p(17.143, 14.571))
        path.addLine(to: p(13.714, 14.571))
        path.addLine(to: p(10.714, 17.571))
        path.addLine(to: p(10.714, 14.571))
        path.addLine(to: p(6.857, 14.571))
        path.addLine(to: p(6.857, 1.714))
        path.addLine(to: p(20.571, 1.714))
        path.closeSubpath()
        // Eyes
        path.addRect(CGRect(origin: p(11.571, 4.714), size: CGSize(width: 1.715 * w, height: 5.143 * h)))
        path.addRect(CGRect(origin: p(16.286, 4.714), size: CGSize(width: 1.714 * w, height: 5.143 * h)))
        return path
    }
}

struct IntegrationsSettingsView: View {
    @Bindable var settings: Settings
    @Environment(NavigationModel.self) private var navigation
    @State private var isTestingConnection = false
    @State private var connectionTestMessage: String?
    @State private var pairingActionStatus: PairingActionStatus?
    @State private var debugTargetSelection: String?
    @State private var debugDiscordUsers: [SwiftBotDiscordUser] = []
    @State private var isLoadingDebugUsers = false
    @State private var showCustomNotificationSettings = false
    @State private var forceCustomNotificationPreset = false

    private let defaultSwiftBotEndpoint = "http://localhost:38888"

    var body: some View {
        Form {
            integrationEnableSection

            if settings.swiftBotEnabled {
                statusCard

                notificationPresetSection

                if showCustomNotificationSettings || dmNotificationPreset == .custom {
                    importantSection

                    activitySection
                }

                onboardingInfoSection

#if DEBUG
                dmDebugSection
#endif
            } else {
                Section {
                    SettingsSecondaryText("Enable the Discord integration to pair with SwiftBot and send account recovery, drop claim, and campaign update DMs.")
                } header: {
                    Text("Discord")
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .padding(.top, 10)
        .onChange(of: settings.webDashboardBaseURL) { _, _ in
            // DM deep links are built from this URL, so they have to follow it.
            navigation.refreshDMPortalBase()
        }
    }

    private var integrationEnableSection: some View {
        Section {
            Toggle("Enable Discord Integration", isOn: $settings.swiftBotEnabled)
            SettingsSecondaryText("Connects SwiftMiner to SwiftBot for Discord account linking, recovery messages, and miner updates.")
        } header: {
            Text("Discord Integration")
        }
    }

    // MARK: - Status Card

    private var statusCard: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(statusColor.opacity(0.12))
                            .frame(width: 34, height: 34)
                        Image(systemName: statusIcon)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(statusColor)
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        Text(statusTitle)
                            .font(.system(size: 13, weight: .semibold))
                        Text(statusSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        Task {
                            connectionTestMessage = nil
                            isTestingConnection = true
                            await navigation.checkSwiftBotConnection()
                            connectionTestMessage = connectionTestDescription(for: navigation.swiftBotState)
                            isTestingConnection = false
                        }
                    } label: {
                        if isTestingConnection {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                    .disabled(isTestingConnection)
                    .help("Re-check SwiftBot connection")
                }

                Text("Sends Discord DMs for account recovery, drop claims, and campaign updates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineSpacing(1)

                if isTestingConnection {
                    Text("Checking SwiftBot…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let connectionTestMessage {
                    Text(connectionTestMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if navigation.swiftBotState != .connected {
                    Divider()
                        .padding(.vertical, 2)

                    HStack(spacing: 10) {
                        Button {
                            pairWithSwiftBot()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: pairingActionStatus == nil ? "link" : "checkmark.circle.fill")
                                Text(pairingButtonTitle)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)

                        Text(pairingHelperText)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .listRowBackground(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(statusColor.opacity(0.14), lineWidth: 0.5)
                )
        )
    }

    private enum PairingActionStatus {
        case opened
        case copied
    }

    private var pairingButtonTitle: String {
        switch pairingActionStatus {
        case .opened: return "Opened SwiftBot"
        case .copied: return "Copied Pairing Link"
        case nil: return "Pair with SwiftBot"
        }
    }

    private var pairingHelperText: String {
        switch pairingActionStatus {
        case .opened:
            return "SwiftBot should finish pairing automatically."
        case .copied:
            return "SwiftBot was not opened, so the pairing link was copied."
        case nil:
            return "Opens SwiftBot and applies the pairing automatically."
        }
    }

    private var statusTitle: String {
        switch navigation.swiftBotState {
        case .connected: return "Connected to SwiftBot"
        case .notConfigured: return "Discord Integration"
        case .disconnected: return "Not Connected"
        case .unpaired: return "Pairing Required"
        }
    }

    private var statusSubtitle: String {
        switch navigation.swiftBotState {
        case .connected: return "Messages will be delivered to Discord"
        case .notConfigured: return "Enable Discord integration to get started"
        case .disconnected: return "SwiftBot is not responding"
        case .unpaired: return "SwiftBot is running but has not been paired yet"
        }
    }

    private var statusIcon: String {
        switch navigation.swiftBotState {
        case .connected: return "checkmark.circle.fill"
        case .notConfigured: return "app.badge.checkmark"
        case .disconnected: return "exclamationmark.triangle.fill"
        case .unpaired: return "link.badge.plus"
        }
    }

    private var statusColor: Color {
        switch navigation.swiftBotState {
        case .connected: return .green
        case .notConfigured: return .secondary
        case .disconnected: return .orange
        case .unpaired: return .accentColor
        }
    }

    // MARK: - Pairing

    private func pairWithSwiftBot() {
        settings.ensureSwiftBotSecrets()
        let swiftBotEndpoint = normalizedValue(settings.swiftBotEndpoint) ?? defaultSwiftBotEndpoint
        let swiftBotWebhookURL = normalizedValue(settings.swiftBotWebhookURL)
            ?? swiftBotEndpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/webhooks/swiftminer/events"
        let swiftMinerEndpoint = normalizedValue(settings.swiftMinerAPIEndpoint) ?? "http://127.0.0.1:8080"

        if settings.swiftBotEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.swiftBotEndpoint = swiftBotEndpoint
            Task { await navigation.updateSwiftBotEndpoint(swiftBotEndpoint) }
        }
        if settings.swiftBotWebhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.swiftBotWebhookURL = swiftBotWebhookURL
            Task { await navigation.updateSwiftBotWebhookConfig() }
        }
        if settings.swiftMinerAPIEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.swiftMinerAPIEndpoint = swiftMinerEndpoint
        }

        let bundle: [String: Any] = [
            "version": 1,
            "endpoint": swiftMinerEndpoint,
            "swiftMinerEndpoint": swiftMinerEndpoint,
            "swiftBotEndpoint": swiftBotEndpoint,
            "apiKey": settings.swiftMinerAPIKey,
            "hmacSecret": settings.swiftBotHmacSecret,
            "webhookHint": swiftBotWebhookURL
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: bundle, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        let payload = Data(json.utf8).base64EncodedString()

        var components = URLComponents()
        components.scheme = "swiftbot"
        components.host = "swiftminer-pair"
        components.queryItems = [URLQueryItem(name: "b", value: payload)]
        guard let url = components.url else { return }

        let opened = NSWorkspace.shared.open(url)
        if !opened {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(url.absoluteString, forType: .string)
        }
        pairingActionStatus = opened ? .opened : .copied
        Task {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run {
                pairingActionStatus = nil
            }
        }
    }

    private func normalizedValue(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Connection Status

    private func connectionTestDescription(for state: SwiftBotConnectionState) -> String {
        switch state {
        case .connected:
            return "SwiftBot replied."
        case .disconnected:
            let endpoint = normalizedValue(settings.swiftBotEndpoint) ?? defaultSwiftBotEndpoint
            return "SwiftBot is not listening at \(endpoint)."
        case .notConfigured:
            return "No valid localhost endpoint is configured."
        case .unpaired:
            return "SwiftBot is reachable but not paired — paste the pairing bundle into SwiftBot."
        }
    }

    // MARK: - Notification Presets

    private enum DMNotificationPreset: String, CaseIterable, Identifiable {
        case essential
        case balanced
        case everything
        case custom

        var id: String { rawValue }

        var label: String {
            switch self {
            case .essential: return "Essential"
            case .balanced: return "Balanced"
            case .everything: return "Everything"
            case .custom: return "Custom"
            }
        }

        var detail: String {
            switch self {
            case .essential:
                return "Only account recovery, linking, and action-required DMs."
            case .balanced:
                return "Essential DMs, plus campaign completion and reconnection updates."
            case .everything:
                return "All available Discord DMs, including new campaign announcements."
            case .custom:
                return "Choose exactly which Discord DMs SwiftMiner sends."
            }
        }
    }

    private var notificationPresetSection: some View {
        Section {
            Picker("Discord notifications", selection: dmNotificationPresetBinding) {
                ForEach(DMNotificationPreset.allCases) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            SettingsSecondaryText(dmNotificationPreset.detail)
        } header: {
            Text("Notifications")
        }
    }

    private var dmNotificationPresetBinding: Binding<DMNotificationPreset> {
        Binding {
            dmNotificationPreset
        } set: { preset in
            if preset == .custom {
                forceCustomNotificationPreset = true
                showCustomNotificationSettings = true
            } else {
                forceCustomNotificationPreset = false
                showCustomNotificationSettings = false
                applyNotificationPreset(preset)
            }
        }
    }

    private var dmNotificationPreset: DMNotificationPreset {
        if forceCustomNotificationPreset {
            return .custom
        }

        let importantOn = settings.dmConnectionExpiredEnabled
            && settings.dmLinkRequiredEnabled
            && settings.dmAccountActionRequiredEnabled
        let importantOnly = importantOn
            && !settings.dmCampaignCompletedEnabled
            && !settings.dmCampaignDetectedEnabled
            && !settings.dmWelcomeBackEnabled
        let balanced = importantOn
            && settings.dmCampaignCompletedEnabled
            && !settings.dmCampaignDetectedEnabled
            && settings.dmWelcomeBackEnabled
        let everything = importantOn
            && settings.dmCampaignCompletedEnabled
            && settings.dmCampaignDetectedEnabled
            && settings.dmWelcomeBackEnabled

        if everything { return .everything }
        if balanced { return .balanced }
        if importantOnly { return .essential }
        return .custom
    }

    private func applyNotificationPreset(_ preset: DMNotificationPreset) {
        settings.dmConnectionExpiredEnabled = true
        settings.dmLinkRequiredEnabled = true
        settings.dmAccountActionRequiredEnabled = true

        switch preset {
        case .essential:
            settings.dmCampaignCompletedEnabled = false
            settings.dmCampaignDetectedEnabled = false
            settings.dmWelcomeBackEnabled = false
        case .balanced:
            settings.dmCampaignCompletedEnabled = true
            settings.dmCampaignDetectedEnabled = false
            settings.dmWelcomeBackEnabled = true
        case .everything:
            settings.dmCampaignCompletedEnabled = true
            settings.dmCampaignDetectedEnabled = true
            settings.dmWelcomeBackEnabled = true
        case .custom:
            break
        }
    }

    // MARK: - Important Notifications

    private var importantSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                notificationToggleRow(
                    title: "Twitch reconnect needed",
                    description: "Sent when a Twitch login session expires and needs reconnecting.",
                    isOn: $settings.dmConnectionExpiredEnabled
                )

                Divider().padding(.vertical, 2)

                notificationToggleRow(
                    title: "Game account link needed",
                    description: "Sent when you prioritised a game but haven't linked the required account.",
                    isOn: $settings.dmLinkRequiredEnabled
                )

                Divider().padding(.vertical, 2)

                notificationToggleRow(
                    title: "Something needs attention",
                    description: "Sent when a miner encounters an issue that needs a manual look.",
                    isOn: $settings.dmAccountActionRequiredEnabled
                )
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("Important")
                    .font(.subheadline.weight(.semibold))
            }
        } footer: {
            Text("These notifications relate to account recovery and linking. They are recommended to stay on.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Activity Notifications

    private var activitySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                notificationToggleRow(
                    title: "Campaign complete",
                    description: "Sent when all Drops in a campaign have been claimed.",
                    isOn: $settings.dmCampaignCompletedEnabled,
                    previewType: .campaignCompleted
                )

                Divider().padding(.vertical, 2)

                notificationToggleRow(
                    title: "New Drops campaign",
                    description: "Sent when a new campaign starts for a game you follow.",
                    isOn: $settings.dmCampaignDetectedEnabled,
                    previewType: .campaignDetected
                )

                Divider().padding(.vertical, 2)

                notificationToggleRow(
                    title: "Connection restored",
                    description: "Sent when SwiftMiner detects a miner has come back online.",
                    isOn: $settings.dmWelcomeBackEnabled,
                    previewType: .welcomeBack
                )
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "bell")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Activity")
                    .font(.subheadline.weight(.semibold))
            }
        } footer: {
            Text("These are informational updates about mining progress. Turn on the ones you find useful.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Onboarding Info

    private var onboardingInfoSection: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.blue)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Setup messages are always enabled")
                        .font(.caption.weight(.medium))
                    Text("Welcome, linking, and reconnection instructions are always sent so users can complete setup and recover accounts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                }
            }
            .padding(.vertical, 2)
        }
        .listRowBackground(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.blue.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.blue.opacity(0.10), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Notification Toggle Row

    private func notificationToggleRow(
        title: String,
        description: String,
        isOn: Binding<Bool>,
        previewType: SwiftBotDMMessageType? = nil
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

#if DEBUG
            if let previewType {
                Button {
                    Task { await sendPreview(type: previewType) }
                } label: {
                    Image(systemName: "play.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Preview this message")
                .disabled(debugTargetId == nil)
            }
#endif

            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Preview

#if DEBUG
    private func sendPreview(type: SwiftBotDMMessageType) async {
        guard let discordId = debugTargetId else { return }
        _ = await navigation.swiftBotConnectionService.sendDebugDM(to: discordId, request: debugDMRequest(for: type))
    }
#endif

    private var firstLinkedDiscordId: String? {
        navigation.minerManager.miners.compactMap(\.ownerDiscordId).first
    }

    /// Discord ID used for debug previews — picker selection takes precedence
    /// when set, otherwise we fall back to the first linked miner's Discord ID.
    private var debugTargetId: String? {
        debugTargetSelection ?? firstLinkedDiscordId
    }

    private func displayName(for discordId: String) -> String {
        debugDiscordUsers.first(where: { $0.id == discordId })?.displayName.nilIfBlank
            ?? debugDiscordUsers.first(where: { $0.id == discordId })?.username?.nilIfBlank
            ?? navigation.minerManager.miners.first(where: { $0.ownerDiscordId == discordId })?.username
            ?? "Linked Discord user"
    }

#if DEBUG
    // MARK: - DM Debug

    private var dmDebugSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Target")
                        .font(.callout)

                    Picker("", selection: debugTargetBinding) {
                        if debugTargetCandidates.isEmpty {
                            Text("No linked Discord users").tag(String?.none)
                        } else {
                            ForEach(debugTargetCandidates, id: \.id) { user in
                                Text(user.displayName).tag(Optional(user.id))
                            }
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .disabled(debugTargetCandidates.isEmpty)

                    Button {
                        Task { await loadDebugDiscordUsers() }
                    } label: {
                        if isLoadingDebugUsers {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                    .disabled(isLoadingDebugUsers)
                    .help("Refresh Discord user list from SwiftBot")

                    Spacer()
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await sendAllDebugDMs() }
                    } label: {
                        Label("Send All Test DMs", systemImage: "text.bubble")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(debugTargetId == nil)

                    if let id = debugTargetId {
                        SettingsSecondaryText("Sending to \(displayName(for: id))")
                    } else {
                        SettingsSecondaryText("No linked Discord account found.", tint: .orange)
                    }

                    Spacer()
                }

                Divider().padding(.vertical, 2)

                ForEach(SwiftBotDMMessageType.debugPreviewOrder) { type in
                    HStack(spacing: 10) {
                        Text(type.displayName)
                            .font(.callout)

                        Spacer()

                        Button {
                            Task { await sendOneDebugDM(type: type) }
                        } label: {
                            Label("Send", systemImage: "paperplane")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(debugTargetId == nil)
                    }
                }
            }
        } header: {
            Text("Debug Testing")
        }
        .task {
            await loadDebugDiscordUsers()
        }
    }

    /// Union of locally-known miner Discord IDs and SwiftBot's known users, with
    /// display names where available. Locally-known IDs fall back to the linked
    /// Twitch username so raw snowflakes stay out of the UI.
    private var debugTargetCandidates: [SwiftBotDiscordUser] {
        var seen: Set<String> = []
        var result: [SwiftBotDiscordUser] = []

        for user in debugDiscordUsers where seen.insert(user.id).inserted {
            result.append(user)
        }
        for miner in navigation.minerManager.miners {
            guard let id = miner.ownerDiscordId, seen.insert(id).inserted else { continue }
            result.append(SwiftBotDiscordUser(id: id, displayName: miner.displayName, username: miner.username))
        }
        return result
    }

    private var debugTargetBinding: Binding<String?> {
        Binding(
            get: { debugTargetId },
            set: { debugTargetSelection = $0 }
        )
    }

    private func loadDebugDiscordUsers() async {
        isLoadingDebugUsers = true
        defer { isLoadingDebugUsers = false }
        let users = await navigation.swiftBotConnectionService.fetchDiscordUsers()
        debugDiscordUsers = users
    }

    /// A real campaign to make game-related test DMs realistic. Prefers a
    /// fully mined campaign, then one with box art, then any loaded campaign.
    private var debugSampleCampaign: Campaign? {
        let campaigns = navigation.minerManager.campaignStore.campaigns
        return campaigns.first(where: { $0.isFullyComplete && $0.gameImageUrl != nil })
            ?? campaigns.first(where: { $0.gameImageUrl != nil })
            ?? campaigns.first
    }

    /// A real game whose account isn't linked yet — so the needs-linking preview
    /// reflects an actual unlinked game. Prefers the same live "requires link"
    /// state used by the miner UI/notifications, then falls back to cached
    /// unconnected campaign data.
    private var debugUnlinkedGameName: String? {
        if let liveCampaign = debugNeedsLinkingCampaign {
            return liveCampaign.game.name
        }

        let campaigns = navigation.minerManager.campaignStore.campaigns
        let priority = debugPriorityGameKeys
        return campaigns.first(where: { campaign in
            !campaign.isAccountConnected &&
                debugPriorityMatches(campaign: campaign, priority: priority)
        })?.game.name
            ?? campaigns.first(where: { !$0.isAccountConnected })?.game.name
            ?? campaigns.first?.game.name
    }

    private var debugNeedsLinkingCampaign: Campaign? {
        let priority = debugPriorityGameKeys
        guard !priority.isEmpty else { return nil }

        for miner in navigation.minerManager.miners {
            if let campaign = miner.allCampaigns.first(where: { campaign in
                debugIsNeedsLinkingCampaign(campaign, miner: miner, priority: priority)
            }) {
                return campaign
            }
        }
        return nil
    }

    private var debugPriorityGameKeys: Set<String> {
        Set(Settings.shared.priorityGames.map(debugNormalizedGameKey).filter { !$0.isEmpty })
    }

    private func debugIsNeedsLinkingCampaign(
        _ campaign: Campaign,
        miner: MinerManager.ManagedMiner,
        priority: Set<String>
    ) -> Bool {
        campaign.isTimeActive &&
            campaign.status != .disabled &&
            campaign.activityStatus(for: miner) == .requiresLink &&
            campaign.drops.contains(where: { !$0.isClaimed }) &&
            debugPriorityMatches(campaign: campaign, priority: priority)
    }

    private func debugPriorityMatches(campaign: Campaign, priority: Set<String>) -> Bool {
        priority.contains(debugNormalizedGameKey(campaign.game.name)) ||
            priority.contains(debugNormalizedGameKey(campaign.game.id))
    }

    private func debugNormalizedGameKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Builds a fully-populated debug request for a message type, filling only
    /// the fields each type actually renders so every DM looks realistic.
    /// Campaign-completed pulls a real (ideally mined) campaign when available;
    /// needs-linking follows a real unlinked game. Falls back to static values.
    private func debugDMRequest(for type: SwiftBotDMMessageType) -> SwiftBotDMRequest {
        let sample = debugSampleCampaign
        let targetMiner = debugTargetId.flatMap { id in
            navigation.minerManager.miners.first(where: { $0.ownerDiscordId == id })
        } ?? navigation.minerManager.miners.first

        // Game-oriented DMs lead with the game name, so feed a real one:
        // campaign-completed/new-campaign use the sample campaign's game;
        // needs-linking uses a real unlinked game.
        let affectedGame: String
        switch type {
        case .campaignCompleted, .campaignDetected:
            affectedGame = sample?.gameName ?? "The Finals"
        case .prioritisedGameNeedsLinking:
            affectedGame = debugUnlinkedGameName ?? "The Finals"
        default:
            affectedGame = sample?.gameName ?? "Test Game"
        }

        // Previews have to carry the same deep links production does, or this
        // section shows a DM that renders differently from the real thing.
        let portal = SwiftMinerPortalLink(base: NavigationModel.portalBase())
        let destination = Self.debugPortalDestination(for: type)
        let issueKind = Self.debugIssueKind(for: type)
        let campaignId = sample?.id
        let portalURL: String? = {
            switch destination {
            case .campaign: return campaignId.flatMap { portal?.campaign(id: $0) } ?? portal?.campaigns
            case .miner: return targetMiner.flatMap { portal?.miner(accountId: $0.accountId) } ?? portal?.dashboard
            default: return portal?.url(for: destination)
            }
        }()

        return SwiftBotDMRequest(
            messageType: type,
            debug: true,
            twitchUsername: targetMiner?.username ?? "test_user",
            priorityGames: Settings.shared.priorityGames,
            activationCode: type == .setup ? "ABCD-EFGH" : nil,
            activationExpiresInMinutes: type == .setup ? 29 : nil,
            activationURL: type == .setup ? "https://www.twitch.tv/activate?device-code=ABCD-EFGH" : nil,
            affectedGame: affectedGame,
            campaignName: sample?.name ?? "Test Campaign",
            milestoneTitle: "50% Complete",
            gameArtworkURL: (type == .campaignCompleted || type == .campaignDetected)
                ? (sample?.gameImageUrl?.absoluteString ?? "https://static-cdn.jtvnw.net/ttv-boxart/1234_IGDB-285x380.jpg")
                : nil,
            recoveryReason: "Twitch token expired during mining.",
            portalURL: portalURL,
            portalDestination: portal.map { _ in destination.rawValue },
            issueKind: issueKind?.rawValue,
            campaignId: destination == .campaign ? campaignId : nil,
            helpURL: issueKind.flatMap(SwiftMinerHelpLink.url(for:))
        )
    }

    /// Where each message type's portal button points, mirroring the
    /// production send sites so a preview is not misleading.
    static func debugPortalDestination(for type: SwiftBotDMMessageType) -> SwiftBotPortalDestination {
        switch type {
        case .reauth: return .accountConnection
        case .prioritisedGameNeedsLinking: return .campaigns
        case .accountActionRequired, .campaignDetected: return .campaign
        case .campaignCompleted, .dropClaimed: return .drops
        case .welcomeBack: return .miner
        case .welcome, .discordLinked, .setup, .linked, .webDashboardAvailable: return .dashboard
        }
    }

    static func debugIssueKind(for type: SwiftBotDMMessageType) -> SwiftBotIssueKind? {
        switch type {
        case .reauth: return .connectionExpired
        case .prioritisedGameNeedsLinking: return .accountLinkRequired
        // The Pending section's subscription-gated case is the common one, and
        // it exercises the classified-title path.
        case .accountActionRequired: return .subscriptionRequired
        default: return nil
        }
    }

    private func sendOneDebugDM(type: SwiftBotDMMessageType) async {
        guard let discordId = debugTargetId else { return }
        _ = await navigation.swiftBotConnectionService.sendDebugDM(to: discordId, request: debugDMRequest(for: type))
    }

    private func sendAllDebugDMs() async {
        guard let discordId = debugTargetId else { return }
        for type in SwiftBotDMMessageType.debugPreviewOrder {
            _ = await navigation.swiftBotConnectionService.sendDebugDM(to: discordId, request: debugDMRequest(for: type))
            try? await Task.sleep(for: .milliseconds(650))
        }
    }
#endif
}
