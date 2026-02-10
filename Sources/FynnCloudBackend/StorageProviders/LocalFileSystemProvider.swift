import Crypto
import Foundation
import NIOCore
import NIOFileSystem
import Vapor

struct LocalFileSystemProvider: FileStorageProvider {
    let storageDirectory: String
    private var fileSystem: FileSystem { .shared }

    // MARK: - Path Helpers

    private func getInternalPath(for id: UUID, userID: UUID) -> FilePath {
        let uuidString = id.uuidString
        let prefix = String(uuidString.prefix(2))
        var path = FilePath(storageDirectory)
        path.append(userID.uuidString)
        path.append(prefix)
        path.append(uuidString)
        return path
    }

    private func getChunkDirectory(for id: UUID, userID: UUID, uploadID: String) -> FilePath {
        var path = FilePath(storageDirectory)
        path.append(userID.uuidString)
        path.append("_chunks")
        path.append(id.uuidString)
        path.append(uploadID)
        return path
    }

    private func getChunkPath(for id: UUID, userID: UUID, uploadID: String, partNumber: Int)
        -> FilePath
    {
        var path = getChunkDirectory(for: id, userID: userID, uploadID: uploadID)
        path.append("part_\(partNumber)")
        return path
    }

    private func userDirectory(for userID: UUID) -> FilePath {
        var path = FilePath(storageDirectory)
        path.append(userID.uuidString)
        return path
    }

    /// Guards against path traversal — resolved paths must stay within the storage root.
    private func assertWithinStorageRoot(_ path: FilePath) {
        precondition(
            path.string.hasPrefix(storageDirectory),
            "Resolved path \(path) escapes storage root \(storageDirectory)"
        )
    }

    // MARK: - Download

