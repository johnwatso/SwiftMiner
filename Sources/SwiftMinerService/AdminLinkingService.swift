import Foundation
import SQLite3
import SwiftMinerCore

// MARK: - SQLite Implementation

public actor SQLiteAdminLinkingService: AdminLinkingService {
    private let manager: SQLiteManager
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        return e
    }()

    public init(manager: SQLiteManager) {
        self.manager = manager
    }

    public func getUnownedAccounts() async -> [Account] {
        do {
            return try await manager.query { db in
                let sql = "SELECT twitch_id, username, owner_discord_id, access_token, refresh_token, token_expiry, scopes FROM twitch_accounts WHERE owner_discord_id IS NULL;"
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                    return []
                }
                defer { sqlite3_finalize(statement) }

                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)

                var accounts: [Account] = []
                while sqlite3_step(statement) == SQLITE_ROW {
                    let id = String(cString: sqlite3_column_text(statement, 0))
                    let username = String(cString: sqlite3_column_text(statement, 1))
                    let ownerId: String? = {
                        if let ptr = sqlite3_column_text(statement, 2) {
                            return String(cString: ptr)
                        }
                        return nil
                    }()
                    let accessToken = String(cString: sqlite3_column_text(statement, 3))
                    let refreshToken = sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? ""
                    let expiryString = String(cString: sqlite3_column_text(statement, 5))
                    let tokenExpiry = dateFormatter.date(from: expiryString) ?? Date()
                    let scopesString = sqlite3_column_text(statement, 6).map { String(cString: $0) } ?? ""
                    let scopes = scopesString.components(separatedBy: ",")

                    accounts.append(Account(
                        id: id,
                        username: username,
                        ownerDiscordId: ownerId,
                        accessToken: accessToken,
                        refreshToken: refreshToken,
                        tokenExpiry: tokenExpiry,
                        scopes: scopes
                    ))
                }
                return accounts
            }
        } catch {
            return []
        }
    }

    public func assignAccount(_ assignment: AdminAccountAssignment, policy: ReassignmentPolicy) async -> AdminLinkingResult {
        // Discord ID validation (17-19 digits)
        guard assignment.discordId.count >= 17 && assignment.discordId.count <= 19,
              assignment.discordId.allSatisfy({ $0.isNumber }) else {
            return .invalidDiscordId
        }

        do {
            return try await manager.transaction { db in
                // 1. Re-validate ownership & existence
                var statement: OpaquePointer?
                let selectSql = "SELECT owner_discord_id, username FROM twitch_accounts WHERE twitch_id = ?;"
                guard sqlite3_prepare_v2(db, selectSql, -1, &statement, nil) == SQLITE_OK else {
                    throw self.dbError(db)
                }
                defer { sqlite3_finalize(statement) }
                sqlite3_bind_text(statement, 1, assignment.twitchAccountId, -1, SQLITE_TRANSIENT)

                guard sqlite3_step(statement) == SQLITE_ROW else {
                    return .notFound
                }

                let currentOwner: String? = {
                    if let ptr = sqlite3_column_text(statement, 0) {
                        return String(cString: ptr)
                    }
                    return nil
                }()
                let twitchUsername = String(cString: sqlite3_column_text(statement, 1))

                // Idempotency: already owned by this user
                if currentOwner == assignment.discordId {
                    return .linked(discordId: assignment.discordId, previousDiscordId: nil, userWasCreated: false, wasReassignment: false)
                }

                // Stale-owner protection
                if case .allowConfirmed(let expected) = policy {
                    if currentOwner != expected {
                        return .alreadyLinked(currentDiscordId: currentOwner ?? "unowned")
                    }
                } else if case .rejectIfOwned = policy, let owner = currentOwner {
                    // RejectIfOwned check
                    return .alreadyLinked(currentDiscordId: owner)
                }

                let wasReassignment = currentOwner != nil && currentOwner != assignment.discordId
                let previousOwner = wasReassignment ? currentOwner : nil

                // 2. Create MinerUser if needed (status = registered)
                var userWasCreated = false
                let userCheckSql = "SELECT discord_id FROM miner_users WHERE discord_id = ?;"
                var userStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, userCheckSql, -1, &userStmt, nil) == SQLITE_OK else { throw self.dbError(db) }
                defer { sqlite3_finalize(userStmt) }
                sqlite3_bind_text(userStmt, 1, assignment.discordId, -1, SQLITE_TRANSIENT)
                
                let userStep = sqlite3_step(userStmt)
                if userStep == SQLITE_DONE {
                    // User not found, create
                    let insertUserSql = "INSERT INTO miner_users (discord_id, status) VALUES (?, 'registered');"
                    var insertUserStmt: OpaquePointer?
                    guard sqlite3_prepare_v2(db, insertUserSql, -1, &insertUserStmt, nil) == SQLITE_OK else { throw self.dbError(db) }
                    defer { sqlite3_finalize(insertUserStmt) }
                    sqlite3_bind_text(insertUserStmt, 1, assignment.discordId, -1, SQLITE_TRANSIENT)
                    guard sqlite3_step(insertUserStmt) == SQLITE_DONE else { throw self.dbError(db) }
                    userWasCreated = true
                } else if userStep != SQLITE_ROW {
                    throw self.dbError(db)
                }

                // 3. Update ownership
                let updateSql = "UPDATE twitch_accounts SET owner_discord_id = ?, link_state = 'linked' WHERE twitch_id = ?;"
                var updateStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, updateSql, -1, &updateStmt, nil) == SQLITE_OK else { throw self.dbError(db) }
                defer { sqlite3_finalize(updateStmt) }
                sqlite3_bind_text(updateStmt, 1, assignment.discordId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(updateStmt, 2, assignment.twitchAccountId, -1, SQLITE_TRANSIENT)
                guard sqlite3_step(updateStmt) == SQLITE_DONE else { throw self.dbError(db) }

                // 4. Write audit
                let auditMetadata = AdminAuditMetadata(
                    twitchUsername: twitchUsername,
                    userWasCreated: userWasCreated,
                    wasReassignment: wasReassignment
                )
                let metadataJson = (try? self.encoder.encode(auditMetadata)).flatMap { String(data: $0, encoding: .utf8) }

                let auditId = UUID().uuidString
                let auditSql = """
                INSERT INTO admin_audit_log (id, action_type, operator_id, twitch_id, from_discord_id, to_discord_id, metadata_json)
                VALUES (?, 'account_assigned', ?, ?, ?, ?, ?);
                """
                var auditStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, auditSql, -1, &auditStmt, nil) == SQLITE_OK else { throw self.dbError(db) }
                defer { sqlite3_finalize(auditStmt) }
                sqlite3_bind_text(auditStmt, 1, auditId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(auditStmt, 2, assignment.operatorIdentity.stringValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(auditStmt, 3, assignment.twitchAccountId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(auditStmt, 4, previousOwner, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(auditStmt, 5, assignment.discordId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(auditStmt, 6, metadataJson, -1, SQLITE_TRANSIENT)
                guard sqlite3_step(auditStmt) == SQLITE_DONE else { throw self.dbError(db) }

                // 5. Emit user.linked event (Insert into event_outbox)
                let eventPayload = UserLinkedEventPayload(
                    discordId: assignment.discordId,
                    twitchId: assignment.twitchAccountId,
                    twitchUsername: twitchUsername,
                    linkMethod: "admin_assignment",
                    previousOwnerDiscordId: previousOwner,
                    userWasCreated: userWasCreated,
                    wasReassignment: wasReassignment
                )
                let payloadData = try self.encoder.encode(eventPayload)
                let payloadString = String(data: payloadData, encoding: .utf8) ?? "{}"

                let eventId = UUID().uuidString
                let eventType = "user.linked"
                let idempotencyKey = "user.linked:discord:\(assignment.discordId):twitch:\(assignment.twitchAccountId)"
                let eventSql = """
                INSERT OR IGNORE INTO event_outbox (id, event_type, payload, idempotency_key, status)
                VALUES (?, ?, ?, ?, 'pending');
                """
                var eventStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, eventSql, -1, &eventStmt, nil) == SQLITE_OK else { throw self.dbError(db) }
                defer { sqlite3_finalize(eventStmt) }
                sqlite3_bind_text(eventStmt, 1, eventId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(eventStmt, 2, eventType, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(eventStmt, 3, payloadString, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(eventStmt, 4, idempotencyKey, -1, SQLITE_TRANSIENT)
                guard sqlite3_step(eventStmt) == SQLITE_DONE else { throw self.dbError(db) }

                return .linked(
                    discordId: assignment.discordId,
                    previousDiscordId: previousOwner,
                    userWasCreated: userWasCreated,
                    wasReassignment: wasReassignment
                )
            }
        } catch {
            return .internalError(error.localizedDescription)
        }
    }

    public func registerUser(discordId: String, operatorIdentity: OperatorIdentity) async -> AdminUserRegistrationResult {
        // Discord ID validation (17-19 digits)
        guard discordId.count >= 17 && discordId.count <= 19,
              discordId.allSatisfy({ $0.isNumber }) else {
            return .invalidDiscordId
        }

        do {
            return try await manager.transaction { db in
                // 1. Check if user already exists
                let userCheckSql = "SELECT discord_id FROM miner_users WHERE discord_id = ?;"
                var userStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, userCheckSql, -1, &userStmt, nil) == SQLITE_OK else { throw self.dbError(db) }
                defer { sqlite3_finalize(userStmt) }
                sqlite3_bind_text(userStmt, 1, discordId, -1, SQLITE_TRANSIENT)

                if sqlite3_step(userStmt) == SQLITE_ROW {
                    return .alreadyRegistered(discordId: discordId)
                }

                // 2. Insert new user
                let insertUserSql = "INSERT INTO miner_users (discord_id, status) VALUES (?, 'registered');"
                var insertUserStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, insertUserSql, -1, &insertUserStmt, nil) == SQLITE_OK else { throw self.dbError(db) }
                defer { sqlite3_finalize(insertUserStmt) }
                sqlite3_bind_text(insertUserStmt, 1, discordId, -1, SQLITE_TRANSIENT)
                guard sqlite3_step(insertUserStmt) == SQLITE_DONE else { throw self.dbError(db) }

                // 3. Write audit row
                let auditId = UUID().uuidString
                let auditSql = """
                INSERT INTO admin_audit_log (id, action_type, operator_id, twitch_id, from_discord_id, to_discord_id, metadata_json)
                VALUES (?, 'user_registered', ?, NULL, NULL, ?, NULL);
                """
                var auditStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, auditSql, -1, &auditStmt, nil) == SQLITE_OK else { throw self.dbError(db) }
                defer { sqlite3_finalize(auditStmt) }
                sqlite3_bind_text(auditStmt, 1, auditId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(auditStmt, 2, operatorIdentity.stringValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(auditStmt, 3, discordId, -1, SQLITE_TRANSIENT)
                guard sqlite3_step(auditStmt) == SQLITE_DONE else { throw self.dbError(db) }

                // 4. Emit user.registered event
                let eventPayload = UserRegisteredEventPayload(
                    discordId: discordId,
                    registeredBy: operatorIdentity.stringValue
                )
                let payloadData = try self.encoder.encode(eventPayload)
                let payloadString = String(data: payloadData, encoding: .utf8) ?? "{}"

                let eventId = UUID().uuidString
                let registeredIdempotencyKey = "user.registered:discord:\(discordId)"
                let eventSql = """
                INSERT OR IGNORE INTO event_outbox (id, event_type, payload, idempotency_key, status)
                VALUES (?, 'user.registered', ?, ?, 'pending');
                """
                var eventStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, eventSql, -1, &eventStmt, nil) == SQLITE_OK else { throw self.dbError(db) }
                defer { sqlite3_finalize(eventStmt) }
                sqlite3_bind_text(eventStmt, 1, eventId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(eventStmt, 2, payloadString, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(eventStmt, 3, registeredIdempotencyKey, -1, SQLITE_TRANSIENT)
                guard sqlite3_step(eventStmt) == SQLITE_DONE else { throw self.dbError(db) }

                return .registered(discordId: discordId)
            }
        } catch {
            return .internalError(error.localizedDescription)
        }
    }

    public func getAllUsers() async -> [MinerUser] {
        do {
            return try await manager.query { db in
                let sql = "SELECT discord_id, status, created_at FROM miner_users ORDER BY created_at DESC;"
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                    return []
                }
                defer { sqlite3_finalize(statement) }

                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)

                var users: [MinerUser] = []
                while sqlite3_step(statement) == SQLITE_ROW {
                    let discordId = String(cString: sqlite3_column_text(statement, 0))
                    let statusString = String(cString: sqlite3_column_text(statement, 1))
                    let status = MinerUser.UserStatus(rawValue: statusString) ?? .registered
                    let createdAtString = String(cString: sqlite3_column_text(statement, 2))
                    let createdAt = dateFormatter.date(from: createdAtString) ?? Date()

                    users.append(MinerUser(
                        discordId: discordId,
                        status: status,
                        createdAt: createdAt
                    ))
                }
                return users
            }
        } catch {
            return []
        }
    }

    public func getAccounts(for discordId: String) async -> [Account] {
        do {
            return try await manager.query { db in
                let sql = "SELECT twitch_id, username, owner_discord_id, access_token, refresh_token, token_expiry, scopes FROM twitch_accounts WHERE owner_discord_id = ?;"
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                    return []
                }
                defer { sqlite3_finalize(statement) }
                sqlite3_bind_text(statement, 1, discordId, -1, SQLITE_TRANSIENT)

                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)

                var accounts: [Account] = []
                while sqlite3_step(statement) == SQLITE_ROW {
                    let id = String(cString: sqlite3_column_text(statement, 0))
                    let username = String(cString: sqlite3_column_text(statement, 1))
                    let ownerId: String? = {
                        if let ptr = sqlite3_column_text(statement, 2) {
                            return String(cString: ptr)
                        }
                        return nil
                    }()
                    let accessToken = String(cString: sqlite3_column_text(statement, 3))
                    let refreshToken = sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? ""
                    let expiryString = String(cString: sqlite3_column_text(statement, 5))
                    let tokenExpiry = dateFormatter.date(from: expiryString) ?? Date()
                    let scopesString = sqlite3_column_text(statement, 6).map { String(cString: $0) } ?? ""
                    let scopes = scopesString.components(separatedBy: ",")

                    accounts.append(Account(
                        id: id,
                        username: username,
                        ownerDiscordId: ownerId,
                        accessToken: accessToken,
                        refreshToken: refreshToken,
                        tokenExpiry: tokenExpiry,
                        scopes: scopes
                    ))
                }
                return accounts
            }
        } catch {
            return []
        }
    }

    public func unlinkAccount(twitchAccountId: String, operatorIdentity: OperatorIdentity) async -> AdminUnlinkResult {
        do {
            return try await manager.transaction { db in
                // 1. Fetch current owner
                let selectSql = "SELECT owner_discord_id FROM twitch_accounts WHERE twitch_id = ?;"
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, selectSql, -1, &stmt, nil) == SQLITE_OK else { throw self.dbError(db) }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, twitchAccountId, -1, SQLITE_TRANSIENT)

                guard sqlite3_step(stmt) == SQLITE_ROW else { return .notFound }

                guard let ownerPtr = sqlite3_column_text(stmt, 0) else { return .notLinked }
                let previousOwner = String(cString: ownerPtr)

                // 2. Clear ownership
                let updateSql = "UPDATE twitch_accounts SET owner_discord_id = NULL, link_state = 'unlinked' WHERE twitch_id = ?;"
                var updateStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, updateSql, -1, &updateStmt, nil) == SQLITE_OK else { throw self.dbError(db) }
                defer { sqlite3_finalize(updateStmt) }
                sqlite3_bind_text(updateStmt, 1, twitchAccountId, -1, SQLITE_TRANSIENT)
                guard sqlite3_step(updateStmt) == SQLITE_DONE else { throw self.dbError(db) }

                // 3. Audit row
                let auditId = UUID().uuidString
                let auditSql = """
                INSERT INTO admin_audit_log (id, action_type, operator_id, twitch_id, from_discord_id, to_discord_id, metadata_json)
                VALUES (?, 'account_unlinked', ?, ?, ?, NULL, NULL);
                """
                var auditStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, auditSql, -1, &auditStmt, nil) == SQLITE_OK else { throw self.dbError(db) }
                defer { sqlite3_finalize(auditStmt) }
                sqlite3_bind_text(auditStmt, 1, auditId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(auditStmt, 2, operatorIdentity.stringValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(auditStmt, 3, twitchAccountId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(auditStmt, 4, previousOwner, -1, SQLITE_TRANSIENT)
                guard sqlite3_step(auditStmt) == SQLITE_DONE else { throw self.dbError(db) }

                return .unlinked(previousDiscordId: previousOwner)
            }
        } catch {
            return .internalError(error.localizedDescription)
        }
    }

    nonisolated private func dbError(_ db: OpaquePointer?) -> Error {
        let message = sqlite3_errmsg(db).map { String(cString: $0) } ?? "Unknown SQLite error"
        return NSError(domain: "SQLiteAdminLinkingService", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
