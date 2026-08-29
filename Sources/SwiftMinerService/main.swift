import Foundation
import SwiftMinerCore
import SwiftMinerService

// MARK: - Configuration

let defaults = UserDefaults.standard
let storedEndpoint = defaults.string(forKey: "swiftMinerAPIEndpoint") ?? "http://127.0.0.1:8080"
let storedPort = URL(string: storedEndpoint)?.port
let port = UInt16(ProcessInfo.processInfo.environment["SWIFTMINER_API_PORT"] ?? "")
    ?? storedPort.flatMap(UInt16.init)
    ?? 8080
let apiKey = ProcessInfo.processInfo.environment["SWIFTMINER_API_KEY"]
    ?? defaults.string(forKey: "swiftMinerAPIKey")
    ?? ""

guard apiKey.count >= 32, apiKey != "dev-key-change-in-production" else {
    print("[SwiftMinerService] SWIFTMINER_API_KEY must be set to a non-default secret of at least 32 characters.")
    exit(1)
}

// MARK: - Database Setup

let fileManager = FileManager.default
let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
let dbDir = appSupport.appendingPathComponent("SwiftMiner", isDirectory: true)
try? fileManager.createDirectory(at: dbDir, withIntermediateDirectories: true)
let dbURL = dbDir.appendingPathComponent("swiftminer.db")

let manager = SQLiteManager(databaseURL: dbURL)
do {
    try await manager.open()
    print("[SwiftMinerService] Database opened at \(dbURL.path)")
} catch {
    print("[SwiftMinerService] Failed to open database: \(error)")
    exit(1)
}

// MARK: - Services

let projectionBuilder = DiscordProjectionBuilder(manager: manager)
let apiRoutes = DiscordAPIRoutes(manager: manager, projectionBuilder: projectionBuilder, apiKey: apiKey)
let router = HTTPRouter()

// MARK: - Optional Web Dashboard
//
// Activated only when Discord OAuth credentials + a public base URL are
// configured. When unset (the default), no web routes are registered and the
// server exposes nothing beyond the existing Bot-key API + /health.
let webConfig = WebDashboardConfig.fromEnvironment(defaults)
let webRoutes: WebDashboardRoutes? = webConfig.map {
    WebDashboardRoutes(config: $0, manager: manager, apiRoutes: apiRoutes)
}

// MARK: - Server Startup

let server = HTTPAPIServer(
    port: port,
    apiKey: apiKey,
    router: router,
    publicPathPrefixes: webConfig != nil ? WebDashboardConfig.publicPrefixes : [],
    publicExactPaths: webConfig != nil ? WebDashboardConfig.publicExactPaths : []
)

Task {
    await apiRoutes.configure(router)
    if let webRoutes {
        await webRoutes.configure(router)
        print("[SwiftMinerService] Web dashboard enabled at \(webConfig!.normalisedBase ?? "local-only")")
    }
    do {
        try await server.start()
    } catch {
        print("[SwiftMinerService] Failed to start server: \(error)")
        exit(1)
    }
}

print("SwiftMinerService v\(SwiftMinerCore.version) starting...")
print("[SwiftMinerService] Press Ctrl+C to stop.")

// Keep the service running
while true {
    try? await Task.sleep(nanoseconds: 1_000_000_000)
}
