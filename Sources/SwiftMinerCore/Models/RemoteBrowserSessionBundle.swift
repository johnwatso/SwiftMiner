import CoreFoundation
import Foundation

/// A sanitized failure from parsing or checking a remote browser handoff.
///
/// Error values intentionally contain only fixed codes. A rejected payload can contain an
/// OAuth token, integrity token, and SDK cookie, so parser diagnostics must never interpolate
/// input values.
public enum RemoteBrowserSessionBundleError: String, Error, Equatable, Sendable {
    case payloadTooLarge = "PAYLOAD_TOO_LARGE"
    case invalidFormat = "FORMAT"
    case unsupportedVersion = "VERSION"
    case invalidTimestamp = "TIMESTAMP"
    case invalidHeaders = "HEADERS"
    case invalidSDKCookie = "SDK_COOKIE"
    case integrityExpired = "EXPIRED"
    case sdkCookieExpired = "SDK_EXPIRED"
    case invalidGeneration = "GENERATION"
}

extension RemoteBrowserSessionBundleError: LocalizedError {
    public var errorDescription: String? {
        "Remote browser session rejected (\(rawValue))."
    }
}

/// Strict parser for the private server seed emitted by TwitchDropsMiner 2.0-compatible
/// browser helpers.
///
/// The wire format is deliberately closed: it accepts one versioned session bundle, a fixed
/// set of Twitch request headers, and exactly one narrowly scoped `KP_UIDz-ssn` seed cookie.
/// It is not `Codable` on purpose. Callers should save `oauthToken` in the account's existing
/// token field and use `authenticationContext(generation:)` for the browser context, avoiding
/// a second copy of the Authorization credential.
public struct RemoteBrowserSessionBundle: Equatable, Sendable {
    public static let schemaVersion = 1
    public static let maximumPayloadBytes = 65_536

    public static let twitchWebClientID = TwitchClientIDs.web
    public static let twitchOrigin = TwitchClientIDs.webOrigin
    public static let sdkCookieName = "KP_UIDz-ssn"
    public static let sdkCookieDomain = "k.twitchcdn.net"

    public static let allowedHeaderNames: Set<String> = [
        "authorization",
        "client-id",
        "client-integrity",
        "client-version",
        "client-session-id",
        "x-device-id",
        "device-id",
        "accept-language",
    ]

    /// The OAuth credential extracted from the single allowlisted Authorization header.
    /// This is transient handoff data and is intentionally absent from the generated browser
    /// authentication context.
    public let oauthToken: String

    public let userAgent: String
    public let xDeviceID: String?
    public let deviceID: String?
    public let clientSessionID: String?
    public let clientVersion: String?
    public let acceptLanguage: String?
    public let integrityToken: String
    public let capturedAt: Date
    public let expiresAt: Date
    public let sdkCookieValue: String
    public let sdkCookieExpiresAt: Date

    private init(
        oauthToken: String,
        userAgent: String,
        xDeviceID: String?,
        deviceID: String?,
        clientSessionID: String?,
        clientVersion: String?,
        acceptLanguage: String?,
        integrityToken: String,
        capturedAt: Date,
        expiresAt: Date,
        sdkCookieValue: String,
        sdkCookieExpiresAt: Date
    ) {
        self.oauthToken = oauthToken
        self.userAgent = userAgent
        self.xDeviceID = xDeviceID
        self.deviceID = deviceID
        self.clientSessionID = clientSessionID
        self.clientVersion = clientVersion
        self.acceptLanguage = acceptLanguage
        self.integrityToken = integrityToken
        self.capturedAt = capturedAt
        self.expiresAt = expiresAt
        self.sdkCookieValue = sdkCookieValue
        self.sdkCookieExpiresAt = sdkCookieExpiresAt
    }

