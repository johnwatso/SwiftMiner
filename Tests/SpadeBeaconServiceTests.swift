import XCTest
@testable import SwiftTwitchMiner

// MARK: - Per-URL Mock Protocol

/// A captured request including body data (URLProtocol strips httpBody to a stream).
struct CapturedRequest {
    let request: URLRequest
    let bodyData: Data?

    var httpMethod: String? { request.httpMethod }
    var url: URL? { request.url }
    func value(forHTTPHeaderField field: String) -> String? {
        request.value(forHTTPHeaderField: field)
    }
}

/// A smarter URL interceptor that returns different responses based on the request URL.
/// This is needed because SpadeBeaconService makes multiple sequential requests
/// (channel page fetch → spade POST), which require distinct stubs.
///
/// Note: URLProtocol receives POST bodies via httpBodyStream, not httpBody.
/// This mock drains the stream to capture the body.
class SpadeBeaconURLMock: URLProtocol {
    nonisolated(unsafe) static var stubs: [(prefix: String, data: Data, status: Int)] = []
    nonisolated(unsafe) static var captured: [CapturedRequest] = []

    static func stub(urlPrefix: String, body: String, status: Int = 200) {
        stubs.append((prefix: urlPrefix, data: body.data(using: .utf8)!, status: status))
    }
    static func stub(urlPrefix: String, data: Data = Data(), status: Int = 200) {
        stubs.append((prefix: urlPrefix, data: data, status: status))
    }
    static func reset() { stubs.removeAll(); captured.removeAll() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // Drain httpBodyStream to recover POST body (URLSession moves httpBody to a stream)
        var bodyData: Data?
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let bufferSize = 4096
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: bufferSize)
                if read > 0 { data.append(contentsOf: buffer[..<read]) }
            }
            stream.close()
            bodyData = data.isEmpty ? nil : data
        }
        SpadeBeaconURLMock.captured.append(CapturedRequest(request: request, bodyData: bodyData))

        let urlString = request.url?.absoluteString ?? ""
        let match = SpadeBeaconURLMock.stubs.first { urlString.hasPrefix($0.prefix) }
        let status = match?.status ?? 204
        let data   = match?.data   ?? Data()

        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

// MARK: - SpadeBeaconService Tests

@MainActor
final class SpadeBeaconServiceTests: XCTestCase {

    var mockSession: URLSession!
    var service: SpadeBeaconService!

