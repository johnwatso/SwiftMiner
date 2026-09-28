import CryptoKit
import Foundation
import Security

/// Coordinates a single-use handoff from a user's local browser helper to the
/// SwiftMiner host. The coordinator deliberately treats the submitted and
/// validated payloads as opaque, short-lived values: neither is retained after
/// `submit(ticket:payload:)` returns.
public actor RemoteBrowserLoginCoordinator {
    public typealias Clock = @Sendable () -> Date
    public typealias RandomBytes = @Sendable (_ count: Int) throws -> Data
    public typealias Validator = @Sendable (RemoteBrowserLoginValidationRequest) async throws -> RemoteBrowserLoginValidatedAccount
    public typealias Importer = @Sendable (RemoteBrowserLoginImportRequest) async throws -> Void

    public static let ticketLifetime: TimeInterval = 10 * 60
    public static let resultRetention: TimeInterval = ticketLifetime

    private struct Session {
        let id: String
        let ownerID: String
        let expectedAccountID: String?
        let ticketDigest: Data
        let createdAt: Date
        let expiresAt: Date
        var resolvedAccountID: String?
        var state: RemoteBrowserLoginState
        var failure: RemoteBrowserLoginFailure?
        var receipt: RemoteBrowserLoginReceipt?
        var terminalAt: Date?
    }

    private let clock: Clock
    private let randomBytes: RandomBytes
    private let validator: Validator
    private let importer: Importer

    private var sessions: [String: Session] = [:]
    private var sessionIDByTicketDigest: [Data: String] = [:]

    public init(
        validator: @escaping Validator,
        importer: @escaping Importer
    ) {
        self.clock = { Date() }
        self.randomBytes = { count in
            try Self.secureRandomBytes(count: count)
        }
        self.validator = validator
        self.importer = importer
    }

    /// Injectable initializer used by deterministic tests and hosts with a
    /// specialised cryptographic random source.
    public init(
        clock: @escaping Clock,
        randomBytes: @escaping RandomBytes,
        validator: @escaping Validator,
        importer: @escaping Importer
    ) {
        self.clock = clock
        self.randomBytes = randomBytes
        self.validator = validator
        self.importer = importer
    }

    /// Issues a 256-bit, URL-safe ticket. The plaintext ticket is returned once
    /// and is never retained by the coordinator; only its SHA-256 digest is kept.
    /// There may be only one active handoff for an owner/account pair.
    public func begin(
        ownerID: String,
        expectedAccountID: String? = nil
    ) throws -> RemoteBrowserLoginTicket {
        guard Self.isValidIdentifier(ownerID) else {
            throw RemoteBrowserLoginCoordinatorError.invalidOwner
        }
        if let expectedAccountID, !Self.isValidIdentifier(expectedAccountID) {
            throw RemoteBrowserLoginCoordinatorError.invalidAccount
        }

        let now = clock()
        cleanup(at: now)

        let alreadyActive = sessions.values.contains { session in
            guard session.ownerID == ownerID, session.state.isActive else { return false }
            if let expectedAccountID {
                return session.expectedAccountID == expectedAccountID
            }
            return session.expectedAccountID == nil
        }
        guard !alreadyActive else {
            throw RemoteBrowserLoginCoordinatorError.sessionAlreadyActive
        }

        let sessionBytes: Data
        let ticketBytes: Data
        do {
            sessionBytes = try randomBytes(16)
            ticketBytes = try randomBytes(32)
        } catch {
            throw RemoteBrowserLoginCoordinatorError.ticketGenerationFailed
        }
        guard sessionBytes.count == 16, ticketBytes.count == 32 else {
            throw RemoteBrowserLoginCoordinatorError.ticketGenerationFailed
        }

        let sessionID = "rbls_\(Self.base64URLEncoded(sessionBytes))"
        let ticket = "rblt_\(Self.base64URLEncoded(ticketBytes))"
        let digest = Self.digest(ticket)
        guard sessions[sessionID] == nil, sessionIDByTicketDigest[digest] == nil else {
            throw RemoteBrowserLoginCoordinatorError.ticketGenerationFailed
        }

        let expiresAt = now.addingTimeInterval(Self.ticketLifetime)
        let session = Session(
            id: sessionID,
            ownerID: ownerID,
            expectedAccountID: expectedAccountID,
            ticketDigest: digest,
            createdAt: now,
            expiresAt: expiresAt,
            resolvedAccountID: nil,
            state: .pending,
            failure: nil,
            receipt: nil,
            terminalAt: nil
        )
        sessions[sessionID] = session
        sessionIDByTicketDigest[digest] = sessionID

        return RemoteBrowserLoginTicket(
            sessionID: sessionID,
            ticket: ticket,
            expiresAt: expiresAt
        )
    }

    /// Atomically claims a ticket before invoking any asynchronous dependency.
    /// A failed validation or import still consumes the ticket; callers must
    /// explicitly begin a new handoff rather than replaying sensitive material.
    @discardableResult
    public func submit(ticket: String, payload: Data) async throws -> RemoteBrowserLoginReceipt {
        guard Self.isWellFormedTicket(ticket) else {
            throw RemoteBrowserLoginCoordinatorError.invalidTicket
        }
        cleanup(at: clock())
        let digest = Self.digest(ticket)
        guard let sessionID = sessionIDByTicketDigest[digest],
              var session = sessions[sessionID]
        else {
            throw RemoteBrowserLoginCoordinatorError.invalidTicket
        }

        let claimedAt = clock()
        if session.state == .pending, claimedAt >= session.expiresAt {
            session.state = .expired
            session.terminalAt = session.expiresAt
            sessions[sessionID] = session
            throw RemoteBrowserLoginCoordinatorError.ticketExpired
        }
        guard session.state == .pending else {
            throw Self.rejection(for: session.state)
        }

        // This state transition happens synchronously inside the actor before
        // the validator can suspend, making concurrent claims deterministic.
        session.state = .validating
        sessions[sessionID] = session

        let validationRequest = RemoteBrowserLoginValidationRequest(
            ownerID: session.ownerID,
            expectedAccountID: session.expectedAccountID,
            payload: payload
        )

        let validated: RemoteBrowserLoginValidatedAccount
        do {
            validated = try await validator(validationRequest)
        } catch {
            try finishFailedValidation(sessionID: sessionID, at: clock())
            throw RemoteBrowserLoginCoordinatorError.validationFailed
        }

        guard var current = sessions[sessionID] else {
            throw RemoteBrowserLoginCoordinatorError.invalidTicket
        }
        guard current.state == .validating else {
            throw Self.rejection(for: current.state)
        }
        guard Self.isValidIdentifier(validated.accountID) else {
            current.state = .failed
            current.failure = RemoteBrowserLoginFailure(code: .validationRejected)
            current.terminalAt = clock()
            sessions[sessionID] = current
            throw RemoteBrowserLoginCoordinatorError.validationFailed
        }
        guard current.expectedAccountID == nil || validated.accountID == current.expectedAccountID else {
            current.state = .failed
            current.failure = RemoteBrowserLoginFailure(code: .accountMismatch)
            current.terminalAt = clock()
            sessions[sessionID] = current
            throw RemoteBrowserLoginCoordinatorError.accountMismatch
        }

        current.resolvedAccountID = validated.accountID
        current.state = .importing
        sessions[sessionID] = current

        let importRequest = RemoteBrowserLoginImportRequest(
            ownerID: current.ownerID,
            accountID: validated.accountID,
            credentialPayload: validated.credentialPayload
        )
        do {
            try await importer(importRequest)
        } catch {
            guard var failed = sessions[sessionID], failed.state == .importing else {
                throw RemoteBrowserLoginCoordinatorError.ticketAlreadyUsed
            }
            failed.state = .failed
            failed.failure = RemoteBrowserLoginFailure(code: .importFailed)
            failed.terminalAt = clock()
            sessions[sessionID] = failed
            throw RemoteBrowserLoginCoordinatorError.importFailed
        }

        guard var completed = sessions[sessionID], completed.state == .importing else {
            throw RemoteBrowserLoginCoordinatorError.ticketAlreadyUsed
        }
        let receipt = RemoteBrowserLoginReceipt(
            sessionID: completed.id,
            accountID: validated.accountID,
            completedAt: clock()
        )
        completed.state = .succeeded
        completed.receipt = receipt
        completed.terminalAt = receipt.completedAt
        sessions[sessionID] = completed
        return receipt
    }

    /// Possession-based lookup for helpers that uploaded a session but lost the
    /// HTTP acknowledgement. A helper can poll the same ticket instead of ever
    /// replaying the credential payload. Results are retained for ten minutes
    /// after reaching a terminal state.
    public func result(ticket: String) -> RemoteBrowserLoginTicketResult? {
        guard Self.isWellFormedTicket(ticket) else { return nil }
        cleanup(at: clock())
        let digest = Self.digest(ticket)
        guard let sessionID = sessionIDByTicketDigest[digest],
              let session = sessions[sessionID]
        else {
            return nil
        }
        return RemoteBrowserLoginTicketResult(
            sessionID: session.id,
            state: session.state,
            failure: session.failure,
            receipt: session.receipt
        )
    }

    /// Returns no information for an unknown session or for a session belonging
    /// to a different owner, preventing account/session enumeration.
    public func status(sessionID: String, ownerID: String) -> RemoteBrowserLoginStatus? {
        let now = clock()
        cleanup(at: now)
        guard let session = sessions[sessionID], session.ownerID == ownerID else {
            return nil
        }
        return Self.status(from: session)
    }

    /// Cancels a handoff that has not begun its atomic import. Validation may be
    /// in flight, but its result will be discarded and the importer will not run.
    /// Import itself cannot be cancelled because the host callback may already
    /// have committed credential changes.
    @discardableResult
    public func cancel(sessionID: String, ownerID: String) -> Bool {
        let now = clock()
        cleanup(at: now)
        guard var session = sessions[sessionID], session.ownerID == ownerID else {
            return false
        }
        guard session.state == .pending || session.state == .validating else {
            return false
        }
        session.state = .cancelled
        session.terminalAt = now
        sessions[sessionID] = session
        return true
    }

    private func finishFailedValidation(sessionID: String, at date: Date) throws {
        guard var session = sessions[sessionID] else {
            throw RemoteBrowserLoginCoordinatorError.invalidTicket
        }
        guard session.state == .validating else {
            throw Self.rejection(for: session.state)
        }
        session.state = .failed
        session.failure = RemoteBrowserLoginFailure(code: .validationRejected)
        session.terminalAt = date
        sessions[sessionID] = session
    }

    private func cleanup(at date: Date) {
        expirePendingSessions(at: date)
        let removableIDs = sessions.values.compactMap { session -> String? in
            guard let terminalAt = session.terminalAt,
                  date >= terminalAt.addingTimeInterval(Self.resultRetention)
            else {
                return nil
            }
            return session.id
        }
        for sessionID in removableIDs {
            guard let removed = sessions.removeValue(forKey: sessionID) else { continue }
            sessionIDByTicketDigest.removeValue(forKey: removed.ticketDigest)
        }
    }

    private func expirePendingSessions(at date: Date) {
        let expiredIDs = sessions.values.compactMap { session in
            session.state == .pending && date >= session.expiresAt ? session.id : nil
        }
        for sessionID in expiredIDs {
            expirePendingSession(sessionID: sessionID, at: date)
        }
    }

    private func expirePendingSession(sessionID: String, at date: Date) {
        guard var session = sessions[sessionID],
              session.state == .pending,
              date >= session.expiresAt
        else {
            return
        }
        session.state = .expired
        session.terminalAt = session.expiresAt
        sessions[sessionID] = session
    }

    private static func status(from session: Session) -> RemoteBrowserLoginStatus {
        RemoteBrowserLoginStatus(
            sessionID: session.id,
            expectedAccountID: session.expectedAccountID,
            resolvedAccountID: session.resolvedAccountID,
            state: session.state,
            createdAt: session.createdAt,
            expiresAt: session.expiresAt,
            failure: session.failure,
            receipt: session.receipt
        )
    }

    private static func rejection(for state: RemoteBrowserLoginState) -> RemoteBrowserLoginCoordinatorError {
        switch state {
        case .expired:
            return .ticketExpired
        case .cancelled:
            return .sessionCancelled
        case .pending:
            return .invalidTicket
        case .validating, .importing, .succeeded, .failed:
            return .ticketAlreadyUsed
        }
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 256 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
        }
    }

    private static func digest(_ ticket: String) -> Data {
        Data(SHA256.hash(data: Data(ticket.utf8)))
    }

    private static func isWellFormedTicket(_ ticket: String) -> Bool {
        let prefix = "rblt_"
        guard ticket.hasPrefix(prefix), ticket.utf8.count == prefix.utf8.count + 43 else {
            return false
        }
        return ticket.dropFirst(prefix.count).utf8.allSatisfy { byte in
            (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || (byte >= 48 && byte <= 57)
                || byte == 45
                || byte == 95
        }
    }

    private static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func secureRandomBytes(count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { rawBuffer -> OSStatus in
            guard let address = rawBuffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, address)
        }
        guard status == errSecSuccess else {
            throw SecureRandomError.generationFailed
        }
        return data
    }

    private enum SecureRandomError: Error {
        case generationFailed
    }
}

