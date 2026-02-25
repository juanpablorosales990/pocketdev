import Foundation
import os.log

/// Lightweight logger using Apple's unified logging (os.log)
public enum PocketDevLogger {
    private static let subsystem = "com.pocketdev"
    private static let osLog = OSLog(subsystem: subsystem, category: "general")

    public struct LoggerProxy {
        public func info(_ message: String) {
            os_log(.info, log: PocketDevLogger.osLog, "%{public}@", message)
        }
        public func debug(_ message: String) {
            os_log(.debug, log: PocketDevLogger.osLog, "%{public}@", message)
        }
        public func warning(_ message: String) {
            os_log(.default, log: PocketDevLogger.osLog, "WARNING: %{public}@", message)
        }
        public func error(_ message: String) {
            os_log(.error, log: PocketDevLogger.osLog, "%{public}@", message)
        }
    }

    public static let shared = LoggerProxy()
}
