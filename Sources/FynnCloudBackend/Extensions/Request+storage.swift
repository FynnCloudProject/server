import SotoS3
import Vapor

extension Request {
    var storage: StorageService {
        let provider: any FileStorageProvider

        guard let config = application.storageConfig else {
            fatalError(
                "StorageConfiguration not initialized. Set app.storageConfig in configure.swift")
        }

        switch config.driver {
        case .local(let path):
            provider = LocalFileSystemProvider(
                storageDirectory: path,
                threadPool: application.threadPool
            )

        case .s3(let bucket):
            provider = S3StorageProvider(
                s3: S3(
                    client: application.aws,
                    region: .init(awsRegionName: application.config.aws.region),
                    endpoint: application.config.aws.endpoint,

                ),
                bucket: bucket,
            )
        }

        return StorageService(
            db: self.db,
            logger: self.logger,
            provider: provider,
            eventLoop: self.eventLoop
        )
    }
}