public enum RemoteBrowserLoginState: String, Codable, Sendable {
    case pending
    case validating
    case importing
    case succeeded
    case failed
    case cancelled
    case expired

    fileprivate var isActive: Bool {
        self == .pending || self == .validating || self == .importing
    }
}

/// The only value containing the plaintext ticket. Callers should deliver it
/// out of band to the browser helper and must not log or persist it.
public struct RemoteBrowserLoginTicket: Sendable, Equatable {
    public let sessionID: String
    public let ticket: String
    public let expiresAt: Date

    public init(sessionID: String, ticket: String, expiresAt: Date) {
        self.sessionID = sessionID
        self.ticket = ticket
        self.expiresAt = expiresAt
    }
}

public struct RemoteBrowserLoginStatus: Codable, Sendable, Equatable {
    public let sessionID: String
    public let expectedAccountID: String?
    public let resolvedAccountID: String?
    public let state: RemoteBrowserLoginState
    public let createdAt: Date
    public let expiresAt: Date
    public let failure: RemoteBrowserLoginFailure?
    public let receipt: RemoteBrowserLoginReceipt?
}

/// A deliberately small helper-facing view. It contains enough information to
/// recover from a lost acknowledgement without exposing owner or target data.
public struct RemoteBrowserLoginTicketResult: Codable, Sendable, Equatable {
    public let sessionID: String
    public let state: RemoteBrowserLoginState
    public let failure: RemoteBrowserLoginFailure?
    public let receipt: RemoteBrowserLoginReceipt?
}

