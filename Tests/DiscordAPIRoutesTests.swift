import Foundation
import XCTest
@testable import SwiftMinerService
import SwiftMinerCore

final class DiscordAPIRoutesTests: XCTestCase {
    private let discordUserId = "123456789012345678"

    func testRegisterUserIsIdempotentAndReturnsDMState() async throws {
        let harness = try await RouteHarness()

        let first = await harness.router.handle(HTTPRequest(
            method: "POST",
            path: "/v1/users",
            headers: [:],
            body: #"{"discordUserId":"123456789012345678"}"#.data(using: .utf8)!
        ))
        XCTAssertEqual(first.statusCode, 201)

        let firstPayload = try decodeJSON(first.body)
        XCTAssertEqual(firstPayload["status"] as? String, "registered")
        XCTAssertEqual(firstPayload["discord_user_id"] as? String, discordUserId)

        let second = await harness.router.handle(HTTPRequest(
            method: "POST",
            path: "/v1/users",
            headers: [:],
            body: #"{"discordUserId":"123456789012345678"}"#.data(using: .utf8)!
        ))
        XCTAssertEqual(second.statusCode, 200)

        let secondPayload = try decodeJSON(second.body)
        XCTAssertEqual(secondPayload["status"] as? String, "already_registered")
        let dmState = try XCTUnwrap(secondPayload["dm_state"] as? [String: Any])
        XCTAssertEqual(dmState["has_received_welcome_message"] as? Bool, false)
        XCTAssertEqual(dmState["has_completed_initial_dm_flow"] as? Bool, false)
    }

    func testUpdateDMStatePreservesUnspecifiedFields() async throws {
        let harness = try await RouteHarness()
        try await harness.registerUser(discordUserId)

        let response = await harness.router.handle(HTTPRequest(
            method: "PATCH",
            path: "/v1/users/\(discordUserId)/dm-state",
            headers: [:],
            body: #"{"has_received_welcome_message":true}"#.data(using: .utf8)!
        ))
        XCTAssertEqual(response.statusCode, 200)

        let payload = try decodeJSON(response.body)
        let dmState = try XCTUnwrap(payload["dm_state"] as? [String: Any])
        XCTAssertEqual(dmState["has_received_welcome_message"] as? Bool, true)
        XCTAssertEqual(dmState["has_completed_initial_dm_flow"] as? Bool, false)
    }

    func testMinerControlRequiresRegisteredUserAndDelegatesValidActions() async throws {
        let harness = try await RouteHarness()
        let recorder = MinerControlRecorder()
        await harness.routes.setOnMinerControl { discordUserId, action in
            await recorder.record(discordUserId: discordUserId, action: action)
            return MinerControlResponse(
                ok: true,
                action: action.rawValue,
                state: "WATCHING",
                twitchUsername: "miner",
                message: "Watching THE FINALS"
            )
        }

        let missingUser = await harness.router.handle(HTTPRequest(
            method: "POST",
            path: "/v1/users/\(discordUserId)/miner/status",
            headers: [:],
            body: Data()
        ))
        XCTAssertEqual(missingUser.statusCode, 404)
        XCTAssertEqual(await recorder.callCount(), 0)

        try await harness.registerUser(discordUserId)

        let response = await harness.router.handle(HTTPRequest(
            method: "POST",
            path: "/v1/users/\(discordUserId)/miner/status",
            headers: [:],
            body: Data()
        ))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(await recorder.actions(), [.status])

        let payload = try decodeJSON(response.body)
        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(payload["state"] as? String, "WATCHING")
        XCTAssertEqual(payload["twitchUsername"] as? String, "miner")
    }

    func testMinerControlReturnsConflictWhenDelegateRejectsAction() async throws {
        let harness = try await RouteHarness()
        try await harness.registerUser(discordUserId)
        await harness.routes.setOnMinerControl { _, action in
            MinerControlResponse(
                ok: false,
                action: action.rawValue,
                state: "not_linked",
                twitchUsername: nil,
                message: "No linked Twitch account was found."
            )
        }

        let response = await harness.router.handle(HTTPRequest(
            method: "POST",
            path: "/v1/users/\(discordUserId)/miner/resume",
            headers: [:],
            body: Data()
        ))
        XCTAssertEqual(response.statusCode, 409)

        let payload = try decodeJSON(response.body)
        XCTAssertEqual(payload["ok"] as? Bool, false)
        XCTAssertEqual(payload["state"] as? String, "not_linked")
    }
}

private final class RouteHarness {
    let manager: SQLiteManager
    let router: HTTPRouter
    let routes: DiscordAPIRoutes
    private let databaseURL: URL

    init() async throws {
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftMiner-DiscordAPIRoutesTests-\(UUID().uuidString).sqlite")
        manager = SQLiteManager(databaseURL: databaseURL)
        try await manager.open()
        router = HTTPRouter()
        routes = DiscordAPIRoutes(
            manager: manager,
            projectionBuilder: DiscordProjectionBuilder(manager: manager),
            apiKey: "test-api-key"
        )
        await routes.configure(router)
    }

    deinit {
        Task { [manager, databaseURL] in
            await manager.close()
            try? FileManager.default.removeItem(at: databaseURL)
        }
    }

    func registerUser(_ discordUserId: String) async throws {
        let response = await router.handle(HTTPRequest(
            method: "POST",
            path: "/v1/users",
            headers: [:],
            body: #"{"discordUserId":"\#(discordUserId)"}"#.data(using: .utf8)!
        ))
        XCTAssertTrue([200, 201].contains(response.statusCode))
    }
}

private actor MinerControlRecorder {
    private var calls: [(discordUserId: String, action: MinerControlAction)] = []

    func record(discordUserId: String, action: MinerControlAction) {
        calls.append((discordUserId, action))
    }

    func callCount() -> Int {
        calls.count
    }

    func actions() -> [MinerControlAction] {
        calls.map(\.action)
    }
}

private func decodeJSON(_ data: Data) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
