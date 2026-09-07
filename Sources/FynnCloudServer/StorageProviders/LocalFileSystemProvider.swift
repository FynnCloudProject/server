import Crypto
import Foundation
import NIOCore
import NIOFileSystem
import Vapor

struct LocalFileSystemProvider: FileStorageProvider {
    let storageDirectory: String
    private var fileSystem: FileSystem { .shared }

    // MARK: - Path Helpers

    private func getFilePath(for key: String) -> FilePath {
        var path = FilePath(storageDirectory)
        for component in key.split(separator: "/") {
            path.append(String(component))
        }
        return path
    }

    private func getChunkDirectory(for key: String, uploadID: String) -> FilePath {
        var path = FilePath(storageDirectory)
        let components = key.split(separator: "/")
        if let userID = components.first {
            path.append(String(userID))
            path.append("_system")
            path.append("chunks")
            if let fileID = components.last, components.count > 1 {
                path.append(String(fileID))
            }
            path.append(uploadID)
        } else {
            path.append("_chunks")
            path.append(key.replacingOccurrences(of: "/", with: "_"))
            path.append(uploadID)
        }
        return path
    }

    private func getChunkPath(for key: String, uploadID: String, partNumber: Int) -> FilePath {
        var path = getChunkDirectory(for: key, uploadID: uploadID)
        path.append("part_\(partNumber)")
        return path
    }

    private func userDirectory(for userID: UUID) -> FilePath {
        var path = FilePath(storageDirectory)
        path.append(userID.uuidString)
        return path
    }

    /// Guards against path traversal - resolved paths must stay within the storage root.
    private func assertWithinStorageRoot(_ path: FilePath) {
        let normalizedRoot = FilePath(storageDirectory).string
        let rootPrefix = normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/"
        precondition(
            path.string == normalizedRoot || path.string.hasPrefix(rootPrefix),
            "Resolved path \(path) escapes storage root \(storageDirectory)"
        )
    }

    // MARK: - Download

    func downloadToFile(key: String, path: String, on eventLoop: any EventLoop) async throws {
        let source = getFilePath(for: key)
        assertWithinStorageRoot(source)

        guard try await fileSystem.info(forFileAt: source, infoAboutSymbolicLink: false) != nil else {
            throw Abort(.notFound).localized(LocalizationKeys.Error.Http.Generic)
        }

        // NIOFileSystem copies in chunks internally, so RAM usage stays flat regardless of file size.
        try await fileSystem.copyItem(at: source, to: FilePath(path))
    }

    func getResponse(key: String, range: HTTPHeaders.Range?, on eventLoop: any EventLoop) async throws -> Response {
        let filePath = getFilePath(for: key)
        assertWithinStorageRoot(filePath)

        guard let info = try await fileSystem.info(forFileAt: filePath, infoAboutSymbolicLink: false) else {
            throw Abort(.notFound).localized(LocalizationKeys.Error.Http.Generic)
        }

        let fileSize = Int64(info.size)

        if let range = range,
           range.unit == .bytes,
           let firstRange = range.ranges.first
        {
            let start: Int64
            let end: Int64

            switch firstRange {
            case .start(let value):
                start = Int64(value)
                end = fileSize - 1
            case .tail(let value):
                start = max(fileSize - Int64(value), 0)
                end = fileSize - 1
            case .within(let lower, let upper):
                start = Int64(lower)
                end = min(Int64(upper), fileSize - 1)
            #if compiler(>=6.0)
            @unknown default:
                start = 0
                end = fileSize - 1
            #endif
            }

            guard start <= end, start < fileSize else {
                let response = Response(status: .rangeNotSatisfiable)
                response.headers.replaceOrAdd(name: "Content-Range", value: "bytes */\(fileSize)")
                return response
            }

            let contentLength = end - start + 1

            let body = Response.Body(
                stream: { writer in
                    Task {
                        do {
                            try await self.fileSystem.withFileHandle(
                                forReadingAt: filePath
                            ) { handle in
                                let chunkRange = start..<(end + 1)
                                for try await chunk in handle.readChunks(in: chunkRange) {
                                    try await writer.write(.buffer(chunk)).get()
                                }
                            }
                            try await writer.write(.end).get()
                        } catch {
                            _ = writer.write(.error(error))
                        }
                    }
                }, count: Int(contentLength))

            let response = Response(status: .partialContent, body: body)
            response.headers.replaceOrAdd(
                name: "Content-Range", value: "bytes \(start)-\(end)/\(fileSize)")
            response.headers.replaceOrAdd(name: "Accept-Ranges", value: "bytes")
            return response
        }

        let body = Response.Body(
            stream: { writer in
                Task {
                    do {
                        try await self.fileSystem.withFileHandle(
                            forReadingAt: filePath
                        ) { handle in
                            for try await chunk in handle.readChunks() {
                                try await writer.write(.buffer(chunk)).get()
                            }
                        }
                        try await writer.write(.end).get()
                    } catch {
                        _ = writer.write(.error(error))
                    }
                }
            }, count: Int(info.size))

        let response = Response(status: .ok, body: body)
        response.headers.replaceOrAdd(name: "Accept-Ranges", value: "bytes")
        return response
    }

