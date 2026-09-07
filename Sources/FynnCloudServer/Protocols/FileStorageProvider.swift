import Vapor

// Represents the result of a save operation
struct StorageSaveResult: Sendable {
    let size: Int64
    let hash: String
}

// Domain-agnostic abstraction for file and blob storage
protocol FileStorageProvider: Sendable {
    func save(
        stream: Request.Body,
        key: String,
        maxSize: Int64,
        on eventLoop: any EventLoop
    ) async throws -> StorageSaveResult

    func save(
        buffer: ByteBuffer,
        key: String,
        contentType: String
    ) async throws

    func getResponse(
        key: String,
        range: HTTPHeaders.Range?,
        on eventLoop: any EventLoop
    ) async throws -> Response

    /// Streams the stored object at `key` directly to a local file at `path`, without buffering
    /// the whole object in memory. Intended for server-side processing (e.g. thumbnailing).
    func downloadToFile(
        key: String,
        path: String,
        on eventLoop: any EventLoop
    ) async throws

    func delete(key: String) async throws
    func exists(key: String) async throws -> Bool

    /// Server-side copy of a stored object. Overwrites the destination if it already exists.
    func copy(sourceKey: String, destinationKey: String) async throws

    func initiateMultipartUpload(key: String) async throws -> String

    func uploadPart(
        key: String,
        uploadID: String,
        partNumber: Int,
        stream: Request.Body,
        maxSize: Int64,
        on eventLoop: any EventLoop
    ) async throws -> CompletedPart

    func completeMultipartUpload(
        key: String,
        uploadID: String,
        parts: [CompletedPart]
    ) async throws -> MultipartCompletionResult

    func abortMultipartUpload(key: String, uploadID: String) async throws

    /// Sweeps partial multipart state left behind by sessions that were never completed or aborted.
    func cleanupOrphanedChunkDirectories(olderThan: TimeInterval) async

    func deleteUserData(userID: UUID) async throws
}

extension FileStorageProvider {
    /// Providers that track multipart state remotely (e.g. S3) have nothing local to sweep.
    func cleanupOrphanedChunkDirectories(olderThan: TimeInterval) async {}
}

// Represents a successfully uploaded part
struct CompletedPart: Codable, Sendable {
    let partNumber: Int
    let etag: String
    let size: Int64

    init(partNumber: Int, etag: String, size: Int64) {
        self.partNumber = partNumber
        self.etag = etag
        self.size = size
    }
}

/// The hash plus the storage-verified real size of an assembled object. `size` is measured from
/// the actual stored object, never trusted from client-declared part sizes.
struct MultipartCompletionResult: Sendable {
    let hash: String
    let size: Int64
}
