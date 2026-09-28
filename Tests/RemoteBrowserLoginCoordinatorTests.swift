import Foundation
import XCTest
@testable import SwiftMinerService

final class RemoteBrowserLoginCoordinatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testBeginIssuesURLSafe256BitTicketAndOwnerScopedPendingStatus() async throws {
        let clock = LockedClock(now)
        let random = DeterministicRandomBytes()
        let coordinator = makeCoordinator(clock: clock, random: random)

        let issued = try await coordinator.begin(ownerID: "discord-1", expectedAccountID: "twitch-1")

        XCTAssertTrue(issued.sessionID.hasPrefix("rbls_"))
        XCTAssertTrue(issued.ticket.hasPrefix("rblt_"))
        XCTAssertEqual(issued.ticket.dropFirst("rblt_".count).count, 43)
        XCTAssertTrue(issued.ticket.allSatisfy { character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
        })
        XCTAssertEqual(issued.expiresAt, now.addingTimeInterval(600))
        XCTAssertEqual(random.requestedCounts, [16, 32])

        let status = try unwrap(await coordinator.status(
            sessionID: issued.sessionID,
            ownerID: "discord-1"
        ))
        XCTAssertEqual(status.sessionID, issued.sessionID)
        XCTAssertEqual(status.expectedAccountID, "twitch-1")
        XCTAssertNil(status.resolvedAccountID)
        XCTAssertEqual(status.state, .pending)
        XCTAssertEqual(status.createdAt, now)
        XCTAssertEqual(status.expiresAt, issued.expiresAt)
        XCTAssertNil(status.failure)
        XCTAssertNil(status.receipt)

        let foreignStatus = await coordinator.status(
            sessionID: issued.sessionID,
            ownerID: "discord-2"
        )
        XCTAssertNil(foreignStatus)

