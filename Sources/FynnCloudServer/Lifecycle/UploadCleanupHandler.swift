import Queues
import Redis
import Vapor

struct UploadCleanupJob: AsyncScheduledJob {
    func run(context: QueueContext) async throws {
        let app = context.application
        let eventLoop = app.eventLoopGroup.next()
        let storageService = StorageService(
            provider: app.fileStorage,
            eventLoop: eventLoop
        )
        let context = FileServiceContext(
            db: app.db,
            logger: app.logger,
            storage: storageService,
            redis: app.redis
        )
        await MultipartUploadService(context).cleanupExpiredUploads()

        await app.recordJobLastRun(id: "upload_cleanup")
    }
}
