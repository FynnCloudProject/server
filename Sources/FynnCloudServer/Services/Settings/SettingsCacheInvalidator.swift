import Foundation
import Redis

/// Unique process identity and message channel manager for dynamic settings cache invalidations.
public struct SettingsCacheInvalidator: Sendable {
    /// Redis Pub/Sub channel used to broadcast cache invalidations across server instances.
    public static var invalidationChannel: RedisChannelName { "settings:invalidate" }

    /// Unique identifier for this process instance so self-generated invalidations are ignored.
    public let instanceID: String

    public init(instanceID: String = UUID().uuidString) {
        self.instanceID = instanceID
    }

    /// Determines if an incoming invalidation message originated from a remote replica.
    public func shouldInvalidate(originID: String) -> Bool {
        originID != instanceID
    }
}
