import Vapor

// Abstraction for file storage to make it easy to switch between different storage providers
protocol FileStorageProvider: Sendable {
    // Updated single-request upload methods - now return actual bytes written
    func save(
        stream: Request.Body,
        id: UUID,
        userID: UUID,
        maxSize: Int64,
        on eventLoop: any EventLoop
    ) async throws -> Int64  // Returns actual bytes written

    func getResponse(for id: UUID, userID: UUID, on eventLoop: any EventLoop) async throws
        -> Response
    func delete(id: UUID, userID: UUID) async throws
    func exists(id: UUID, userID: UUID) async throws -> Bool

    // Updated multipart upload methods - now return actual bytes written
    func initiateMultipartUpload(id: UUID, userID: UUID) async throws -> String

    func uploadPart(
        id: UUID,
        userID: UUID,
        uploadID: String,
        partNumber: Int,
        stream: Request.Body,
        maxSize: Int64,  // Maximum allowed for this part
        on eventLoop: any EventLoop
    ) async throws -> CompletedPart  // Now includes actual size

    func completeMultipartUpload(
        id: UUID,
        userID: UUID,
        uploadID: String,
        parts: [CompletedPart]
    ) async throws

    func abortMultipartUpload(id: UUID, userID: UUID, uploadID: String) async throws
}

// Represents a successfully uploaded part
struct CompletedPart: Codable, Sendable {
    let partNumber: Int
    let etag: String
    let size: Int64  // Actual bytes written for this part

    init(partNumber: Int, etag: String, size: Int64) {
        self.partNumber = partNumber
        self.etag = etag
        self.size = size
    }
}
