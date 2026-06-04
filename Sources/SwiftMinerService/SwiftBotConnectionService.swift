import Foundation
import OSLog
import SwiftMinerCore

private let swiftBotConnectionLogger = Logger(subsystem: "com.swiftminer", category: "swiftbot")

/// Implementation of SwiftBotConnectionService using REST polling.
public actor RestSwiftBotConnectionService: SwiftBotConnectionService {
    /// Notified after every DM send attempt so the app layer can mirror the
    /// event into the activity log. Always called on a non-debug send;
    /// `success` reflects the HTTP outcome.
    public typealias DMActivityHandler = @Sendable (_ messageType: SwiftBotDMMessageType, _ discordUserId: String, _ success: Bool, _ debug: Bool) async -> Void

    private var endpoint: URL?
    private(set) public var state: SwiftBotConnectionState = .notConfigured
    private let outboxProvider: @Sendable () -> EventOutboxService?
    private let dmLogStore: DMLogStore?
    private var dmActivityHandler: DMActivityHandler?

    public init(
        endpoint: String,
        dmLogStore: DMLogStore? = nil,
        outboxProvider: @escaping @Sendable () -> EventOutboxService?
    ) {
        self.endpoint = Self.validatedURL(from: endpoint)
        self.dmLogStore = dmLogStore
        self.outboxProvider = outboxProvider
        if self.endpoint == nil {
            self.state = .notConfigured
        } else {
            self.state = .disconnected
        }
    }

    public func setDMActivityHandler(_ handler: @escaping DMActivityHandler) {
        self.dmActivityHandler = handler
    }
    
    public func updateEndpoint(_ urlString: String) async {
        self.endpoint = Self.validatedURL(from: urlString)
        if self.endpoint == nil {
            self.state = .notConfigured
        } else {
            self.state = .disconnected
            _ = await checkHealth()
        }
    }
    
    public func checkHealth() async -> SwiftBotConnectionState {
        guard let url = endpoint else {
            self.state = .notConfigured
            return .notConfigured
        }
        
        let healthUrl = url.appendingPathComponent("health")
        var request = URLRequest(url: healthUrl)
        request.httpMethod = "GET"
        request.timeoutInterval = 5.0
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) {
                // SwiftBot 1.11+ reports a `paired` flag in /health. Treat a
                // present-and-false flag as `.unpaired` so the UI prompts the
                // user to paste the pairing bundle. Missing/unparseable falls
                // back to `.connected` for older SwiftBot builds.
                if let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let paired = body["paired"] as? Bool {
                    self.state = paired ? .connected : .unpaired
                } else {
                    self.state = .connected
                }
            } else {
                self.state = .disconnected
            }
        } catch {
            self.state = .disconnected
        }

        return self.state
    }

    public func sendTestEvent() async -> Bool {
        guard let outbox = outboxProvider() else { return false }
        return await outbox.sendTestWebhook()
    }

    public func fetchDiscordUsers() async -> [SwiftBotDiscordUser] {
        guard let url = endpoint else { return [] }
        var request = URLRequest(url: url.appendingPathComponent("v1/users"))
        request.httpMethod = "GET"
        request.timeoutInterval = 5.0
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return [] }
            let wrapper = try JSONDecoder().decode(UsersResponse.self, from: data)
            return wrapper.users
        } catch {
            return []
        }
    }

    public func sendLinkedDM(to discordUserId: String, twitchUsername: String?, priorityGames: [String]) async -> Bool {
        await sendDM(
            to: discordUserId,
            request: SwiftBotDMRequest(
                messageType: .linked,
                debug: false,
                twitchUsername: twitchUsername,
                priorityGames: priorityGames
            )
        )
    }

    public func sendDebugDM(to discordUserId: String, request: SwiftBotDMRequest) async -> Bool {
        var debugRequest = request
        if !debugRequest.debug {
            debugRequest = SwiftBotDMRequest(
                messageType: request.messageType,
                debug: true,
                twitchUsername: request.twitchUsername,
                priorityGames: request.priorityGames,
                activationCode: request.activationCode,
                activationExpiresInMinutes: request.activationExpiresInMinutes,
                affectedGame: request.affectedGame,
                campaignName: request.campaignName,
                milestoneTitle: request.milestoneTitle,
                gameArtworkURL: request.gameArtworkURL,
                recoveryReason: request.recoveryReason
            )
        }
        return await sendDM(to: discordUserId, request: debugRequest)
    }

    public func sendEventDM(to discordUserId: String, request: SwiftBotDMRequest) async -> Bool {
        await sendDM(to: discordUserId, request: request)
    }

    private func sendDM(to discordUserId: String, request dmRequest: SwiftBotDMRequest) async -> Bool {
        guard let url = endpoint else {
            swiftBotConnectionLogger.warning("sendDM aborted — endpoint not configured")
            return false
        }
        let dmUrl = url.appendingPathComponent("v1/users/\(discordUserId)/dm/test")
        var request = URLRequest(url: dmUrl)
        request.httpMethod = "POST"
        request.timeoutInterval = 10.0

        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(dmRequest)

        swiftBotConnectionLogger.info(
            "sendDM POST discordId=\(discordUserId, privacy: .private) messageType=\(dmRequest.messageType.rawValue, privacy: .public) debug=\(dmRequest.debug, privacy: .public) twitchUsername=\(dmRequest.twitchUsername ?? "<nil>", privacy: .private) priorityCount=\(dmRequest.priorityGames.count)"
        )
        if let httpBody = request.httpBody, let raw = String(data: httpBody, encoding: .utf8) {
            swiftBotConnectionLogger.debug("sendDM body=\(raw, privacy: .private)")
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let ok = (response as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } ?? false
            if !ok, let http = response as? HTTPURLResponse {
                swiftBotConnectionLogger.error("sendDM non-2xx status=\(http.statusCode)")
            }
            // Persist successful sends (production + debug) with the full
            // payload. The reader filters debug entries out for production UI;
            // DEBUG-only views opt in via `includeDebug: true`.
            if ok, let dmLogStore {
                await dmLogStore.record(discordUserId: discordUserId, request: dmRequest)
            }
            await dmActivityHandler?(dmRequest.messageType, discordUserId, ok, dmRequest.debug)
            return ok
        } catch {
            swiftBotConnectionLogger.error("sendDM transport error: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Private Helpers

    private struct UsersResponse: Decodable {
        let users: [SwiftBotDiscordUser]
    }

    /// Validates that the URL is a local endpoint (localhost/127.0.0.1) with http/https scheme.
    private static func validatedURL(from urlString: String) -> URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host(),
              host == "localhost" || host == "127.0.0.1" else {
            return nil
        }
        return url
    }
}
