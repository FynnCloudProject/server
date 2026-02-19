import SotoCore
import Vapor

extension Application {

    struct FileStorageProviderKey: StorageKey {
        typealias Value = any FileStorageProvider
    }

    var fileStorage: any FileStorageProvider {
        get {
            guard let provider = self.storage[FileStorageProviderKey.self] else {
                fatalError(
                    "FileStorageProvider not configured. Use app.fileStorage = ... in configure.swift"
                )
            }
            return provider
        }
        set {
            self.storage[FileStorageProviderKey.self] = newValue
        }
    }
}
