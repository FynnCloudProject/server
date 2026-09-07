import Foundation
import NIOCore
import Vapor
@testable import FynnCloudServer

enum TestStorage {
    /// Returns a unique temporary directory path ending in `/` for testing.
    static func createTemporaryStorageDirectory() -> String {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fynncloud_tests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir.path.hasSuffix("/") ? tempDir.path : tempDir.path + "/"
    }

    /// Creates a `LocalFileSystemProvider` backed by an isolated temporary directory in the OS temp location.
    static func createLocalProvider() -> LocalFileSystemProvider {
        LocalFileSystemProvider(storageDirectory: createTemporaryStorageDirectory())
    }
}

struct MockStorageProvider: FileStorageProvider {
    func save(stream: Request.Body, key: String, maxSize: Int64, on eventLoop: any EventLoop) async throws -> StorageSaveResult {
        return StorageSaveResult(size: 1234, hash: "mockhash123")
    }
    func save(buffer: ByteBuffer, key: String, contentType: String) async throws {}
    func getResponse(key: String, range: HTTPHeaders.Range?, on eventLoop: any EventLoop) async throws -> Response {
        return Response(status: .ok, body: "mock content")
    }
    func downloadToFile(key: String, path: String, on eventLoop: any EventLoop) async throws {}
    func delete(key: String) async throws {}
    func exists(key: String) async throws -> Bool { return true }
    func copy(sourceKey: String, destinationKey: String) async throws {}
    func initiateMultipartUpload(key: String) async throws -> String { return "uploadid" }
    func uploadPart(key: String, uploadID: String, partNumber: Int, stream: Request.Body, maxSize: Int64, on eventLoop: any EventLoop) async throws -> CompletedPart {
        return CompletedPart(partNumber: partNumber, etag: "part-hash", size: 100)
    }
    func completeMultipartUpload(key: String, uploadID: String, parts: [CompletedPart]) async throws -> MultipartCompletionResult {
        MultipartCompletionResult(hash: "mockhash123", size: parts.reduce(0) { $0 + $1.size })
    }
    func abortMultipartUpload(key: String, uploadID: String) async throws {}
    func deleteUserData(userID: UUID) async throws {}
}
