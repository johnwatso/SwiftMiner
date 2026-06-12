import Foundation
import Network

// MARK: - HTTP Types

public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data
    public let queryParams: [String: String]

    public init(method: String, path: String, headers: [String: String], body: Data, queryParams: [String: String] = [:]) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
        self.queryParams = queryParams
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public static func json<T: Encodable>(_ value: T, statusCode: Int = 200) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .useDefaultKeys
        let data = (try? encoder.encode(value)) ?? Data()
        var headers = [
            "Content-Type": "application/json",
            "Content-Length": "\(data.count)",
            "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0"
        ]
        return HTTPResponse(statusCode: statusCode, headers: headers, body: data)
    }

    public static func error(code: String, message: String, statusCode: Int) -> HTTPResponse {
        let obj: [String: Any] = ["error": code, "message": message]
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        var headers = [
            "Content-Type": "application/json",
            "Content-Length": "\(data.count)",
            "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0"
        ]
        return HTTPResponse(statusCode: statusCode, headers: headers, body: data)
    }

    public static func redirect(to location: String, setCookie: String? = nil) -> HTTPResponse {
        var headers = ["Location": location, "Content-Length": "0"]
        if let setCookie { headers["Set-Cookie"] = setCookie }
        return HTTPResponse(statusCode: 302, headers: headers)
    }

    public static func html(_ markup: String, statusCode: Int = 200, setCookie: String? = nil) -> HTTPResponse {
        let data = Data(markup.utf8)
        var headers = [
            "Content-Type": "text/html; charset=utf-8",
            "Content-Length": "\(data.count)",
            // The dashboard renders only data the session owner already controls;
            // a strict CSP keeps the surface minimal regardless.
            "Content-Security-Policy": "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:",
            "X-Content-Type-Options": "nosniff",
            "Referrer-Policy": "no-referrer",
            "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0"
        ]
        if let setCookie { headers["Set-Cookie"] = setCookie }
        return HTTPResponse(statusCode: statusCode, headers: headers, body: data)
    }

    public static let notFound = HTTPResponse.error(code: "not_found", message: "Resource not found.", statusCode: 404)
    public static let methodNotAllowed = HTTPResponse.error(code: "method_not_allowed", message: "Method not allowed.", statusCode: 405)
    public static let unauthorized = HTTPResponse.error(code: "unauthorized", message: "Invalid or missing Authorization header.", statusCode: 401)
    public static let badRequest = HTTPResponse.error(code: "bad_request", message: "Bad request.", statusCode: 400)
}

// MARK: - Router

public struct HTTPRoute: Sendable {
    public let method: String
    public let pattern: String
    public let handler: @Sendable (HTTPRequest, [String: String]) async -> HTTPResponse

    public init(method: String, pattern: String, handler: @escaping @Sendable (HTTPRequest, [String: String]) async -> HTTPResponse) {
        self.method = method
        self.pattern = pattern
        self.handler = handler
    }
}

public actor HTTPRouter {
    private var routes: [HTTPRoute] = []

    public init() {}

    public func register(_ route: HTTPRoute) {
        routes.append(route)
    }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        for route in routes {
            guard route.method.uppercased() == request.method.uppercased() else { continue }
            if let params = match(pattern: route.pattern, path: request.path) {
                return await route.handler(request, params)
            }
        }
        return .notFound
    }

    private func match(pattern: String, path: String) -> [String: String]? {
        let patternParts = pattern.split(separator: "/").map(String.init)
        let pathParts = path.split(separator: "/").map(String.init)

        guard patternParts.count == pathParts.count else { return nil }

        var params: [String: String] = [:]
        for (p, v) in zip(patternParts, pathParts) {
            if p.hasPrefix(":") {
                let key = String(p.dropFirst())
                params[key] = v
            } else if p != v {
                return nil
            }
        }
        return params
    }
}

// MARK: - Server

