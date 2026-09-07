import Vapor
@preconcurrency import Redis

/// Redis is a hard dependency of the server, so the test suite needs a live instance.
/// Point `REDIS_URL` at one; the default is a local server on the standard port.
///
/// Tests do not need key isolation beyond what they already have: every Redis key the file
/// subsystem writes is scoped by a per-test UUID (user, session or reservation id).
enum TestRedis {
    static var url: String {
        Environment.get("REDIS_URL") ?? "redis://127.0.0.1:6379"
    }

    /// Configures `app.redis` and boots the application, since RediStack only creates its
    /// connection pools in the boot lifecycle. Returns a client usable as
    /// `FileServiceContext.redis`.
    @discardableResult
    static func configure(_ app: Application) async throws -> any RedisClient {
        if app.redis.configuration == nil {
            let poolOptions = RedisConfiguration.PoolOptions(
                maximumConnectionCount: .maximumActiveConnections(5),
                minimumConnectionCount: 1,
                connectionRetryTimeout: .seconds(2)
            )
            app.redis.configuration = try RedisConfiguration(url: url, pool: poolOptions)
        }
        try await app.asyncBoot()
        return app.redis
    }
}
