import Foundation
import AppKit
import SwiftMinerCore

/// Manages the Twitch OAuth device-code login flow for adding a new miner account.
///
/// Usage:
///   1. Call `startDeviceAuth()` — populates `deviceInfo` and opens the browser.
///   2. Observe `state` to drive the UI.
///   3. When `state == .succeeded(let account)`, hand the account to `MinerManager`.
@MainActor
@Observable
public final class MinerLoginService {

    // MARK: - State

    public enum AuthState: Equatable {
        case idle
        case starting
        case waitingForUser(code: String, verificationURL: URL, expiresIn: Int)
        case polling
        case succeeded(account: Account)
        case failed(message: String)

        public static func == (lhs: AuthState, rhs: AuthState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle),
                 (.starting, .starting),
                 (.polling, .polling):
                return true
            case (.waitingForUser(let lc, let lu, let le), .waitingForUser(let rc, let ru, let re)):
                return lc == rc && lu == ru && le == re
            case (.succeeded(let la), .succeeded(let ra)):
                return la.id == ra.id
            case (.failed(let lm), .failed(let rm)):
                return lm == rm
            default:
                return false
            }
        }
    }

    public private(set) var state: AuthState = .idle

    // MARK: - Private

    private var pollingTask: Task<Void, Never>?

    // MARK: - Init

    public init() {}

    // MARK: - Public API

    /// Begin the device-code flow. Updates `state` as the flow progresses.
    public func startDeviceAuth() {
        guard state == .idle || isFailed else { return }

        // resolvedClientId always returns a value (falls back to Twitch's web client ID)
        let clientId = Settings.shared.resolvedClientId
        
        // Debug logging
        print("[MinerLoginService] Using client_id: \(clientId.prefix(10))... (length: \(clientId.count))")
        print("[MinerLoginService] Source: \(ProcessInfo.processInfo.environment["TWITCH_CLIENT_ID"]?.isEmpty == false ? "env" : Settings.shared.twitchClientId.isEmpty ? "default" : "settings")")

        state = .starting

        Task {
            do {
                let authService = TwitchAuthService(clientId: clientId)
                let response = try await authService.initiateDeviceFlow()

                // Auto-open browser for user convenience
                NSWorkspace.shared.open(response.verificationURI)
                
                state = .waitingForUser(
                    code: response.userCode,
                    verificationURL: response.verificationURI,
                    expiresIn: response.expiresIn
                )

                // Begin polling in the background
                beginPolling(
                    authService: authService,
                    deviceCode: response.deviceCode,
                    interval: response.interval
                )
            } catch {
                let raw = error.localizedDescription
                // Include the first 8 chars of the client ID so we can verify which one was used
                let idHint = clientId.count > 8 ? String(clientId.prefix(8)) + "…" : clientId
                state = .failed(message: "\(raw)\n\n(client_id: \(idHint))")
            }
        }
    }

    /// Cancel any in-flight polling and reset to idle.
    public func cancel() {
        pollingTask?.cancel()
        pollingTask = nil
        state = .idle
    }

    // MARK: - Polling

    private func beginPolling(authService: TwitchAuthService, deviceCode: String, interval: Int) {
        pollingTask?.cancel()
        state = .polling

        pollingTask = Task {
            do {
                let account = try await authService.pollForToken(
                    deviceCode: deviceCode,
                    interval: interval
                )
                guard !Task.isCancelled else { return }
                state = .succeeded(account: account)
            } catch {
                guard !Task.isCancelled else { return }
                let raw = error.localizedDescription
                let friendly: String
                if raw.contains("expired") {
                    friendly = "Authorisation code expired. Click 'Try Again' to start over."
                } else {
                    friendly = raw
                }
                state = .failed(message: friendly)
            }
        }
    }

    // MARK: - Helpers

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }
}