    /// Parses the exact TwitchDropsMiner 2.0 server-seed envelope.
    ///
    /// Structural parsing permits an expired integrity token because the still-fresh SDK
    /// cookie can bootstrap a replacement on the server. Initial account handoff must also
    /// call `requireFresh(at:)`; renewal may call `requireFreshSDKCookie(at:)` instead.
    public static func parse(_ data: Data, now: Date = Date()) throws -> Self {
        guard data.count <= maximumPayloadBytes else {
            throw RemoteBrowserSessionBundleError.payloadTooLarge
        }

        let rootObject: Any
        do {
            rootObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw RemoteBrowserSessionBundleError.invalidFormat
        }

        let root = try exactDictionary(
            rootObject,
            keys: ["version", "bundle", "sdk_cookie"]
        )
        try validateVersion(root["version"])

        let session = try exactDictionary(
            root["bundle"],
            keys: ["version", "captured_at", "expires_at", "user_agent", "headers"]
        )
        try validateVersion(session["version"])

        let nowSeconds = now.timeIntervalSince1970
        guard nowSeconds.isFinite, nowSeconds > 0 else {
            throw RemoteBrowserSessionBundleError.invalidTimestamp
        }
        let captured = try timestamp(session["captured_at"])
        let expiry = try timestamp(session["expires_at"])
        guard
            captured > 0,
            captured <= nowSeconds + 60,
            expiry > captured,
            expiry - captured <= 86_400
        else {
            throw RemoteBrowserSessionBundleError.invalidTimestamp
        }

        guard
            let userAgent = session["user_agent"] as? String,
            isPrintableASCII(userAgent, maximumBytes: 1_024)
        else {
            throw RemoteBrowserSessionBundleError.invalidHeaders
        }

        guard let rawHeaders = session["headers"] as? [String: Any] else {
            throw RemoteBrowserSessionBundleError.invalidHeaders
        }
        let headerNames = Set(rawHeaders.keys)
        guard headerNames.isSubset(of: allowedHeaderNames) else {
            throw RemoteBrowserSessionBundleError.invalidHeaders
        }

        var headers: [String: String] = [:]
        headers.reserveCapacity(rawHeaders.count)
        for (name, rawValue) in rawHeaders {
            guard
                let value = rawValue as? String,
                isPrintableASCII(value, maximumBytes: 16_384)
            else {
                throw RemoteBrowserSessionBundleError.invalidHeaders
            }
            headers[name] = value
        }

        guard headers["client-id"] == twitchWebClientID else {
            throw RemoteBrowserSessionBundleError.invalidHeaders
        }
        guard
            let authorization = headers["authorization"],
            authorization.hasPrefix("OAuth ")
        else {
            throw RemoteBrowserSessionBundleError.invalidHeaders
        }
        let oauthToken = String(authorization.dropFirst(6))
        guard
            (1 ... 512).contains(oauthToken.utf8.count),
            oauthToken.unicodeScalars.allSatisfy(isOAuthTokenScalar)
        else {
            throw RemoteBrowserSessionBundleError.invalidHeaders
        }
        guard
            let integrityToken = headers["client-integrity"],
            !integrityToken.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            throw RemoteBrowserSessionBundleError.invalidHeaders
        }
        let xDeviceID = headers["x-device-id"]
        let deviceID = headers["device-id"]
        guard [xDeviceID, deviceID].compactMap({ $0 }).contains(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else {
            throw RemoteBrowserSessionBundleError.invalidHeaders
        }

        let cookie = try exactDictionary(
            root["sdk_cookie"],
            keys: ["value", "expires_at"]
        )
        guard
            let cookieValue = cookie["value"] as? String,
            isSDKCookieValue(cookieValue)
        else {
            throw RemoteBrowserSessionBundleError.invalidSDKCookie
        }
        let cookieExpiry: Double
        do {
            cookieExpiry = try timestamp(cookie["expires_at"])
        } catch {
            throw RemoteBrowserSessionBundleError.invalidSDKCookie
        }
        guard cookieExpiry > 0 else {
            throw RemoteBrowserSessionBundleError.invalidSDKCookie
        }

        return Self(
            oauthToken: oauthToken,
            userAgent: userAgent,
            xDeviceID: xDeviceID,
            deviceID: deviceID,
            clientSessionID: headers["client-session-id"],
            clientVersion: headers["client-version"],
            acceptLanguage: headers["accept-language"],
            integrityToken: integrityToken,
            capturedAt: Date(timeIntervalSince1970: captured),
            expiresAt: Date(timeIntervalSince1970: expiry),
            sdkCookieValue: cookieValue,
            sdkCookieExpiresAt: Date(timeIntervalSince1970: cookieExpiry)
        )
    }

