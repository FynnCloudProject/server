import SotoS3
import Vapor

extension Request {
    var storage: StorageService {
        let provider = application.fileStorage
        return StorageService(
            db: self.db,
            logger: self.logger,
            provider: provider,
            eventLoop: self.eventLoop
        )
    }
}