    override func setUp() {
        super.setUp()
        SpadeBeaconURLMock.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SpadeBeaconURLMock.self]
        mockSession = URLSession(configuration: config)
        service = SpadeBeaconService(urlSession: mockSession)
    }

    override func tearDown() {
        SpadeBeaconURLMock.reset()
        super.tearDown()
    }

    // MARK: - Constants

    func testWatchIntervalIs59Seconds() {
        XCTAssertEqual(SpadeBeaconService.watchInterval, 59,
                       "watchInterval must match TDM's WATCH_INTERVAL = 59")
    }

    // MARK: - Payload Structure (TDM parity)

    func testPayloadIsBase64FormEncoded() async throws {
        stubFallbackFlow()
        try await service.sendBeacon(channelLogin: "test", channelId: "1", broadcastId: "2", userId: "3")

        let post = beaconPOST()
        let body = try XCTUnwrap(String(data: XCTUnwrap(post.bodyData), encoding: .utf8))
        XCTAssertTrue(body.hasPrefix("data="), "Body must be form-encoded: data=<base64>")
        let b64 = String(body.dropFirst("data=".count))
        XCTAssertNotNil(Data(base64Encoded: b64), "Value after 'data=' must be valid base64")
    }

    func testPayloadEventIsMinuteWatched() async throws {
        stubFallbackFlow()
        try await service.sendBeacon(channelLogin: "shroud", channelId: "99", broadcastId: "b1", userId: "42")

        let json = try decodedBeaconJSON()
        XCTAssertEqual(json["event"] as? String, "minute-watched")
    }

    func testPayloadUserIdIsInteger() async throws {
        stubFallbackFlow()
        try await service.sendBeacon(channelLogin: "test", channelId: "1", broadcastId: "2", userId: "12345")

        let props = try beaconProperties()
        // Must be NSNumber (integer), not String
        let userIdValue = try XCTUnwrap(props["user_id"])
        XCTAssertFalse(userIdValue is String, "user_id must be an integer in JSON, not a string (TDM parity)")
        XCTAssertEqual(props["user_id"] as? Int, 12345)
    }

    func testPayloadChannelIdIsString() async throws {
        stubFallbackFlow()
        try await service.sendBeacon(channelLogin: "test", channelId: "999", broadcastId: "2", userId: "3")

        let props = try beaconProperties()
        XCTAssertEqual(props["channel_id"] as? String, "999",
                       "channel_id must be a String (TDM uses str(channel.id))")
    }

    func testPayloadBroadcastIdIsString() async throws {
        stubFallbackFlow()
        try await service.sendBeacon(channelLogin: "test", channelId: "1", broadcastId: "broadcast_abc", userId: "3")

        let props = try beaconProperties()
        XCTAssertEqual(props["broadcast_id"] as? String, "broadcast_abc",
                       "broadcast_id must be a String (TDM uses str(stream.id))")
    }

    func testPayloadChannelLoginIsString() async throws {
        stubFallbackFlow()
        try await service.sendBeacon(channelLogin: "shroud", channelId: "1", broadcastId: "2", userId: "3")

        let props = try beaconProperties()
        XCTAssertEqual(props["channel"] as? String, "shroud")
    }

    func testPayloadStaticFields() async throws {
        stubFallbackFlow()
        try await service.sendBeacon(channelLogin: "test", channelId: "1", broadcastId: "2", userId: "3")

        let props = try beaconProperties()
        XCTAssertEqual(props["player"]     as? String, "site")
        XCTAssertEqual(props["location"]   as? String, "channel")
        XCTAssertEqual(props["logged_in"]  as? Bool,   true)
        XCTAssertEqual(props["live"]       as? Bool,   true)
        XCTAssertEqual(props["hidden"]     as? Bool,   false)
        XCTAssertEqual(props["muted"]      as? Bool,   false)
    }

    /// Full exact-match against TDM's compact json_minify output with the expected key order.
    func testPayloadExactTDMParity() async throws {
        stubFallbackFlow()
        try await service.sendBeacon(
            channelLogin: "testchannel",
            channelId: "123",
            broadcastId: "456",
            userId: "789"
        )

        let rawJSON = try decodedBeaconRawString()
        let expected = """
        [{"event":"minute-watched","properties":{"broadcast_id":"456","channel_id":"123","channel":"testchannel","hidden":false,"live":true,"location":"channel","logged_in":true,"muted":false,"player":"site","user_id":789}}]
        """
        XCTAssertEqual(rawJSON, expected, "Beacon JSON must exactly match TDM's json_minify output")
    }

    func testInvalidUserIdDefaultsToZero() async throws {
        stubFallbackFlow()
        try await service.sendBeacon(channelLogin: "test", channelId: "1", broadcastId: "2", userId: "not_a_number")

        let props = try beaconProperties()
        XCTAssertEqual(props["user_id"] as? Int, 0,
                       "Invalid userId string should fall back to 0")
    }

    // MARK: - Headers (TDM parity)

    func testBeaconPOSTUsesAndroidUserAgent() async throws {
        stubFallbackFlow()
        try await service.sendBeacon(channelLogin: "test", channelId: "1", broadcastId: "2", userId: "3")

        let ua = beaconPOST().value(forHTTPHeaderField: "User-Agent")
        XCTAssertNotNil(ua, "User-Agent must be set")
        XCTAssertTrue(ua!.contains("tv.twitch.android.app"),
                      "Beacon POST must use an Android User-Agent to match TDM's ANDROID_APP client")
        
        // Verify it's one of the 7 expected UAs
        let androidPool = [
            "Dalvik/2.1.0 (Linux; U; Android 16; SM-S911B Build/TP1A.220624.014) tv.twitch.android.app/25.3.0/2503006",
            "Dalvik/2.1.0 (Linux; U; Android 16; SM-S938B Build/BP2A.250605.031) tv.twitch.android.app/25.3.0/2503006",
            "Dalvik/2.1.0 (Linux; Android 16; SM-X716N Build/UP1A.231005.007) tv.twitch.android.app/25.3.0/2503006",
            "Dalvik/2.1.0 (Linux; U; Android 15; SM-G990B Build/AP3A.240905.015.A2) tv.twitch.android.app/25.3.0/2503006",
            "Dalvik/2.1.0 (Linux; U; Android 15; SM-G970F Build/AP3A.241105.008) tv.twitch.android.app/25.3.0/2503006",
            "Dalvik/2.1.0 (Linux; U; Android 15; SM-A566E Build/AP3A.240905.015.A2) tv.twitch.android.app/25.3.0/2503006",
            "Dalvik/2.1.0 (Linux; U; Android 14; SM-X306B Build/UP1A.231005.007) tv.twitch.android.app/25.3.0/2503006"
        ]
        XCTAssertTrue(androidPool.contains(ua!), "User-Agent must be from the TDM Android pool")
    }

    func testPageFetchUsesAndroidUserAgent() async throws {
        stubFallbackFlow()
        try await service.sendBeacon(channelLogin: "test", channelId: "1", broadcastId: "2", userId: "3")

        let pageFetch = SpadeBeaconURLMock.captured.first {
            $0.url?.absoluteString.contains("twitch.tv/test") == true
        }
        let ua = try XCTUnwrap(try XCTUnwrap(pageFetch).value(forHTTPHeaderField: "User-Agent"))
        XCTAssertTrue(ua.contains("tv.twitch.android.app"),
                      "Channel page fetch must also use an Android User-Agent")
    }

    func testBeaconPOSTHasNoRefererHeader() async throws {
        stubFallbackFlow()
        try await service.sendBeacon(channelLogin: "test", channelId: "1", broadcastId: "2", userId: "3")

        let referer = beaconPOST().value(forHTTPHeaderField: "Referer")
        XCTAssertNil(referer, "Android apps don't send Referer — must not be present (TDM parity)")
    }

    func testBeaconPOSTContentTypeIsFormEncoded() async throws {
        stubFallbackFlow()
        try await service.sendBeacon(channelLogin: "test", channelId: "1", broadcastId: "2", userId: "3")

        let ct = beaconPOST().value(forHTTPHeaderField: "Content-Type")
        XCTAssertEqual(ct, "application/x-www-form-urlencoded")
    }

    func testBeaconPOSTMethodIsPost() async throws {
        stubFallbackFlow()
        try await service.sendBeacon(channelLogin: "test", channelId: "1", broadcastId: "2", userId: "3")

        XCTAssertEqual(beaconPOST().httpMethod, "POST")
    }

    // MARK: - Spade URL Extraction

    func testSpadeURLExtractedDirectlyFromPageHTML() async throws {
        // Stub: page HTML contains spade_url inline (TDM Step #1)
        let pageHTML = """
        <html><head>
        <script>window.__twilightBuildID="abc";</script>
        <script>settings={"spade_url":"https://spade.twitch.tv/custom-track"}</script>
        </head></html>
        """
        SpadeBeaconURLMock.stub(urlPrefix: "https://www.twitch.tv/", body: pageHTML, status: 200)
        SpadeBeaconURLMock.stub(urlPrefix: "https://spade.twitch.tv/custom-track", data: Data(), status: 204)

        try await service.sendBeacon(channelLogin: "streamer", channelId: "1", broadcastId: "2", userId: "3")

        let postURL = beaconPOST().request.url?.absoluteString
        XCTAssertEqual(postURL, "https://spade.twitch.tv/custom-track",
                       "Should use spade_url found directly in page HTML")
    }

    func testBeaconURLExtractedFromScriptBundle() async throws {
        // Stub: page HTML has no inline spade_url but has a settings.js bundle
        let pageHTML = """
        <html><head>
        <script src="https://static.twitchsvc.net/config/settings.abc123.js"></script>
        </head></html>
        """
        let settingsJS = """
        var a={"beacon_url":"https://spade.twitch.tv/bundle-track"};
        """
        SpadeBeaconURLMock.stub(urlPrefix: "https://www.twitch.tv/", body: pageHTML, status: 200)
        SpadeBeaconURLMock.stub(urlPrefix: "https://static.twitchsvc.net/config/settings", body: settingsJS, status: 200)
        SpadeBeaconURLMock.stub(urlPrefix: "https://spade.twitch.tv/bundle-track", data: Data(), status: 204)

        try await service.sendBeacon(channelLogin: "streamer", channelId: "1", broadcastId: "2", userId: "3")

        let postURL = beaconPOST().request.url?.absoluteString
        XCTAssertEqual(postURL, "https://spade.twitch.tv/bundle-track",
                       "Should fall back to extracting beacon_url from settings JS bundle")
    }

    func testFallsBackToDefaultSpadeURLWhenExtractionFails() async throws {
        // Stub: page returns no spade URL, no bundles → fallback URL used
        SpadeBeaconURLMock.stub(urlPrefix: "https://www.twitch.tv/", body: "<html></html>", status: 200)
        SpadeBeaconURLMock.stub(urlPrefix: "https://spade.twitch.tv/track", data: Data(), status: 204)

        try await service.sendBeacon(channelLogin: "nourl", channelId: "1", broadcastId: "2", userId: "3")

        let postURL = beaconPOST().request.url?.absoluteString
        XCTAssertEqual(postURL, "https://spade.twitch.tv/track",
                       "Should fall back to https://spade.twitch.tv/track when URL extraction fails")
    }

    // MARK: - URL Caching

    func testSpadeURLIsCachedAfterFirstSend() async throws {
        let pageHTML = """
        <html><script>{"spade_url":"https://spade.twitch.tv/cached-track"}</script></html>
        """
        SpadeBeaconURLMock.stub(urlPrefix: "https://www.twitch.tv/", body: pageHTML, status: 200)
        SpadeBeaconURLMock.stub(urlPrefix: "https://spade.twitch.tv/cached-track", data: Data(), status: 204)

        // Send twice
        try await service.sendBeacon(channelLogin: "streamer", channelId: "1", broadcastId: "2", userId: "3")
        try await service.sendBeacon(channelLogin: "streamer", channelId: "1", broadcastId: "2", userId: "3")

        // Page should only have been fetched once (second call uses cache)
        let pageGETs = SpadeBeaconURLMock.captured.filter {
            $0.url?.absoluteString.hasPrefix("https://www.twitch.tv/") == true
        }
        XCTAssertEqual(pageGETs.count, 1,
                       "Channel page should only be fetched once — spade URL must be cached")
    }

    func testClearCacheForcesFreshPageFetch() async throws {
        let pageHTML = """
        <html><script>{"spade_url":"https://spade.twitch.tv/cached-track"}</script></html>
        """
        SpadeBeaconURLMock.stub(urlPrefix: "https://www.twitch.tv/", body: pageHTML, status: 200)
        SpadeBeaconURLMock.stub(urlPrefix: "https://spade.twitch.tv/cached-track", data: Data(), status: 204)

        try await service.sendBeacon(channelLogin: "streamer", channelId: "1", broadcastId: "2", userId: "3")
        await service.clearCache(for: "streamer")
        try await service.sendBeacon(channelLogin: "streamer", channelId: "1", broadcastId: "2", userId: "3")

        let pageGETs = SpadeBeaconURLMock.captured.filter {
            $0.url?.absoluteString.hasPrefix("https://www.twitch.tv/") == true
        }
        XCTAssertEqual(pageGETs.count, 2,
                       "clearCache should force a fresh page fetch on next sendBeacon")
    }

    // MARK: - Error Handling

    func testThrowsOnNon200Or204Response() async throws {
        SpadeBeaconURLMock.stub(urlPrefix: "https://www.twitch.tv/", body: "", status: 200)
        SpadeBeaconURLMock.stub(urlPrefix: "https://spade.twitch.tv/track", data: Data(), status: 403)

        do {
            try await service.sendBeacon(channelLogin: "test", channelId: "1", broadcastId: "2", userId: "3")
            XCTFail("Should throw on HTTP 403")
        } catch let err as SpadeError {
            if case .unexpectedStatus(let code) = err {
                XCTAssertEqual(code, 403)
            } else {
                XCTFail("Expected .unexpectedStatus, got \(err)")
            }
        }
    }
}