    func getResponse(for id: UUID, userID: UUID, on eventLoop: any EventLoop) async throws
        -> Response
    {
        let filePath = getInternalPath(for: id, userID: userID)
        assertWithinStorageRoot(filePath)

        guard
            let info = try await fileSystem.info(
                forFileAt: filePath, infoAboutSymbolicLink: false)
        else {
            throw Abort(.notFound).localized("error.generic")
        }

        let body = Response.Body(
            stream: { writer in
                Task {
                    do {
                        try await self.fileSystem.withFileHandle(
                            forReadingAt: filePath
                        ) { handle in
                            for try await chunk in handle.readChunks() {
                                // Await backpressure signal before reading more data
                                try await writer.write(.buffer(chunk)).get()
                            }
                        }
                        try await writer.write(.end).get()
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
        userID: UUID,
        maxSize: Int64,
        on eventLoop: any EventLoop
    ) async throws -> Int64 {
        let filePath = getInternalPath(for: id, userID: userID)
        assertWithinStorageRoot(filePath)

        try await fileSystem.createDirectory(
            at: filePath.removingLastComponent(),
            withIntermediateDirectories: true,
            permissions: nil
        )

        let countingBody = ByteCountingBody(wrappedBody: stream, maxAllowedSize: maxSize)

        do {
            try await fileSystem.withFileHandle(
                forWritingAt: filePath,
                options: .newFile(replaceExisting: true)
            ) { handle in
                var writer = handle.bufferedWriter(capacity: .bytes(128 * 1024))

                for try await chunk in countingBody {
                    try await writer.write(contentsOf: chunk.readableBytesView)
                }

                try await writer.flush()
            }
        } catch {
            // Clean up partial file on failure
            try await fileSystem.removeItem(
                at: filePath, strategy: .platformDefault, recursively: false)
            throw error
        }

        return countingBody.bytesReceived
    }

    func delete(id: UUID, userID: UUID) async throws {
        let filePath = getInternalPath(for: id, userID: userID)
        assertWithinStorageRoot(filePath)
        try await fileSystem.removeItem(
            at: filePath, strategy: .platformDefault, recursively: false)
    }

    func exists(id: UUID, userID: UUID) async throws -> Bool {
        let filePath = getInternalPath(for: id, userID: userID)
        let info = try await fileSystem.info(forFileAt: filePath, infoAboutSymbolicLink: false)
        return info != nil
    }

    // MARK: - Multipart Upload (with size validation)

    func initiateMultipartUpload(id: UUID, userID: UUID) async throws -> String {
        let uploadID = UUID().uuidString

        let chunkDir = getChunkDirectory(for: id, userID: userID, uploadID: uploadID)
        assertWithinStorageRoot(chunkDir)

        try await fileSystem.createDirectory(
            at: chunkDir,
            withIntermediateDirectories: true,
            permissions: nil
        )

        return uploadID
    }

    func uploadPart(
        id: UUID,
        userID: UUID,
        uploadID: String,
        partNumber: Int,
        stream: Request.Body,
        maxSize: Int64,
        on eventLoop: any EventLoop
    ) async throws -> CompletedPart {
        let filePath = getChunkPath(
            for: id, userID: userID, uploadID: uploadID, partNumber: partNumber)
        assertWithinStorageRoot(filePath)

        let countingBody = ByteCountingBody(wrappedBody: stream, maxAllowedSize: maxSize)

        // MD5 is used intentionally for S3-compatible ETag generation, not for security.
        var hasher = Insecure.MD5()

        do {
            try await fileSystem.withFileHandle(
                forWritingAt: filePath,
                options: .newFile(replaceExisting: true)
            ) { handle in
                var writer = handle.bufferedWriter(capacity: .bytes(128 * 1024))

                for try await chunk in countingBody {
                    chunk.withUnsafeReadableBytes { bufferPointer in
                        hasher.update(bufferPointer: bufferPointer)
                    }

                    try await writer.write(contentsOf: chunk.readableBytesView)
                }

                try await writer.flush()
            }
        } catch {
            // Clean up partial chunk on failure
            _ = try? await fileSystem.removeItem(
                at: filePath, strategy: .platformDefault, recursively: false)
            throw error
        }

        let hash = hasher.finalize()
        let etag = hash.map { String(format: "%02x", $0) }.joined()

        return CompletedPart(
            partNumber: partNumber,
            etag: etag,
            size: countingBody.bytesReceived
        )
    }

    func completeMultipartUpload(
        id: UUID,
        userID: UUID,
        uploadID: String,
        parts: [CompletedPart]
    ) async throws {
        let finalFilePath = getInternalPath(for: id, userID: userID)
        let chunkDir = getChunkDirectory(for: id, userID: userID, uploadID: uploadID)
        assertWithinStorageRoot(finalFilePath)
        assertWithinStorageRoot(chunkDir)

        try await fileSystem.createDirectory(
            at: finalFilePath.removingLastComponent(),
            withIntermediateDirectories: true,
            permissions: nil
        )

        let sortedParts = parts.sorted { $0.partNumber < $1.partNumber }

        do {
            try await fileSystem.withFileHandle(
                forWritingAt: finalFilePath,
                options: .newFile(replaceExisting: true)
            ) { outputHandle in
                var offset: Int64 = 0

                for part in sortedParts {
                    let chunkPath = getChunkPath(
                        for: id, userID: userID, uploadID: uploadID,
                        partNumber: part.partNumber)

                    // Verify chunk exists and size matches what was reported during upload
                    guard
                        let chunkInfo = try await fileSystem.info(
                            forFileAt: chunkPath, infoAboutSymbolicLink: false)
                    else {
                        throw Abort(
                            .internalServerError,
                            reason: "Chunk \(part.partNumber) not found")
                    }

                    guard Int64(chunkInfo.size) == part.size else {
                        throw Abort(
                            .internalServerError,
                            reason:
                                "Size mismatch for part \(part.partNumber): "
                                + "expected \(part.size), got \(chunkInfo.size)")
                    }

                    // Read chunk and append to output file
                    try await fileSystem.withFileHandle(forReadingAt: chunkPath) {
                        inputHandle in
                        for try await chunk in inputHandle.readChunks() {
                            try await outputHandle.write(
                                contentsOf: chunk, toAbsoluteOffset: .init(offset))
                            offset += Int64(chunk.readableBytes)
                        }
                    }
                }
            }
        } catch {
            // Clean up partial final file; preserve chunks so the caller can retry.
            try await fileSystem.removeItem(
                at: finalFilePath, strategy: .platformDefault, recursively: false)
            throw error
        }

        // Clean up chunks directory after successful assembly
        try await fileSystem.removeItem(
            at: chunkDir, strategy: .platformDefault, recursively: true)
    }

    func abortMultipartUpload(id: UUID, userID: UUID, uploadID: String) async throws {
        let chunkDir = getChunkDirectory(for: id, userID: userID, uploadID: uploadID)
        assertWithinStorageRoot(chunkDir)

        if try await fileSystem.info(forFileAt: chunkDir, infoAboutSymbolicLink: false) != nil {
            try await fileSystem.removeItem(
                at: chunkDir, strategy: .platformDefault, recursively: true)
        }
    }

    // MARK: - User Operations

    /// Delete all files for a specific user.
    func deleteUserData(userID: UUID) async throws {
        let userDir = userDirectory(for: userID)
        assertWithinStorageRoot(userDir)

        if try await fileSystem.info(forFileAt: userDir, infoAboutSymbolicLink: false) != nil {
            try await fileSystem.removeItem(
                at: userDir, strategy: .platformDefault, recursively: true)
        }
    }
}
