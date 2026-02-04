import Vapor

// MARK: - Multipart Upload DTOs

struct InitiateMultipartInput: Content {
    let filename: String
    let contentType: String
    let totalSize: Int64
    let parentID: UUID?
    let lastModified: Int64?  // Unix timestamp in milliseconds
    let chunkSize: Int64?  // Optional, client can specify preferred chunk size
}

struct InitiateMultipartResponse: Content {
    let sessionID: UUID
    let fileID: UUID
    let uploadID: String
    let maxChunkSize: Int64
    let token: String  // JWT token for subsequent uploads
}

struct UploadPartResponse: Content {
    let partNumber: Int
    let etag: String
    let size: Int64
}

struct CompleteMultipartInput: Content {
    let parts: [CompletedPartDTO]
}

struct CompletedPartDTO: Content {
    let partNumber: Int
    let etag: String
    let size: Int64
}
