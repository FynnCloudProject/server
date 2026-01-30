import NIOCore
import NIOFileSystem
import Vapor

struct LocalFileSystemProvider: FileStorageProvider {
    let storageDirectory: String

    private func getInternalPath(for id: UUID) -> String {
        let uuidString = id.uuidString
        let prefix = String(uuidString.prefix(2))
        return storageDirectory + prefix + "/" + uuidString
    }

    // MARK: - Download
    func getResponse(for id: UUID, on eventLoop: any EventLoop) async throws -> Response {
        let path = getInternalPath(for: id)

        guard let info = try await FileSystem.shared.info(forFileAt: FilePath(path)) else {
            throw Abort(.notFound)
        }

        // Vapor's stream initializer expects a non-throwing closure: @Sendable (writer) -> ()
        let body = Response.Body(
            stream: { writer in
                // We create a Task to run our async, throwing file logic
                Task {
                    do {
                        try await FileSystem.shared.withFileHandle(forReadingAt: FilePath(path)) {
                            handle in
                            for try await chunk in handle.readChunks() {
                                _ = writer.write(.buffer(chunk))
                            }
                        }
                        // Signal the end of the stream
                        _ = writer.write(.end)
                    } catch {
                        // If an error occurs, we signal the error to the writer
                        // and log it since we can't 'throw' out of this closure
                        _ = writer.write(.error(error))
                    }
                }
            }, count: Int(info.size))

        return Response(status: .ok, body: body)
    }

    // MARK: - Upload
    func save(stream: Request.Body, id: UUID, size: Int64, on eventLoop: any EventLoop) async throws
    {
        let path = getInternalPath(for: id)
        let filePath = FilePath(path)

        // Ensure directory exists
        try await FileSystem.shared.createDirectory(
            at: filePath.removingLastComponent(), withIntermediateDirectories: true)

        // Open for writing
        try await FileSystem.shared.withFileHandle(
            forWritingAt: filePath,
            options: .newFile(replaceExisting: true)
        ) { handle in
            var offset: Int64 = 0
            for try await chunk in stream {
                try await handle.write(contentsOf: chunk, toAbsoluteOffset: .init(offset))
                offset += Int64(chunk.readableBytes)
            }
        }
    }

    func delete(id: UUID) async throws {
        try await FileSystem.shared.removeItem(at: FilePath(getInternalPath(for: id)))
        // Check if file still exists
        if try await exists(id: id) {
            throw Abort(.internalServerError)
        }
    }

    func exists(id: UUID) async throws -> Bool {
        let info = try await FileSystem.shared.info(forFileAt: FilePath(getInternalPath(for: id)))
        return info != nil
    }
}
