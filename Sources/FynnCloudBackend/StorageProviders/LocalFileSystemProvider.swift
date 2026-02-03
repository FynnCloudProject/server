import Crypto
import Foundation
import NIOCore
import NIOFileSystem
import Vapor

struct LocalFileSystemProvider: FileStorageProvider {
    let storageDirectory: String

    // Directory for storing temporary chunks during multipart uploads
    private var chunksDirectory: String {
        storageDirectory + "_chunks/"
    }

    private func getInternalPath(for id: UUID) -> String {
        let uuidString = id.uuidString
        let prefix = String(uuidString.prefix(2))
        return storageDirectory + prefix + "/" + uuidString
    }

    private func getChunkDirectory(for id: UUID, uploadID: String) -> String {
        return chunksDirectory + id.uuidString + "/" + uploadID + "/"
    }

    private func getChunkPath(for id: UUID, uploadID: String, partNumber: Int) -> String {
        return getChunkDirectory(for: id, uploadID: uploadID) + "part_\(partNumber)"
    }

    // MARK: - Download

    func getResponse(for id: UUID, on eventLoop: any EventLoop) async throws -> Response {
        let path = getInternalPath(for: id)

        guard let info = try await FileSystem.shared.info(forFileAt: FilePath(path)) else {
            throw Abort(.notFound).localized("error.generic")
        }

        let body = Response.Body(
            stream: { writer in
                Task {
                    do {
                        try await FileSystem.shared.withFileHandle(forReadingAt: FilePath(path)) {
                            handle in
                            for try await chunk in handle.readChunks() {
                                _ = writer.write(.buffer(chunk))
                            }
                        }
                        _ = writer.write(.end)
                    } catch {
                        _ = writer.write(.error(error))
                    }
                }
            }, count: Int(info.size))

        return Response(status: .ok, body: body)
    }

    // MARK: - Single Request Upload (with size validation)

    func save(
        stream: Request.Body,
        id: UUID,
        maxSize: Int64,
        on eventLoop: any EventLoop
    ) async throws -> Int64 {
        let path = getInternalPath(for: id)
        let filePath = FilePath(path)

        try await FileSystem.shared.createDirectory(
            at: filePath.removingLastComponent(),
            withIntermediateDirectories: true
        )

        let countingBody = ByteCountingBody(wrappedBody: stream, maxAllowedSize: maxSize)

        try await FileSystem.shared.withFileHandle(
            forWritingAt: filePath,
            options: .newFile(replaceExisting: true)
        ) { handle in
            var offset: Int64 = 0

            for try await chunk in countingBody {
                try await handle.write(contentsOf: chunk, toAbsoluteOffset: .init(offset))
                offset += Int64(chunk.readableBytes)
            }
        }

        return countingBody.bytesReceived
    }

    func delete(id: UUID) async throws {
        try await FileSystem.shared.removeItem(at: FilePath(getInternalPath(for: id)))
        if try await exists(id: id) {
            throw Abort(.internalServerError).localized("error.generic")
        }
    }

    func exists(id: UUID) async throws -> Bool {
        let info = try await FileSystem.shared.info(forFileAt: FilePath(getInternalPath(for: id)))
        return info != nil
    }

    // MARK: - Multipart Upload (with size validation)

    func initiateMultipartUpload(id: UUID) async throws -> String {
        // Generate a unique upload ID
        let uploadID = UUID().uuidString

        // Create directory for this upload's chunks
        let chunkDir = getChunkDirectory(for: id, uploadID: uploadID)
        try await FileSystem.shared.createDirectory(
            at: FilePath(chunkDir),
            withIntermediateDirectories: true
        )

        return uploadID
    }

    func uploadPart(
        id: UUID,
        uploadID: String,
        partNumber: Int,
        stream: Request.Body,
        maxSize: Int64,
        on eventLoop: any EventLoop
    ) async throws -> CompletedPart {
        let chunkPath = getChunkPath(for: id, uploadID: uploadID, partNumber: partNumber)
        let filePath = FilePath(chunkPath)

        // Use ByteCountingBody for consistency with S3Provider
        let countingBody = ByteCountingBody(wrappedBody: stream, maxAllowedSize: maxSize)

        // Write chunk to temporary file
        try await FileSystem.shared.withFileHandle(
            forWritingAt: filePath,
            options: .newFile(replaceExisting: true)
        ) { handle in
            var offset: Int64 = 0

            for try await chunk in countingBody {
                try await handle.write(contentsOf: chunk, toAbsoluteOffset: .init(offset))
                offset += Int64(chunk.readableBytes)
            }
        }

        // Calculate ETag (MD5 hash) of the chunk for verification
        let data = try Data(contentsOf: URL(fileURLWithPath: chunkPath))
        let hash = Insecure.MD5.hash(data: data)
        let etag = hash.map { String(format: "%02x", $0) }.joined()

        return CompletedPart(
            partNumber: partNumber,
            etag: etag,
            size: countingBody.bytesReceived
        )
    }

    func completeMultipartUpload(
        id: UUID,
        uploadID: String,
        parts: [CompletedPart]
    ) async throws {
        let finalPath = getInternalPath(for: id)
        let finalFilePath = FilePath(finalPath)
        let chunkDir = getChunkDirectory(for: id, uploadID: uploadID)

        // Ensure final directory exists
        try await FileSystem.shared.createDirectory(
            at: finalFilePath.removingLastComponent(),
            withIntermediateDirectories: true
        )

        // Sort parts by part number
        let sortedParts = parts.sorted { $0.partNumber < $1.partNumber }

        // Concatenate all chunks into the final file
        try await FileSystem.shared.withFileHandle(
            forWritingAt: finalFilePath,
            options: .newFile(replaceExisting: true)
        ) { outputHandle in
            var offset: Int64 = 0

            for part in sortedParts {
                let chunkPath = getChunkPath(
                    for: id, uploadID: uploadID, partNumber: part.partNumber)

                // Verify chunk exists
                guard
                    let chunkInfo = try await FileSystem.shared.info(forFileAt: FilePath(chunkPath))
                else {
                    throw Abort(.internalServerError, reason: "Chunk \(part.partNumber) not found")
                }

                // Read and write chunk
                try await FileSystem.shared.withFileHandle(forReadingAt: FilePath(chunkPath)) {
                    inputHandle in
                    for try await chunk in inputHandle.readChunks() {
                        try await outputHandle.write(
                            contentsOf: chunk, toAbsoluteOffset: .init(offset))
                        offset += Int64(chunk.readableBytes)
                    }
                }
            }
        }

        // Clean up chunks directory
        try await FileSystem.shared.removeItem(at: FilePath(chunkDir))
    }

    func abortMultipartUpload(id: UUID, uploadID: String) async throws {
        let chunkDir = getChunkDirectory(for: id, uploadID: uploadID)

        // Remove the chunks directory if it exists
        if try await FileSystem.shared.info(forFileAt: FilePath(chunkDir)) != nil {
            try await FileSystem.shared.removeItem(at: FilePath(chunkDir))
        }
    }
}