// MARK: - Helpers

private extension SpadeBeaconServiceTests {

    /// Stub the minimal flow: empty page (fallback URL) + 204 POST response.
    func stubFallbackFlow() {
        SpadeBeaconURLMock.stub(urlPrefix: "https://www.twitch.tv/", body: "<html></html>", status: 200)
        SpadeBeaconURLMock.stub(urlPrefix: "https://spade.twitch.tv/track", data: Data(), status: 204)
    }

    /// Returns the last POST captured request (the beacon submission).
    func beaconPOST() -> CapturedRequest {
        SpadeBeaconURLMock.captured.last(where: { $0.httpMethod == "POST" })!
    }

    /// Decodes the beacon body and returns the first event object in the JSON array.
    func decodedBeaconJSON() throws -> [String: Any] {
        let post = beaconPOST()
        let body = try XCTUnwrap(String(data: XCTUnwrap(post.bodyData), encoding: .utf8))
        let b64  = String(body.dropFirst("data=".count))
        let json = try XCTUnwrap(Data(base64Encoded: b64))
        let arr  = try JSONSerialization.jsonObject(with: json) as! [[String: Any]]
        return arr[0]
    }

    /// Returns the raw decoded JSON string (for exact-match comparison).
    func decodedBeaconRawString() throws -> String {
        let post = beaconPOST()
        let body = try XCTUnwrap(String(data: XCTUnwrap(post.bodyData), encoding: .utf8))
        let b64  = String(body.dropFirst("data=".count))
        let data = try XCTUnwrap(Data(base64Encoded: b64))
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    /// Returns the `properties` dict from the first beacon event.
    func beaconProperties() throws -> [String: Any] {
        try XCTUnwrap(decodedBeaconJSON()["properties"] as? [String: Any])
    }
}