public struct RemoteBrowserLoginReceipt: Codable, Sendable, Equatable {
    public let sessionID: String
    public let accountID: String
    public let completedAt: Date

    public init(sessionID: String, accountID: String, completedAt: Date) {
        self.sessionID = sessionID
        self.accountID = accountID
        self.completedAt = completedAt
    }
}

public struct RemoteBrowserLoginFailure: Codable, Sendable, Equatable {
    public enum Code: String, Codable, Sendable {
        case validationRejected = "validation_rejected"
        case accountMismatch = "account_mismatch"
        case importFailed = "import_failed"
    }

    public let code: Code

    public var message: String {
        switch code {
        case .validationRejected:
            return "The browser login could not be verified. Start a new login and try again."
        case .accountMismatch:
            return "The browser login belongs to a different Twitch account."
        case .importFailed:
            return "The verified login could not be saved. Your existing account was not changed."
        }
    }

    fileprivate init(code: Code) {
        self.code = code
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case message
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(Code.self, forKey: .code)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
    }
}

/// Opaque input passed directly from the helper endpoint to the validator.
/// The coordinator does not inspect or retain `payload`.
public struct RemoteBrowserLoginValidationRequest: Sendable {
    public let ownerID: String
    public let expectedAccountID: String?
    public let payload: Data

