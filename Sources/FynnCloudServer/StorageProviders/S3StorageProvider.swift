import NIOConcurrencyHelpers
import NIOCore
import NIOFileSystem
import SotoS3
import Vapor

private final class S3StreamGuard: @unchecked Sendable {
    private let lock = NIOLockedValueBox(false)
    func claim() -> Bool {
        lock.withLockedValue { claimed in
            if claimed { return false }
            claimed = true
            return true
        }
    }
}


struct S3StorageProvider: FileStorageProvider {
    let s3: S3
    let bucket: String

    // MARK: - Single Request Upload (stream)

    func save(
        stream: Request.Body,
        key: String,
        maxSize: Int64,
        on eventLoop: any EventLoop
    ) async throws -> StorageSaveResult {
        let countingBody = ByteCountingBody(wrappedBody: stream, maxAllowedSize: maxSize)
        let body = AWSHTTPBody(asyncSequence: countingBody, length: Int(maxSize))
        let putRequest = S3.PutObjectRequest(
            body: body,
            bucket: bucket,
            key: key
        )

        let response = try await s3.putObject(putRequest)
        let etag = response.eTag?.replacingOccurrences(of: "\"", with: "") ?? ""

        return StorageSaveResult(size: countingBody.bytesReceived, hash: etag)
    }

    // MARK: - Single Request Upload (buffer)

    func save(buffer: ByteBuffer, key: String, contentType: String) async throws {
        let body = AWSHTTPBody(buffer: buffer)
        let putRequest = S3.PutObjectRequest(
            body: body,
            bucket: bucket,
            contentType: contentType,
            key: key
        )
        _ = try await s3.putObject(putRequest)
    }

    // MARK: - Download

    func downloadToFile(key: String, path: String, on eventLoop: any EventLoop) async throws {
        let output = try await s3.getObject(.init(bucket: bucket, key: key))

        // Stream the object body chunk-by-chunk to disk so RAM usage stays flat.
        try await FileSystem.shared.withFileHandle(
            forWritingAt: FilePath(path),
            options: .newFile(replaceExisting: true)
        ) { handle in
            var offset: Int64 = 0
            for try await chunk in output.body {
                _ = try await handle.write(contentsOf: chunk.readableBytesView, toAbsoluteOffset: offset)
                offset += Int64(chunk.readableBytes)
            }
        }
    }

    // MARK: - Get Response

    func getResponse(key: String, range: HTTPHeaders.Range?, on eventLoop: any EventLoop) async throws -> Response {
        var rangeHeader: String? = nil
        if let range = range, range.unit == .bytes, let firstRange = range.ranges.first {
            switch firstRange {
            case .start(let value):
                rangeHeader = "bytes=\(value)-"
            case .tail(let value):
                rangeHeader = "bytes=-\(value)"
            case .within(let lower, let upper):
                rangeHeader = "bytes=\(lower)-\(upper)"
            #if compiler(>=6.0)
            @unknown default:
                break
            #endif
            }
        }

        let output = try await s3.getObject(
            .init(bucket: bucket, key: key, range: rangeHeader))
        let body = output.body

        let status: HTTPResponseStatus = (rangeHeader != nil && output.contentRange != nil) ? .partialContent : .ok
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: "Content-Type", value: output.contentType ?? "application/octet-stream")
        headers.replaceOrAdd(name: "Accept-Ranges", value: "bytes")
        if let contentRange = output.contentRange {
            headers.replaceOrAdd(name: "Content-Range", value: contentRange)
        }

        if let contentLength = output.contentLength {
            headers.replaceOrAdd(name: "Content-Length", value: String(contentLength))
        }

        let responseBody: Response.Body
        if let contentLength = output.contentLength, contentLength <= 10 * 1024 * 1024 {
            let buffer = try await body.collect(upTo: Int(contentLength))
            responseBody = Response.Body(buffer: buffer)
        } else {
            let streamGuard = S3StreamGuard()
            responseBody = Response.Body(
                managedAsyncStream: { writer in
                    guard streamGuard.claim() else {
                        return
                    }
                    for try await buffer in body {
                        try await writer.write(.buffer(buffer))
                    }
                },
                count: output.contentLength.map(Int.init) ?? -1
            )
        }

        return Response(
            status: status,
            headers: headers,
            body: responseBody
        )
    }

    func delete(key: String) async throws {
        _ = try await s3.deleteObject(
            .init(bucket: bucket, key: key))
    }

    func exists(key: String) async throws -> Bool {
        do {
            _ = try await s3.headObject(
                .init(bucket: bucket, key: key))
            return true
        } catch {
            return false
        }
    }

    func copy(sourceKey: String, destinationKey: String) async throws {
        let request = S3.CopyObjectRequest(
            bucket: bucket,
            copySource: "\(bucket)/\(sourceKey)",
            key: destinationKey
        )
        _ = try await s3.copyObject(request)
    }

    // MARK: - Multipart Upload

    func initiateMultipartUpload(key: String) async throws -> String {
        let request = S3.CreateMultipartUploadRequest(
            bucket: bucket,
            key: key
        )

        let response = try await s3.createMultipartUpload(request)

        guard let uploadID = response.uploadId else {
            throw Abort(.internalServerError, reason: "S3 did not return upload ID")
        }

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
        let countingBody = ByteCountingBody(wrappedBody: stream, maxAllowedSize: maxSize)
        let body = AWSHTTPBody(asyncSequence: countingBody, length: Int(maxSize))

        let request = S3.UploadPartRequest(
            body: body,
            bucket: bucket,
            key: key,
            partNumber: partNumber,
            uploadId: uploadID
        )

        let response = try await s3.uploadPart(request)

        guard let etag = response.eTag?.replacingOccurrences(of: "\"", with: "") else {
            throw Abort(.internalServerError, reason: "S3 did not return ETag for part")
        }

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
        let completedParts = parts.map { part in
            S3.CompletedPart(eTag: part.etag, partNumber: part.partNumber)
        }

        let request = S3.CompleteMultipartUploadRequest(
            bucket: bucket,
            key: key,
            multipartUpload: S3.CompletedMultipartUpload(parts: completedParts),
            uploadId: uploadID
        )

        let response = try await s3.completeMultipartUpload(request)
        let etag = response.eTag?.replacingOccurrences(of: "\"", with: "") ?? ""

        // Measured from the assembled object in S3, not summed from client-declared part sizes.
        let head = try await s3.headObject(.init(bucket: bucket, key: key))
        guard let size = head.contentLength else {
            throw Abort(.internalServerError, reason: "S3 did not return object size")
        }

        return MultipartCompletionResult(hash: etag, size: size)
    }

    func abortMultipartUpload(key: String, uploadID: String) async throws {
        let request = S3.AbortMultipartUploadRequest(
            bucket: bucket,
            key: key,
            uploadId: uploadID
        )

        _ = try await s3.abortMultipartUpload(request)
    }

    // MARK: - User Operations

    func deleteUserData(userID: UUID) async throws {
        let prefix = "\(userID.uuidString)/"
        var continuationToken: String? = nil

        repeat {
            let listRequest = S3.ListObjectsV2Request(
                bucket: bucket,
                continuationToken: continuationToken,
                prefix: prefix
            )

            let listResponse = try await s3.listObjectsV2(listRequest)

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
