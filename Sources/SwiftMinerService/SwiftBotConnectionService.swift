import Foundation
import SwiftMinerCore

/// Implementation of SwiftBotConnectionService using REST polling.
public actor RestSwiftBotConnectionService: SwiftBotConnectionService {
    private var endpoint: URL?
    private(set) public var state: SwiftBotConnectionState = .notConfigured
    private let outboxProvider: @Sendable () -> EventOutboxService?
    
    public init(endpoint: String, outboxProvider: @escaping @Sendable () -> EventOutboxService?) {
        self.endpoint = Self.validatedURL(from: endpoint)
        self.outboxProvider = outboxProvider
        if self.endpoint == nil {
            self.state = .notConfigured
        } else {
            self.state = .disconnected
        }
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
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) {
                self.state = .connected
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

    public func sendTestDM(to discordUserId: String, twitchUsername: String?, priorityGames: [String]) async -> Bool {
        guard let url = endpoint else { return false }
        let dmUrl = url.appendingPathComponent("v1/users/\(discordUserId)/dm/test")
        var request = URLRequest(url: dmUrl)
        request.httpMethod = "POST"
        request.timeoutInterval = 10.0
        if twitchUsername != nil || !priorityGames.isEmpty {
            var body: [String: Any] = [:]
            if let twitchUsername { body["twitch_username"] = twitchUsername }
            if !priorityGames.isEmpty { body["priority_games"] = priorityGames }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } ?? false
        } catch {
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
