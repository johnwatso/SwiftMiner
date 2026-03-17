import Foundation
import os.log

/// Logging utility for the Twitch miner
public actor Logger {
    public enum LogLevel: String, Sendable, Comparable {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARNING"
        case error = "ERROR"
        
        public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
            let order: [LogLevel] = [.debug, .info, .warning, .error]
            guard let lhsIndex = order.firstIndex(of: lhs),
                  let rhsIndex = order.firstIndex(of: rhs) else {
                return false
            }
            return lhsIndex < rhsIndex
        }
    }
    
    private let subsystem = "com.swifttwitchminer"
    private let category: String
    private let osLog: OSLog
    private var logLevel: LogLevel = .info
    
    public var logHandler: (@Sendable (LogLevel, String) -> Void)?
    
    public init(category: String = "SwiftTwitchMiner") {
        self.category = category
        self.osLog = OSLog(subsystem: subsystem, category: category)
    }
    
    public func setLogLevel(_ level: LogLevel) {
        self.logLevel = level
    }

    public func debug(_ message: String) {
        log(level: .debug, message: message)
    }

    public func info(_ message: String) {
        log(level: .info, message: message)
    }

    public func warning(_ message: String) {
        log(level: .warning, message: message)
    }

    public func error(_ message: String) {
        log(level: .error, message: message)
    }

    private func log(level: LogLevel, message: String) {
        guard level >= logLevel else { return }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let formattedMessage = "[\(timestamp)] [\(level.rawValue)] \(message)"

        // Log to OSLog
        switch level {
        case .debug:
            os_log("%{public}@", log: osLog, type: .debug, message)
        case .info:
            os_log("%{public}@", log: osLog, type: .info, message)
        case .warning:
            os_log("%{public}@", log: osLog, type: .default, message)
        case .error:
            os_log("%{public}@", log: osLog, type: .error, message)
        }

        // Call custom handler
        logHandler?(level, formattedMessage)
    }
}