    public init(ownerID: String, expectedAccountID: String?, payload: Data) {
        self.ownerID = ownerID
        self.expectedAccountID = expectedAccountID
        self.payload = payload
    }
}

/// A validator-provided account assertion plus the sensitive, validated value
/// needed by the importer. `credentialPayload` is never placed in status or a
/// receipt and is not retained by the coordinator.
public struct RemoteBrowserLoginValidatedAccount: Sendable {
    public let accountID: String
    public let credentialPayload: Data

    public init(accountID: String, credentialPayload: Data) {
        self.accountID = accountID
        self.credentialPayload = credentialPayload
    }
}

/// The one import operation allowed for a successfully validated ticket.
public struct RemoteBrowserLoginImportRequest: Sendable {
    public let ownerID: String
    public let accountID: String
    public let credentialPayload: Data

    public init(ownerID: String, accountID: String, credentialPayload: Data) {
        self.ownerID = ownerID
        self.accountID = accountID
        self.credentialPayload = credentialPayload
    }
}

public enum RemoteBrowserLoginCoordinatorError: Error, LocalizedError, Sendable, Equatable {
    case invalidOwner
    case invalidAccount
    case sessionAlreadyActive
    case ticketGenerationFailed
    case invalidTicket
    case ticketExpired
    case ticketAlreadyUsed
    case sessionCancelled
    case validationFailed
    case accountMismatch
    case importFailed

    public var errorDescription: String? {
        switch self {
        case .invalidOwner:
            return "The login owner is invalid."
        case .invalidAccount:
            return "The Twitch account is invalid."
        case .sessionAlreadyActive:
            return "A browser login is already active for this account."
        case .ticketGenerationFailed:
            return "A secure browser login ticket could not be created."
        case .invalidTicket:
            return "The browser login ticket is invalid."
        case .ticketExpired:
            return "The browser login ticket has expired."
        case .ticketAlreadyUsed:
            return "The browser login ticket has already been used."
        case .sessionCancelled:
            return "The browser login was cancelled."
        case .validationFailed:
            return "The browser login could not be verified."
        case .accountMismatch:
            return "The browser login belongs to a different Twitch account."
        case .importFailed:
            return "The verified browser login could not be saved."
        }
    }
}
