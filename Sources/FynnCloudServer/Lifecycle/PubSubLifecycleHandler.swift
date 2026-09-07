import Redis
import Vapor

extension RedisID {
    static let pubsub: RedisID = "pubsub"
}

struct PubSubLifecycleHandler: LifecycleHandler {
    func didBootAsync(_ application: Application) async throws {
        await application.settings.startListening(redis: application.redis(.pubsub)) {
            await reloadSSOProviders(application)
        }
        await application.subscription.startListening(redis: application.redis(.pubsub), logger: application.logger)
    }

    func shutdown(_ application: Application) {
        let logger = application.logger(subsystem: .system)
        logger.info("Unsubscribing from invalidation channels...")
        do {
            try application.redis(.pubsub).unsubscribe(from: ["settings:invalidate", "subscription:invalidate"]).wait()
            logger.info("Successfully unsubscribed from invalidation channels")
        } catch {
            logger.warning(
                "Failed to unsubscribe from invalidation channels during shutdown",
                metadata: ["error": .string("\(error)")]
            )
        }
    }
}
