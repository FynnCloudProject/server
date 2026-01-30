import NIOCore
import SotoS3
import Vapor

struct S3StorageProvider: FileStorageProvider {
    let s3: S3
    let bucket: String

    func save(stream: Request.Body, id: UUID, size: Int64, on eventLoop: any EventLoop) async throws
    {
        // Create an AsyncSequence from the Vapor Request Body
        let asyncStream = AsyncStream<ByteBuffer> { continuation in
            stream.drain { part in
                switch part {
                case .buffer(let buffer):
                    continuation.yield(buffer)
                case .error(let error):
                    // TODO: Handle error
                    continuation.finish()
                case .end:
                    continuation.finish()
                }
                return eventLoop.makeSucceededFuture(())
            }
        }

        // Soto 7 AWSHTTPBody initialization
        let body = AWSHTTPBody(asyncSequence: asyncStream, length: Int(size))

        let putRequest = S3.PutObjectRequest(
            body: body,
            bucket: bucket,
            key: id.uuidString
        )

        _ = try await s3.putObject(putRequest)
    }

    func getResponse(for id: UUID, on eventLoop: any EventLoop) async throws -> Response {
        let output = try await s3.getObject(.init(bucket: bucket, key: id.uuidString))

        let body = output.body

        // AWSHTTPBody is an AsyncSequence, stream it directly to Vapor's Response
        return Response(
            status: .ok,
            headers: ["Content-Type": output.contentType ?? "application/octet-stream"],
            body: .init(asyncStream: { writer in
                for try await buffer in body {
                    try await writer.write(.buffer(buffer))
                }
                try await writer.write(.end)
            })
        )
    }

    func delete(id: UUID) async throws {
        _ = try await s3.deleteObject(.init(bucket: bucket, key: id.uuidString))
    }

    func exists(id: UUID) async throws -> Bool {
        do {
            _ = try await s3.headObject(.init(bucket: bucket, key: id.uuidString))
            return true
        } catch {
            return false
        }
    }
}