    // MARK: - Save

    func save(
        stream: Request.Body,
        key: String,
        maxSize: Int64,
        on eventLoop: any EventLoop
    ) async throws -> StorageSaveResult {
        let filePath = getFilePath(for: key)
        assertWithinStorageRoot(filePath)

        try await fileSystem.createDirectory(
            at: filePath.removingLastComponent(),
            withIntermediateDirectories: true,
            permissions: nil
        )

        let countingBody = ByteCountingBody(wrappedBody: stream, maxAllowedSize: maxSize)
        var hasher = Insecure.MD5()

        do {
            try await fileSystem.withFileHandle(
                forWritingAt: filePath,
                options: .newFile(replaceExisting: true)
            ) { handle in
                var writer = handle.bufferedWriter(capacity: .bytes(128 * 1024))

                for try await chunk in countingBody {
                    chunk.readableBytesView.withContiguousStorageIfAvailable { ptr in
                        hasher.update(bufferPointer: UnsafeRawBufferPointer(ptr))
                    }
                    try await writer.write(contentsOf: chunk.readableBytesView)
                }

                try await writer.flush()
            }
        } catch {
            try await fileSystem.removeItem(
                at: filePath, strategy: .platformDefault, recursively: false)
            throw error
        }

        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return StorageSaveResult(size: countingBody.bytesReceived, hash: hash)
    }

    func save(buffer: ByteBuffer, key: String, contentType: String) async throws {
        let filePath = getFilePath(for: key)
        assertWithinStorageRoot(filePath)

        try await fileSystem.createDirectory(
            at: filePath.removingLastComponent(),
            withIntermediateDirectories: true,
            permissions: nil
        )

        try await fileSystem.withFileHandle(
            forWritingAt: filePath,
            options: .newFile(replaceExisting: true)
        ) { handle in
            try await handle.write(contentsOf: buffer, toAbsoluteOffset: 0)
        }
    }

    func delete(key: String) async throws {
        let filePath = getFilePath(for: key)
        assertWithinStorageRoot(filePath)
        do {
            if try await fileSystem.info(forFileAt: filePath, infoAboutSymbolicLink: false) != nil {
                try await fileSystem.removeItem(
                    at: filePath, strategy: .platformDefault, recursively: false)
            }
        } catch {
            // File or directory already removed / not found
        }
    }

    func exists(key: String) async throws -> Bool {
        let filePath = getFilePath(for: key)
        do {
            let info = try await fileSystem.info(forFileAt: filePath, infoAboutSymbolicLink: false)
            return info != nil
        } catch {
            return false
        }
    }

    func copy(sourceKey: String, destinationKey: String) async throws {
        let source = getFilePath(for: sourceKey)
        let destination = getFilePath(for: destinationKey)
        assertWithinStorageRoot(source)
        assertWithinStorageRoot(destination)

        guard try await fileSystem.info(forFileAt: source, infoAboutSymbolicLink: false) != nil else {
            throw Abort(.notFound).localized(LocalizationKeys.Error.Http.Generic)
        }

        try await fileSystem.createDirectory(
            at: destination.removingLastComponent(),
            withIntermediateDirectories: true,
            permissions: nil
        )

        if try await fileSystem.info(forFileAt: destination, infoAboutSymbolicLink: false) != nil {
            try await fileSystem.removeItem(
                at: destination, strategy: .platformDefault, recursively: false)
        }

        try await fileSystem.copyItem(at: source, to: destination)
    }

    // MARK: - Multipart Upload

    func initiateMultipartUpload(key: String) async throws -> String {
        let uploadID = UUID().uuidString
        let chunkDir = getChunkDirectory(for: key, uploadID: uploadID)
        assertWithinStorageRoot(chunkDir)

        try await fileSystem.createDirectory(
            at: chunkDir,
            withIntermediateDirectories: true,
            permissions: nil
        )

        return uploadID
    }

