import SotoS3
import Vapor

extension Request {
    var storage: StorageService {
        let provider: any FileStorageProvider

        switch application.storageConfig.driver {
        case .local(let path):  // Extract the configured path
            provider = LocalFileSystemProvider(
                storageDirectory: path
            )

        case .s3(let bucket):
            provider = S3StorageProvider(
                s3: S3(
                    client: application.aws,
                    region: .init(awsRegionName: Environment.get("AWS_REGION") ?? "us-east-1"),
                    endpoint: Environment.get("AWS_ENDPOINT") ?? "https://s3.amazonaws.com",

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
