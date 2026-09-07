import Logging
import Vapor

public enum LogSubsystem: String, Sendable {
    case auth = "auth"
    case admin = "admin"
    case sync = "sync"
    case storage = "storage"
    case scheduler = "scheduler"
    case sso = "sso"
    case embedding = "embedding"
    case files = "files"
    case wopi = "wopi"
    case system = "system"
    case ai = "ai"
    case http = "http"
}

extension Logger {
    public func scoped(to subsystem: LogSubsystem) -> Logger {
        var copy = self
        copy[metadataKey: "subsystem"] = .string(subsystem.rawValue)
        return copy
    }
}

extension Request {
    public func logger(subsystem: LogSubsystem) -> Logger {
        self.logger.scoped(to: subsystem)
    }
}

extension Application {
    public func logger(subsystem: LogSubsystem) -> Logger {
        self.logger.scoped(to: subsystem)
    }
}