    func uploadPart(
        key: String,
        uploadID: String,
        partNumber: Int,
        stream: Request.Body,
        maxSize: Int64,
        on eventLoop: any EventLoop
    ) async throws -> CompletedPart {
        let filePath = getChunkPath(for: key, uploadID: uploadID, partNumber: partNumber)
        assertWithinStorageRoot(filePath)

        let countingBody = ByteCountingBody(wrappedBody: stream, maxAllowedSize: maxSize)
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
        key: String,
        uploadID: String,
        parts: [CompletedPart]
    ) async throws -> MultipartCompletionResult {
        let finalFilePath = getFilePath(for: key)
        let chunkDir = getChunkDirectory(for: key, uploadID: uploadID)
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
                        for: key, uploadID: uploadID, partNumber: part.partNumber)

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

                    try await fileSystem.withFileHandle(forReadingAt: chunkPath) { inputHandle in
                        for try await chunk in inputHandle.readChunks() {
                            try await outputHandle.write(
                                contentsOf: chunk, toAbsoluteOffset: .init(offset))
                            offset += Int64(chunk.readableBytes)
                        }
                    }
                }
            }
        } catch {
            try await fileSystem.removeItem(
                at: finalFilePath, strategy: .platformDefault, recursively: false)
            throw error
        }

        try await fileSystem.removeItem(
            at: chunkDir, strategy: .platformDefault, recursively: true)

        // Measured from the assembled file on disk, not summed from client-declared part sizes.
        guard
            let finalInfo = try await fileSystem.info(
                forFileAt: finalFilePath, infoAboutSymbolicLink: false)
        else {
            throw Abort(.internalServerError, reason: "Assembled file vanished after write")
        }

        var combinedHasher = Insecure.MD5()
        for part in sortedParts {
            if let partBytes = part.etag.data(using: .utf8) {
                combinedHasher.update(data: partBytes)
            }
        }
        let finalHash = combinedHasher.finalize()
        let hash = finalHash.map { String(format: "%02x", $0) }.joined() + "-\(sortedParts.count)"
        return MultipartCompletionResult(hash: hash, size: Int64(finalInfo.size))
    }


    func abortMultipartUpload(key: String, uploadID: String) async throws {
        let chunkDir = getChunkDirectory(for: key, uploadID: uploadID)
        assertWithinStorageRoot(chunkDir)

        if try await fileSystem.info(forFileAt: chunkDir, infoAboutSymbolicLink: false) != nil {
            try await fileSystem.removeItem(
                at: chunkDir, strategy: .platformDefault, recursively: true)
        }
    }

    /// Periodic safety sweeper to clean up orphaned chunk folders older than `olderThan` seconds.
    func cleanupOrphanedChunkDirectories(
        olderThan: TimeInterval = StorageService.orphanedChunkRetention
    ) async {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-olderThan)
        let storageURL = URL(fileURLWithPath: storageDirectory)

        guard let userDirs = try? fm.contentsOfDirectory(
            at: storageURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return }

        for userDir in userDirs {
            let chunksDir = userDir.appendingPathComponent("_system").appendingPathComponent("chunks")
            guard fm.fileExists(atPath: chunksDir.path),
                  let fileDirs = try? fm.contentsOfDirectory(
                      at: chunksDir,
                      includingPropertiesForKeys: [.isDirectoryKey],
                      options: .skipsHiddenFiles
                  ) else { continue }

            for fileDir in fileDirs {
                guard let uploadDirs = try? fm.contentsOfDirectory(
                    at: fileDir,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                    options: .skipsHiddenFiles
                ) else { continue }

                for uploadDir in uploadDirs {
                    if let values = try? uploadDir.resourceValues(forKeys: [.contentModificationDateKey]),
                       let modDate = values.contentModificationDate,
                       modDate < cutoff {
                        try? fm.removeItem(at: uploadDir)
                    }
                }

                if let remaining = try? fm.contentsOfDirectory(atPath: fileDir.path), remaining.isEmpty {
                    try? fm.removeItem(at: fileDir)
                }
            }
        }
    }

    // MARK: - User Operations

    func deleteUserData(userID: UUID) async throws {
        let userDir = userDirectory(for: userID)
        assertWithinStorageRoot(userDir)

        if try await fileSystem.info(forFileAt: userDir, infoAboutSymbolicLink: false) != nil {
            try await fileSystem.removeItem(
                at: userDir, strategy: .platformDefault, recursively: true)
        }
    }
}