        let encodedStatus = try JSONEncoder().encode(status)
        XCTAssertFalse(String(decoding: encodedStatus, as: UTF8.self).contains(issued.ticket))
    }

    func testBeginRejectsInvalidTargetsAndBrokenRandomSource() async {
        let clock = LockedClock(now)
        let random = DeterministicRandomBytes()
        let coordinator = makeCoordinator(clock: clock, random: random)

        await assertError(.invalidOwner) {
            _ = try await coordinator.begin(ownerID: "", expectedAccountID: "twitch-1")
        }
        await assertError(.invalidOwner) {
            _ = try await coordinator.begin(ownerID: "discord\n1", expectedAccountID: "twitch-1")
        }
        await assertError(.invalidAccount) {
            _ = try await coordinator.begin(ownerID: "discord-1", expectedAccountID: "")
        }
        await assertError(.invalidAccount) {
            _ = try await coordinator.begin(
                ownerID: "discord-1",
                expectedAccountID: String(repeating: "a", count: 257)
            )
        }

        let shortRandomCoordinator = RemoteBrowserLoginCoordinator(
            clock: clock.callAsFunction,
            randomBytes: { count in Data(repeating: 0, count: max(0, count - 1)) },
            validator: { _ in throw TestFailure.unexpected },
            importer: { _ in throw TestFailure.unexpected }
        )
        await assertError(.ticketGenerationFailed) {
            _ = try await shortRandomCoordinator.begin(ownerID: "discord-1", expectedAccountID: "twitch-1")
        }

        let throwingRandomCoordinator = RemoteBrowserLoginCoordinator(
            clock: clock.callAsFunction,
            randomBytes: { _ in throw TestFailure.secret("rng internals") },
            validator: { _ in throw TestFailure.unexpected },
            importer: { _ in throw TestFailure.unexpected }
        )
        await assertError(.ticketGenerationFailed) {
            _ = try await throwingRandomCoordinator.begin(ownerID: "discord-1", expectedAccountID: "twitch-1")
        }
    }

    func testOnlyOneActiveSessionExistsPerOwnerAccountPair() async throws {
        let clock = LockedClock(now)
        let random = DeterministicRandomBytes()
        let coordinator = makeCoordinator(clock: clock, random: random)

        _ = try await coordinator.begin(ownerID: "discord-1", expectedAccountID: "twitch-1")
        await assertError(.sessionAlreadyActive) {
            _ = try await coordinator.begin(ownerID: "discord-1", expectedAccountID: "twitch-1")
        }

        // The lock is the pair, not either identifier independently.
        _ = try await coordinator.begin(ownerID: "discord-1", expectedAccountID: "twitch-2")
        _ = try await coordinator.begin(ownerID: "discord-2", expectedAccountID: "twitch-1")

        _ = try await coordinator.begin(ownerID: "discord-1")
        await assertError(.sessionAlreadyActive) {
            _ = try await coordinator.begin(ownerID: "discord-1")
        }
    }

    func testSuccessfulSubmitValidatesAndImportsExactlyOnce() async throws {
        let clock = LockedClock(now)
        let random = DeterministicRandomBytes()
        let recorder = RequestRecorder()
        let credentialPayload = Data("validated-cookie-and-token".utf8)
        let coordinator = RemoteBrowserLoginCoordinator(
            clock: clock.callAsFunction,
            randomBytes: random.callAsFunction,
            validator: { request in
                await recorder.recordValidation(request)
                return RemoteBrowserLoginValidatedAccount(
                    accountID: "twitch-1",
                    credentialPayload: credentialPayload
                )
            },
            importer: { request in
                await recorder.recordImport(request)
            }
        )
        let submissionPayload = Data("opaque-browser-session".utf8)
        // Fresh adds intentionally have no Twitch account ID until the helper
        // completes an authenticated browser session.
        let issued = try await coordinator.begin(ownerID: "discord-1")

        clock.advance(by: 5)
        let receipt = try await coordinator.submit(ticket: issued.ticket, payload: submissionPayload)

        XCTAssertEqual(receipt.sessionID, issued.sessionID)
        XCTAssertEqual(receipt.accountID, "twitch-1")
        XCTAssertEqual(receipt.completedAt, now.addingTimeInterval(5))

        let validations = await recorder.validations
        XCTAssertEqual(validations.count, 1)
        XCTAssertEqual(validations.first?.ownerID, "discord-1")
        XCTAssertNil(validations.first?.expectedAccountID)
        XCTAssertEqual(validations.first?.payload, submissionPayload)

        let imports = await recorder.imports
        XCTAssertEqual(imports.count, 1)
        XCTAssertEqual(imports.first?.ownerID, "discord-1")
        XCTAssertEqual(imports.first?.accountID, "twitch-1")
        XCTAssertEqual(imports.first?.credentialPayload, credentialPayload)

        let status = try unwrap(await coordinator.status(
            sessionID: issued.sessionID,
            ownerID: "discord-1"
        ))
        XCTAssertEqual(status.state, .succeeded)
        XCTAssertNil(status.expectedAccountID)
        XCTAssertEqual(status.resolvedAccountID, "twitch-1")
        XCTAssertEqual(status.receipt, receipt)
        XCTAssertNil(status.failure)

        let encodedStatus = String(decoding: try JSONEncoder().encode(status), as: UTF8.self)
        XCTAssertFalse(encodedStatus.contains("opaque-browser-session"))
        XCTAssertFalse(encodedStatus.contains("validated-cookie-and-token"))

        await assertError(.ticketAlreadyUsed) {
            _ = try await coordinator.submit(ticket: issued.ticket, payload: submissionPayload)
        }
        assertEqual(await recorder.validationCount, 1)
        assertEqual(await recorder.importCount, 1)
    }

    func testUnknownTicketNeverInvokesDependencies() async {
        let clock = LockedClock(now)
        let random = DeterministicRandomBytes()
        let recorder = RequestRecorder()
        let coordinator = RemoteBrowserLoginCoordinator(
            clock: clock.callAsFunction,
            randomBytes: random.callAsFunction,
            validator: { request in
                await recorder.recordValidation(request)
                return RemoteBrowserLoginValidatedAccount(
                    accountID: request.expectedAccountID ?? "discovered-account",
                    credentialPayload: Data()
                )
            },
            importer: { request in
                await recorder.recordImport(request)
            }
        )

        await assertError(.invalidTicket) {
            _ = try await coordinator.submit(ticket: "rblt_not-a-ticket", payload: Data())
        }
        assertNil(await coordinator.result(ticket: "wrong-prefix-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
        assertNil(await coordinator.result(ticket: "rblt_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa="))
        assertEqual(await recorder.validationCount, 0)
        assertEqual(await recorder.importCount, 0)
    }

    func testTicketResultRecoversSucceededReceiptAfterLostAcknowledgement() async throws {
        let clock = LockedClock(now)
        let random = DeterministicRandomBytes()
        let coordinator = makeCoordinator(clock: clock, random: random)
        let issued = try await coordinator.begin(ownerID: "discord-secret-owner")

        let pendingResult = try unwrap(await coordinator.result(ticket: issued.ticket))
        XCTAssertEqual(pendingResult.sessionID, issued.sessionID)
        XCTAssertEqual(pendingResult.state, .pending)
        XCTAssertNil(pendingResult.receipt)
        XCTAssertNil(pendingResult.failure)

        // Imagine this return value was sent in an HTTP response that never
        // reached the helper. The helper polls with its ticket instead of
        // uploading the credential payload a second time.
        let originalReceipt = try await coordinator.submit(
            ticket: issued.ticket,
            payload: Data("credential-payload".utf8)
        )
        let recoveredResult = try unwrap(await coordinator.result(ticket: issued.ticket))
        XCTAssertEqual(recoveredResult.state, .succeeded)
        XCTAssertEqual(recoveredResult.receipt, originalReceipt)
        XCTAssertNil(recoveredResult.failure)

        let encoded = String(decoding: try JSONEncoder().encode(recoveredResult), as: UTF8.self)
        XCTAssertFalse(encoded.contains("discord-secret-owner"))
        XCTAssertFalse(encoded.contains("credential-payload"))
    }

    func testTerminalSessionAndTicketDigestAreRemovedAfterBoundedRetention() async throws {
        let clock = LockedClock(now)
        let random = DeterministicRandomBytes()
        let coordinator = makeCoordinator(clock: clock, random: random)
        let issued = try await coordinator.begin(ownerID: "discord-1", expectedAccountID: "twitch-1")
        assertTrue(await coordinator.cancel(sessionID: issued.sessionID, ownerID: "discord-1"))

        clock.advance(by: 599)
        assertNotNil(await coordinator.result(ticket: issued.ticket))
        assertNotNil(await coordinator.status(sessionID: issued.sessionID, ownerID: "discord-1"))

        clock.advance(by: 1)
        assertNil(await coordinator.result(ticket: issued.ticket))
        assertNil(await coordinator.status(sessionID: issued.sessionID, ownerID: "discord-1"))
        await assertError(.invalidTicket) {
            _ = try await coordinator.submit(ticket: issued.ticket, payload: Data())
        }
    }

    func testConcurrentClaimIsRejectedBeforeSecondValidation() async throws {
        let clock = LockedClock(now)
        let random = DeterministicRandomBytes()
        let gate = SuspensionGate()
        let recorder = RequestRecorder()
        let coordinator = RemoteBrowserLoginCoordinator(
            clock: clock.callAsFunction,
            randomBytes: random.callAsFunction,
            validator: { request in
                await recorder.recordValidation(request)
                await gate.arriveAndWait()
                return RemoteBrowserLoginValidatedAccount(
                    accountID: request.expectedAccountID ?? "discovered-account",
                    credentialPayload: Data("credential".utf8)
                )
            },
            importer: { request in
                await recorder.recordImport(request)
            }
        )
        let issued = try await coordinator.begin(ownerID: "discord-1", expectedAccountID: "twitch-1")
        let firstClaim = Task {
            try await coordinator.submit(ticket: issued.ticket, payload: Data("first".utf8))
        }

        await gate.waitForArrival()
        let inFlight = try unwrap(await coordinator.status(
            sessionID: issued.sessionID,
            ownerID: "discord-1"
        ))
        XCTAssertEqual(inFlight.state, .validating)

        await assertError(.ticketAlreadyUsed) {
            _ = try await coordinator.submit(ticket: issued.ticket, payload: Data("second".utf8))
        }
        assertEqual(await recorder.validationCount, 1)

        await gate.open()
        _ = try await firstClaim.value
        assertEqual(await recorder.validationCount, 1)
        assertEqual(await recorder.importCount, 1)
    }

    func testTicketExpiresAtExactTenMinuteBoundaryWithoutValidation() async throws {
        let clock = LockedClock(now)
        let random = DeterministicRandomBytes()
        let recorder = RequestRecorder()
        let coordinator = RemoteBrowserLoginCoordinator(
            clock: clock.callAsFunction,
            randomBytes: random.callAsFunction,
            validator: { request in
                await recorder.recordValidation(request)
                return RemoteBrowserLoginValidatedAccount(
                    accountID: request.expectedAccountID ?? "discovered-account",
                    credentialPayload: Data()
                )
            },
            importer: { request in
                await recorder.recordImport(request)
            }
        )
        let issued = try await coordinator.begin(ownerID: "discord-1", expectedAccountID: "twitch-1")

        clock.advance(by: 599)
        assertEqual(
            await coordinator.status(sessionID: issued.sessionID, ownerID: "discord-1")?.state,
            .pending
        )
        clock.advance(by: 1)
        assertEqual(
            await coordinator.status(sessionID: issued.sessionID, ownerID: "discord-1")?.state,
            .expired
        )

        await assertError(.ticketExpired) {
            _ = try await coordinator.submit(ticket: issued.ticket, payload: Data())
        }
        assertEqual(await recorder.validationCount, 0)
        assertEqual(await recorder.importCount, 0)

        // An expired session no longer blocks a fresh handoff for the pair.
        _ = try await coordinator.begin(ownerID: "discord-1", expectedAccountID: "twitch-1")
    }

    func testCancellationIsOwnerScopedAndConsumesTicket() async throws {
        let clock = LockedClock(now)
        let random = DeterministicRandomBytes()
        let coordinator = makeCoordinator(clock: clock, random: random)
        let issued = try await coordinator.begin(ownerID: "discord-1", expectedAccountID: "twitch-1")

        assertFalse(await coordinator.cancel(sessionID: issued.sessionID, ownerID: "discord-2"))
        assertEqual(
            await coordinator.status(sessionID: issued.sessionID, ownerID: "discord-1")?.state,
            .pending
        )
        assertTrue(await coordinator.cancel(sessionID: issued.sessionID, ownerID: "discord-1"))
        assertEqual(
            await coordinator.status(sessionID: issued.sessionID, ownerID: "discord-1")?.state,
            .cancelled
        )
        assertFalse(await coordinator.cancel(sessionID: issued.sessionID, ownerID: "discord-1"))

        await assertError(.sessionCancelled) {
            _ = try await coordinator.submit(ticket: issued.ticket, payload: Data())
        }

        // Cancellation deliberately permits a new ticket for the same target.
        _ = try await coordinator.begin(ownerID: "discord-1", expectedAccountID: "twitch-1")
    }

    func testCancellationDuringValidationDiscardsResultAndSkipsImport() async throws {
        let clock = LockedClock(now)
        let random = DeterministicRandomBytes()
        let gate = SuspensionGate()
        let recorder = RequestRecorder()
        let coordinator = RemoteBrowserLoginCoordinator(
            clock: clock.callAsFunction,
            randomBytes: random.callAsFunction,
            validator: { request in
                await recorder.recordValidation(request)
                await gate.arriveAndWait()
                return RemoteBrowserLoginValidatedAccount(
                    accountID: request.expectedAccountID ?? "discovered-account",
                    credentialPayload: Data("must-not-import".utf8)
                )
            },
            importer: { request in
                await recorder.recordImport(request)
            }
        )
        let issued = try await coordinator.begin(ownerID: "discord-1", expectedAccountID: "twitch-1")
        let submission = Task {
            try await coordinator.submit(ticket: issued.ticket, payload: Data())
        }

        await gate.waitForArrival()
        assertTrue(await coordinator.cancel(sessionID: issued.sessionID, ownerID: "discord-1"))
        await gate.open()

        do {
            _ = try await submission.value
            XCTFail("Expected cancellation to reject the in-flight claim")
        } catch let error as RemoteBrowserLoginCoordinatorError {
            XCTAssertEqual(error, .sessionCancelled)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        assertEqual(await recorder.validationCount, 1)
        assertEqual(await recorder.importCount, 0)
        assertEqual(
            await coordinator.status(sessionID: issued.sessionID, ownerID: "discord-1")?.state,
            .cancelled
        )
    }

    func testImportCannotBeCancelledAfterAtomicImportBegins() async throws {
        let clock = LockedClock(now)
        let random = DeterministicRandomBytes()
        let importGate = SuspensionGate()
        let recorder = RequestRecorder()
        let coordinator = RemoteBrowserLoginCoordinator(
            clock: clock.callAsFunction,
            randomBytes: random.callAsFunction,
            validator: { request in
                await recorder.recordValidation(request)
                return RemoteBrowserLoginValidatedAccount(
                    accountID: request.expectedAccountID ?? "discovered-account",
                    credentialPayload: Data("credential".utf8)
                )
            },
            importer: { request in
                await recorder.recordImport(request)
                await importGate.arriveAndWait()
            }
        )
        let issued = try await coordinator.begin(ownerID: "discord-1", expectedAccountID: "twitch-1")
        let submission = Task {
            try await coordinator.submit(ticket: issued.ticket, payload: Data())
        }

        await importGate.waitForArrival()
        let importingStatus = await coordinator.status(sessionID: issued.sessionID, ownerID: "discord-1")
        XCTAssertEqual(importingStatus?.state, .importing)
        XCTAssertEqual(importingStatus?.resolvedAccountID, "twitch-1")
        assertFalse(await coordinator.cancel(sessionID: issued.sessionID, ownerID: "discord-1"))

        await importGate.open()
        _ = try await submission.value
        assertEqual(
            await coordinator.status(sessionID: issued.sessionID, ownerID: "discord-1")?.state,
            .succeeded
        )
    }

    func testValidationFailureIsSanitizedAndCannotBeRetried() async throws {
        let clock = LockedClock(now)
        let random = DeterministicRandomBytes()
        let recorder = RequestRecorder()
        let coordinator = RemoteBrowserLoginCoordinator(
            clock: clock.callAsFunction,
            randomBytes: random.callAsFunction,
            validator: { request in
                await recorder.recordValidation(request)
                throw TestFailure.secret("access_token=top-secret-token")
            },
            importer: { request in
                await recorder.recordImport(request)
            }
        )
        let issued = try await coordinator.begin(ownerID: "discord-1", expectedAccountID: "twitch-1")

        await assertError(.validationFailed) {
            _ = try await coordinator.submit(ticket: issued.ticket, payload: Data("cookie=secret-cookie".utf8))
        }

        let status = try unwrap(await coordinator.status(
            sessionID: issued.sessionID,
            ownerID: "discord-1"
        ))
        XCTAssertEqual(status.state, .failed)
        XCTAssertEqual(status.failure?.code, .validationRejected)
        XCTAssertNil(status.receipt)
        let encodedStatus = String(decoding: try JSONEncoder().encode(status), as: UTF8.self)
        XCTAssertFalse(encodedStatus.contains("top-secret-token"))
        XCTAssertFalse(encodedStatus.contains("secret-cookie"))
        assertEqual(await recorder.importCount, 0)

        await assertError(.ticketAlreadyUsed) {
            _ = try await coordinator.submit(ticket: issued.ticket, payload: Data())
        }
        assertEqual(await recorder.validationCount, 1)
    }

    func testAccountMismatchFailsBeforeImportWithSanitizedReceiptState() async throws {
        let clock = LockedClock(now)
        let random = DeterministicRandomBytes()
        let recorder = RequestRecorder()
        let coordinator = RemoteBrowserLoginCoordinator(
            clock: clock.callAsFunction,
            randomBytes: random.callAsFunction,
            validator: { request in
                await recorder.recordValidation(request)
                return RemoteBrowserLoginValidatedAccount(
                    accountID: "someone-elses-account",
                    credentialPayload: Data("credential".utf8)
                )
            },
            importer: { request in
                await recorder.recordImport(request)
            }
        )
        let issued = try await coordinator.begin(ownerID: "discord-1", expectedAccountID: "twitch-1")

        await assertError(.accountMismatch) {
            _ = try await coordinator.submit(ticket: issued.ticket, payload: Data())
        }

        let status = try unwrap(await coordinator.status(
            sessionID: issued.sessionID,
            ownerID: "discord-1"
        ))
        XCTAssertEqual(status.state, .failed)
        XCTAssertEqual(status.failure?.code, .accountMismatch)
        XCTAssertNil(status.receipt)
        assertEqual(await recorder.importCount, 0)
    }

    func testFreshAddAcceptsDiscoveredAccountButRejectsInvalidDiscoveredIdentity() async throws {
        let clock = LockedClock(now)
        let random = DeterministicRandomBytes()
        let recorder = RequestRecorder()
        let validCoordinator = RemoteBrowserLoginCoordinator(
            clock: clock.callAsFunction,
            randomBytes: random.callAsFunction,
            validator: { request in
                XCTAssertNil(request.expectedAccountID)
                return RemoteBrowserLoginValidatedAccount(
                    accountID: "discovered-twitch-id",
                    credentialPayload: Data("credential".utf8)
                )
            },
            importer: { request in
                await recorder.recordImport(request)
            }
        )
        let validTicket = try await validCoordinator.begin(ownerID: "discord-1")
        let receipt = try await validCoordinator.submit(ticket: validTicket.ticket, payload: Data())
        XCTAssertEqual(receipt.accountID, "discovered-twitch-id")
        assertEqual(await recorder.imports.first?.accountID, "discovered-twitch-id")

        let invalidCoordinator = RemoteBrowserLoginCoordinator(
            clock: clock.callAsFunction,
            randomBytes: random.callAsFunction,
            validator: { _ in
                RemoteBrowserLoginValidatedAccount(
                    accountID: "",
                    credentialPayload: Data("must-not-import".utf8)
                )
            },
            importer: { request in
                await recorder.recordImport(request)
            }
        )
        let invalidTicket = try await invalidCoordinator.begin(ownerID: "discord-2")
        await assertError(.validationFailed) {
            _ = try await invalidCoordinator.submit(ticket: invalidTicket.ticket, payload: Data())
        }
        assertEqual(await recorder.importCount, 1)
        let invalidStatus = try unwrap(await invalidCoordinator.status(
            sessionID: invalidTicket.sessionID,
            ownerID: "discord-2"
        ))
        XCTAssertEqual(invalidStatus.failure?.code, .validationRejected)
        XCTAssertNil(invalidStatus.resolvedAccountID)
    }

    func testImportFailureIsSanitizedAndCannotCauseASecondImport() async throws {
        let clock = LockedClock(now)
        let random = DeterministicRandomBytes()
        let recorder = RequestRecorder()
        let coordinator = RemoteBrowserLoginCoordinator(
            clock: clock.callAsFunction,
            randomBytes: random.callAsFunction,
            validator: { request in
                await recorder.recordValidation(request)
                return RemoteBrowserLoginValidatedAccount(
                    accountID: request.expectedAccountID ?? "discovered-account",
                    credentialPayload: Data("credential=super-secret".utf8)
                )
            },
            importer: { request in
                await recorder.recordImport(request)
                throw TestFailure.secret("database contained super-secret")
            }
        )
        let issued = try await coordinator.begin(ownerID: "discord-1", expectedAccountID: "twitch-1")

        await assertError(.importFailed) {
            _ = try await coordinator.submit(ticket: issued.ticket, payload: Data())
        }

        let status = try unwrap(await coordinator.status(
            sessionID: issued.sessionID,
            ownerID: "discord-1"
        ))
        XCTAssertEqual(status.state, .failed)
        XCTAssertEqual(status.failure?.code, .importFailed)
        XCTAssertNil(status.receipt)
        let encodedStatus = String(decoding: try JSONEncoder().encode(status), as: UTF8.self)
        XCTAssertFalse(encodedStatus.contains("super-secret"))

        await assertError(.ticketAlreadyUsed) {
            _ = try await coordinator.submit(ticket: issued.ticket, payload: Data())
        }
        assertEqual(await recorder.validationCount, 1)
        assertEqual(await recorder.importCount, 1)
    }

    private func makeCoordinator(
        clock: LockedClock,
        random: DeterministicRandomBytes
    ) -> RemoteBrowserLoginCoordinator {
        RemoteBrowserLoginCoordinator(
            clock: clock.callAsFunction,
            randomBytes: random.callAsFunction,
            validator: { request in
                RemoteBrowserLoginValidatedAccount(
                    accountID: request.expectedAccountID ?? "discovered-account",
                    credentialPayload: request.payload
                )
            },
            importer: { _ in }
        )
    }

    private func assertError(
        _ expected: RemoteBrowserLoginCoordinatorError,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as RemoteBrowserLoginCoordinatorError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    /// XCTest's assertion arguments are synchronous autoclosures, so actor reads must finish
    /// before they enter XCTest. These helpers deliberately take ordinary, eagerly evaluated
    /// arguments and preserve the original call site's source location.
    private func unwrap<T>(
        _ value: T?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }

    private func assertEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func assertTrue(
        _ value: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(value, file: file, line: line)
    }

    private func assertFalse(
        _ value: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(value, file: file, line: line)
    }

    private func assertNil<T>(
        _ value: T?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(value, file: file, line: line)
    }

    private func assertNotNil<T>(
        _ value: T?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNotNil(value, file: file, line: line)
    }
}

private final class LockedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    func callAsFunction() -> Date {
        lock.withLock { date }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock {
            date = date.addingTimeInterval(interval)
        }
    }
}

private final class DeterministicRandomBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var nextByte: UInt8 = 1
    private var counts: [Int] = []

    var requestedCounts: [Int] {
        lock.withLock { counts }
    }

    func callAsFunction(_ count: Int) -> Data {
        lock.withLock {
            counts.append(count)
            let bytes = (0..<count).map { offset in
                nextByte &+ UInt8(truncatingIfNeeded: offset)
            }
            nextByte &+= UInt8(truncatingIfNeeded: count)
            return Data(bytes)
        }
    }
}

private actor RequestRecorder {
    private(set) var validations: [RemoteBrowserLoginValidationRequest] = []
    private(set) var imports: [RemoteBrowserLoginImportRequest] = []

    var validationCount: Int { validations.count }
    var importCount: Int { imports.count }

    func recordValidation(_ request: RemoteBrowserLoginValidationRequest) {
        validations.append(request)
    }

    func recordImport(_ request: RemoteBrowserLoginImportRequest) {
        imports.append(request)
    }
}

private actor SuspensionGate {
    private var hasArrived = false
    private var isOpen = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        hasArrived = true
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }

        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            openWaiters.append(continuation)
        }
    }

    func waitForArrival() async {
        guard !hasArrived else { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiters = openWaiters
        openWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private enum TestFailure: Error {
    case unexpected
    case secret(String)
}
