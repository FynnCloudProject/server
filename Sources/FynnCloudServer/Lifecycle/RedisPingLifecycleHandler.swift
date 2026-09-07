import Redis
import Vapor

struct RedisPingLifecycleHandler: LifecycleHandler {
    let redisURL: String

    func didBootAsync(_ application: Application) async throws {
        guard !application.isCLICommand else { return }

        do {
            _ = try await application.redis.ping().get()
            application.logger(subsystem: .system).info(
                "Successfully connected to Redis",
                metadata: ["url": .string(redisURL)]
            )
        } catch {
            throw Abort(
                .internalServerError,
                reason: """
                    Cannot reach Redis at \(redisURL). Redis is required - quota accounting, \
                    sessions, rate limiting and SSO flow state all depend on it. Set REDIS_URL and \
                    make sure the server is running. (\(error))
                    """
            )
        }
    }
}