    /// Requires both parts of a first-time browser handoff to still be usable.
    public func requireFresh(at now: Date = Date()) throws {
        guard expiresAt > now else {
            throw RemoteBrowserSessionBundleError.integrityExpired
        }
        try requireFreshSDKCookie(at: now)
    }

    /// Requires the narrowly scoped SDK seed to be usable for server-side renewal.
    public func requireFreshSDKCookie(at now: Date = Date()) throws {
        guard sdkCookieExpiresAt > now else {
            throw RemoteBrowserSessionBundleError.sdkCookieExpired
        }
    }

    /// Creates the canonical persistent browser context while keeping Authorization solely in
    /// the account's existing token field.
    public func authenticationContext(generation: Int = 1) throws -> TwitchAuthenticationContext {
        guard generation > 0 else {
            throw RemoteBrowserSessionBundleError.invalidGeneration
        }
        return .browser(.init(
            schemaVersion: Self.schemaVersion,
            clientID: Self.twitchWebClientID,
            origin: Self.twitchOrigin,
            userAgent: userAgent,
            xDeviceID: xDeviceID,
            deviceID: deviceID,
            clientSessionID: clientSessionID,
            clientVersion: clientVersion,
            acceptLanguage: acceptLanguage,
            integrityToken: integrityToken,
            capturedAt: capturedAt,
            expiresAt: expiresAt,
            sdkCookieValue: sdkCookieValue,
            cookieExpiresAt: sdkCookieExpiresAt,
            generation: generation
        ))
    }

    private static func exactDictionary(_ object: Any?, keys: Set<String>) throws -> [String: Any] {
        guard let dictionary = object as? [String: Any], Set(dictionary.keys) == keys else {
            throw RemoteBrowserSessionBundleError.invalidFormat
        }
        return dictionary
    }

    private static func validateVersion(_ object: Any?) throws {
        guard let number = object as? NSNumber, !isBoolean(number), !isFloatingPoint(number) else {
            throw RemoteBrowserSessionBundleError.invalidFormat
        }
        guard number.intValue == schemaVersion else {
            throw RemoteBrowserSessionBundleError.unsupportedVersion
        }
    }

    private static func timestamp(_ object: Any?) throws -> Double {
        guard let number = object as? NSNumber, !isBoolean(number) else {
            throw RemoteBrowserSessionBundleError.invalidTimestamp
        }
        let value = number.doubleValue
        guard value.isFinite else {
            throw RemoteBrowserSessionBundleError.invalidTimestamp
        }
        return value
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func isFloatingPoint(_ number: NSNumber) -> Bool {
        switch String(cString: number.objCType) {
        case "f", "d":
            true
        default:
            false
        }
    }

    private static func isPrintableASCII(_ value: String, maximumBytes: Int) -> Bool {
        let count = value.utf8.count
        return (1 ... maximumBytes).contains(count) && value.unicodeScalars.allSatisfy {
            (0x20 ... 0x7E).contains($0.value)
        }
    }

    private static func isOAuthTokenScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x30 ... 0x39, 0x41 ... 0x5A, 0x61 ... 0x7A, 0x2D, 0x5F:
            true
        default:
            false
        }
    }

    private static func isSDKCookieValue(_ value: String) -> Bool {
        let count = value.utf8.count
        guard (1 ... 8_192).contains(count) else { return false }
        return value.unicodeScalars.allSatisfy {
            switch $0.value {
            case 0x21, 0x23 ... 0x2B, 0x2D ... 0x3A, 0x3C ... 0x5B, 0x5D ... 0x7E:
                true
            default:
                false
            }
        }
    }
}

extension RemoteBrowserSessionBundle: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "RemoteBrowserSessionBundle(version: \(Self.schemaVersion), credentials: <redacted>)"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "version": Self.schemaVersion,
                "credentials": "<redacted>",
            ],
            displayStyle: .struct
        )
    }
}
