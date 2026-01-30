import SotoCore
import Vapor

extension Application {
    struct StorageConfiguration {
        enum Driver {
            case local(path: String)
            case s3(bucket: String)
        }
        var driver: Driver
    }

    private struct StorageConfigKey: StorageKey {
        typealias Value = StorageConfiguration
    }

    var storageConfig: StorageConfiguration {
        get {
            self.storage[StorageConfigKey.self]
                ?? .init(
                    driver: .local(
                        path: Environment.get("STORAGE_PATH") ?? self.directory.workingDirectory
                            + "Storage/"))
        }
        set { self.storage[StorageConfigKey.self] = newValue }
    }

    // Manage a single Soto AWSClient instance for the whole app
    private struct AWSClientKey: StorageKey {
        typealias Value = AWSClient
    }

    var aws: AWSClient {
        if let client = self.storage[AWSClientKey.self] {
            return client
        }
        let client = AWSClient()
        self.storage[AWSClientKey.self] = client
        return client
    }
}
