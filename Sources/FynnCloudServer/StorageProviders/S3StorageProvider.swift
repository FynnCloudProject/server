import NIOCore
import SotoS3
import Vapor

struct S3StorageProvider: FileStorageProvider {
    let s3: S3
    let bucket: String

    private func getObjectKey(for id: UUID, userID: UUID) -> String {
        let prefix = String(id.uuidString.prefix(2))
        return "\(userID.uuidString)/\(prefix)/\(id.uuidString)"
    }

    // MARK: - Single Request Upload (with size validation)

    func save(
        stream: Request.Body,
        id: UUID,
        userID: UUID,
        maxSize: Int64,
        on eventLoop: any EventLoop
    ) async throws -> Int64 {
        // Wrap body to count actual bytes
        let countingBody = ByteCountingBody(wrappedBody: stream, maxAllowedSize: maxSize)

        let asyncStream = AsyncStream<ByteBuffer> { continuation in
            countingBody.drain(on: eventLoop) { part in
                switch part {
                case .buffer(let buffer):
                    continuation.yield(buffer)
                case .error(let error):
                    continuation.finish()
                case .end:
                    continuation.finish()
                }
                return eventLoop.makeSucceededFuture(())
            }
        }

        let body = AWSHTTPBody(asyncSequence: asyncStream, length: nil)  // Let S3 handle length
        let putRequest = S3.PutObjectRequest(
            body: body,
            bucket: bucket,
            key: getObjectKey(for: id, userID: userID)
        )

        _ = try await s3.putObject(putRequest)

        // Return actual bytes received
        return countingBody.bytesReceived
    }

    func getResponse(for id: UUID, userID: UUID, on eventLoop: any EventLoop) async throws
        -> Response
    {
        let output = try await s3.getObject(
            .init(bucket: bucket, key: getObjectKey(for: id, userID: userID)))
        let body = output.body

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

    func delete(id: UUID, userID: UUID) async throws {
        _ = try await s3.deleteObject(
            .init(bucket: bucket, key: getObjectKey(for: id, userID: userID)))
    }

    func exists(id: UUID, userID: UUID) async throws -> Bool {
        do {
            _ = try await s3.headObject(
                .init(bucket: bucket, key: getObjectKey(for: id, userID: userID)))
            return true
        } catch {
            return false
        }
    }

    // MARK: - Multipart Upload (with size validation)

    func initiateMultipartUpload(id: UUID, userID: UUID) async throws -> String {
        let request = S3.CreateMultipartUploadRequest(
            bucket: bucket,
            key: getObjectKey(for: id, userID: userID)
        )

        let response = try await s3.createMultipartUpload(request)

        guard let uploadID = response.uploadId else {
            throw Abort(.internalServerError, reason: "S3 did not return upload ID")
        }

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
        // Wrap body to count actual bytes
        let countingBody = ByteCountingBody(wrappedBody: stream, maxAllowedSize: maxSize)

        let asyncStream = AsyncStream<ByteBuffer> { continuation in
            countingBody.drain(on: eventLoop) { part in
                switch part {
                case .buffer(let buffer):
                    continuation.yield(buffer)
                case .error(let error):
                    continuation.finish()
                case .end:
                    continuation.finish()
                }
                return eventLoop.makeSucceededFuture(())
            }
        }

        let body = AWSHTTPBody(asyncSequence: asyncStream, length: nil)

        let request = S3.UploadPartRequest(
            body: body,
            bucket: bucket,
            key: getObjectKey(for: id, userID: userID),
            partNumber: partNumber,
            uploadId: uploadID
        )

        let response = try await s3.uploadPart(request)

        guard let etag = response.eTag else {
            throw Abort(.internalServerError, reason: "S3 did not return ETag for part")
        }

        // Return actual size written
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
        let completedParts = parts.map { part in
            S3.CompletedPart(eTag: part.etag, partNumber: part.partNumber)
        }

        let request = S3.CompleteMultipartUploadRequest(
            bucket: bucket,
            key: getObjectKey(for: id, userID: userID),
            multipartUpload: S3.CompletedMultipartUpload(parts: completedParts),
            uploadId: uploadID
        )

        _ = try await s3.completeMultipartUpload(request)
    }

    func abortMultipartUpload(id: UUID, userID: UUID, uploadID: String) async throws {
        let request = S3.AbortMultipartUploadRequest(
            bucket: bucket,
            key: getObjectKey(for: id, userID: userID),
            uploadId: uploadID
        )

        _ = try await s3.abortMultipartUpload(request)
    }

    // MARK: - User Operations

    /// Delete all objects for a specific user (uses S3 prefix deletion)
    func deleteUserData(userID: UUID) async throws {
        let prefix = "\(userID.uuidString)/"

        // List all objects with this prefix
        var continuationToken: String? = nil

        repeat {
            let listRequest = S3.ListObjectsV2Request(
                bucket: bucket,
                continuationToken: continuationToken,
                prefix: prefix
            )

            let listResponse = try await s3.listObjectsV2(listRequest)

            // Delete objects in batches
            if let objects = listResponse.contents, !objects.isEmpty {
                let objectIdentifiers = objects.compactMap { object -> S3.ObjectIdentifier? in
                    guard let key = object.key else { return nil }
                    return S3.ObjectIdentifier(key: key)
                }

                if !objectIdentifiers.isEmpty {
                    let deleteRequest = S3.DeleteObjectsRequest(
                        bucket: bucket,
                        delete: S3.Delete(objects: objectIdentifiers)
                    )

                    _ = try await s3.deleteObjects(deleteRequest)
                }
            }

            continuationToken = listResponse.nextContinuationToken
        } while continuationToken != nil
    }

    /// Get total storage used by a user (in bytes)
    func getUserStorageSize(userID: UUID) async throws -> Int64 {
        let prefix = "\(userID.uuidString)/"
        var totalSize: Int64 = 0
        var continuationToken: String? = nil

        repeat {
            let listRequest = S3.ListObjectsV2Request(
                bucket: bucket,
                continuationToken: continuationToken,
                prefix: prefix
            )

            let listResponse = try await s3.listObjectsV2(listRequest)

            // Sum up object sizes
            if let objects = listResponse.contents {
                for object in objects {
                    totalSize += object.size ?? 0
                }
            }

            continuationToken = listResponse.nextContinuationToken
        } while continuationToken != nil

        return totalSize
    }
}