public actor HTTPAPIServer {
    private let port: UInt16
    private let router: HTTPRouter
    private var listener: NWListener?
    private let apiKey: String
    private let publicPathPrefixes: [String]
    private let publicExactPaths: Set<String>
    private var isRunning = false

    /// - Parameters:
    ///   - publicPathPrefixes: paths under these prefixes bypass the shared
    ///     Bot-key check and must enforce their own authentication (e.g. session
    ///     cookies for the web dashboard). A prefix is matched with `hasPrefix`,
    ///     so never pass `"/"` here — use `publicExactPaths` for the root.
    ///   - publicExactPaths: paths that bypass the Bot-key check only on an
    ///     exact match (e.g. `"/"` for the landing page).
    ///
    ///   Both default to empty, so the only unauthenticated path remains
    ///   `/health` — behaviour is identical to before when the web dashboard is
    ///   not configured.
    public init(
        port: UInt16,
        apiKey: String,
        router: HTTPRouter,
        publicPathPrefixes: [String] = [],
        publicExactPaths: Set<String> = []
    ) {
        self.port = port
        self.apiKey = apiKey
        self.router = router
        self.publicPathPrefixes = publicPathPrefixes.filter { $0 != "/" }
        self.publicExactPaths = publicExactPaths
    }

    public func start() async throws {
        guard !isRunning else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "HTTPAPIServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid port"])
        }
        // Plain TCP on the configured port. Leaving the local endpoint unset lets
        // the dashboard answer localhost and LAN addresses; the web routes decide
        // which sign-in methods are available for each Host header.
        let parameters = NWParameters.tcp
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.connectionTimeout = 5
        }
        let listener = try NWListener(using: parameters, on: nwPort)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self else {
                connection.cancel()
                return
            }
            connection.start(queue: .global())
            Task {
                await self.handleConnection(connection)
            }
        }

        // Wait for the listener to actually bind (or fail) before returning so callers
        // know whether the port is live.
        let resumeOnce = ResumeOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeOnce.resume(continuation, with: .success(()))
                case .failed(let error):
                    resumeOnce.resume(continuation, with: .failure(error))
                case .cancelled:
                    resumeOnce.resume(continuation, with: .failure(NSError(domain: "HTTPAPIServer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Listener cancelled before ready"])))
                default:
                    break
                }
            }
            listener.start(queue: .global())
        }

        // Replace the bind-time handler with a long-lived one that just logs.
        listener.stateUpdateHandler = { [port] state in
            switch state {
            case .failed(let error):
                print("[HTTPAPIServer] Listener failed after start: \(error)")
            case .cancelled:
                print("[HTTPAPIServer] Listener cancelled (port \(port))")
            default:
                break
            }
        }
        isRunning = true
        print("[HTTPAPIServer] Listening on port \(port)")
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    private func handleConnection(_ connection: NWConnection) async {
        var buffer = Data()
        var headersParsed = false
        var contentLength = 0
        var headerData = Data()
        var requestLine: String?
        var headers: [String: String] = [:]

        while true {
            do {
                let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                        if let error = error {
                            continuation.resume(throwing: error)
                            return
                        }
                        if isComplete {
                            continuation.resume(returning: data ?? Data())
                            return
                        }
                        continuation.resume(returning: data ?? Data())
                    }
                }

                buffer.append(data)

                if !headersParsed {
                    if let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) {
                        headerData = buffer.subdata(in: 0..<headerRange.upperBound)
                        let bodyStart = headerRange.upperBound
                        let headerString = String(data: headerData, encoding: .utf8) ?? ""
                        let lines = headerString.split(separator: "\r\n", omittingEmptySubsequences: false)

                        if let first = lines.first {
                            requestLine = String(first)
                        }

                        for line in lines.dropFirst() {
                            let trimmed = String(line)
                            if let colonIndex = trimmed.firstIndex(of: ":") {
                                let key = String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespaces).lowercased()
                                let value = String(trimmed[trimmed.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                                headers[key] = value
                            }
                        }

                        if let cl = headers["content-length"], let length = Int(cl) {
                            contentLength = length
                        }

                        headersParsed = true

                        let bodySoFar = buffer.count - bodyStart
                        if bodySoFar >= contentLength {
                            let bodyEnd = bodyStart + contentLength
                            let body = buffer.subdata(in: bodyStart..<bodyEnd)
                            await processRequest(connection: connection, requestLine: requestLine, headers: headers, body: body)
                            return
                        }
                    }
                } else {
                    let bodyStart = headerData.count
                    let bodySoFar = buffer.count - bodyStart
                    if bodySoFar >= contentLength {
                        let bodyEnd = bodyStart + contentLength
                        let body = buffer.subdata(in: bodyStart..<bodyEnd)
                        await processRequest(connection: connection, requestLine: requestLine, headers: headers, body: body)
                        return
                    }
                }

                if data.isEmpty {
                    break
                }
            } catch {
                break
            }
        }

        connection.cancel()
    }

    private func processRequest(connection: NWConnection, requestLine: String?, headers: [String: String], body: Data) async {
        defer { connection.cancel() }

        guard let requestLine = requestLine else {
            await sendResponse(connection, .badRequest)
            return
        }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            await sendResponse(connection, .badRequest)
            return
        }

        let method = String(parts[0])
        let fullPath = String(parts[1])

        // Parse path and query
        let pathComponents = fullPath.split(separator: "?", maxSplits: 1)
        let path = String(pathComponents[0])
        var queryParams: [String: String] = [:]
        if pathComponents.count > 1 {
            let query = String(pathComponents[1])
            for pair in query.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
                queryParams[key] = value
            }
        }

        let request = HTTPRequest(method: method, path: path, headers: headers, body: body, queryParams: queryParams)

        // Auth check for Bot endpoints. `/health` and any explicitly-registered
        // public prefix (web dashboard OAuth + session routes) bypass the shared
        // Bot-key gate; those routes authenticate themselves per-request.
        if !isPublicPath(path) {
            guard let auth = request.header("authorization"),
                  auth == "Bot \(apiKey)" else {
                await sendResponse(connection, .unauthorized)
                return
            }
        }

        let response = await router.handle(request)
        await sendResponse(connection, response)
    }

    private func isPublicPath(_ path: String) -> Bool {
        Self.isPublicPath(path, prefixes: publicPathPrefixes, exactPaths: publicExactPaths)
    }

    public static func isPublicPath(_ path: String, prefixes: [String], exactPaths: Set<String>) -> Bool {
        if path == "/health" || path.hasPrefix("/health/") { return true }
        if exactPaths.contains(path) { return true }
        for prefix in prefixes where path == prefix || path.hasPrefix(prefix + "/") {
            return true
        }
        return false
    }

    private func sendResponse(_ connection: NWConnection, _ response: HTTPResponse) async {
        let statusText = HTTPStatusText.forCode(response.statusCode)
        var httpString = "HTTP/1.1 \(response.statusCode) \(statusText)\r\n"
        for (key, value) in response.headers {
            httpString += "\(key): \(value)\r\n"
        }
        httpString += "Connection: close\r\n"
        httpString += "\r\n"

        var data = Data(httpString.utf8)
        data.append(response.body)

        return await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }
}

private enum HTTPStatusText {
    static func forCode(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        default: return "Unknown"
        }
    }
}

// MARK: - Resume-once helper

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume(_ continuation: CheckedContinuation<Void, Error>, with result: Result<Void, Error>) {
        lock.lock()
        let alreadyResumed = resumed
        resumed = true
        lock.unlock()
        guard !alreadyResumed else { return }
        switch result {
        case .success: continuation.resume()
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}
