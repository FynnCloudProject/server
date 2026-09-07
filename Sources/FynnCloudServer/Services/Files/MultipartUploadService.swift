import Fluent
import Vapor
@preconcurrency import Redis

/// Chunked uploads: session lifecycle, part assembly, and the sweeper for sessions that were
/// never completed or aborted.
struct MultipartUploadService: Sendable {
    let context: FileServiceContext

    init(_ context: FileServiceContext) { self.context = context }

    private var db: any Database { context.db }
    private var logger: Logger { context.logger }
    private var storageService: StorageService { context.storage }
    private var redis: any RedisClient { context.redis }
    private var syncLogService: SyncLogService { context.syncLog }
    private var accessService: FileAccessService { FileAccessService(context) }
    private var quota: QuotaService { QuotaService(context) }

    struct InitiatedUploadSession: Sendable {
        let sessionID: UUID
        let fileID: UUID
        let uploadID: String
        let filename: String
        let contentType: String
        let totalSize: Int64
        let maxChunkSize: Int64
        let parentID: UUID?
        let lastModified: Int64?
        let createdAt: Int64?
        let userID: UUID
        let isUpdate: Bool
        let reservationID: String?
    }

    /// Where a multipart session will land, resolved once for both the create and update cases.
    private struct MultipartTarget {
        let fileID: UUID
        let filename: String
        let parentID: UUID?
        let ownerID: UUID
        let quotaDelta: Int64
        let isUpdate: Bool
    }

    private static let activeUploadSessionsKey = RedisKey("upload:active_sessions")

    /// Upload sessions live only in Redis; a failure here leaves the session untracked, so the
    /// expiry sweeper has nothing to reclaim.
    private func storeUploadSession(_ payload: MultipartSessionPayload) async {
        guard let data = try? JSONEncoder().encode(payload),
            let json = String(data: data, encoding: .utf8)
        else { return }

        do {
            _ = try await redis.hset(
                payload.sessionID.uuidString, to: json, in: Self.activeUploadSessionsKey).get()
        } catch {
            logger.error(
                "Failed to store upload session in Redis",
                metadata: [
                    "sessionID": .string(payload.sessionID.uuidString),
                    "error": .string("\(error)"),
                ])
        }
    }

    private func discardUploadSession(
        sessionID: UUID, reservationID: String?, userID: UUID
    ) async {
        if let reservationID {
            await quota.release(reservationID: reservationID, userID: userID)
        }
        _ = try? await redis.hdel(sessionID.uuidString, from: Self.activeUploadSessionsKey).get()
    }

    /// Aborts every in-flight upload for a user, used when their account is deleted.
    func abortAllSessions(userID: UUID) async {
        for session in await activeSessions() where session.userID == userID {
            try? await storageService.abortMultipartUpload(
                id: session.fileID, userID: userID, uploadID: session.uploadID)
            await discardUploadSession(
                sessionID: session.sessionID, reservationID: session.reservationID, userID: userID)
        }
        await quota.releaseAll(userID: userID)
    }

    private func activeSessions() async -> [MultipartSessionPayload] {
        let sessions = try? await redis.hgetall(from: Self.activeUploadSessionsKey)
            .map { dict -> [MultipartSessionPayload] in
                let decoder = JSONDecoder()
                return dict.values.compactMap { value in
                    guard let json = value.string, let data = json.data(using: .utf8) else { return nil }
                    return try? decoder.decode(MultipartSessionPayload.self, from: data)
                }
            }.get()
        return sessions ?? []
    }

    func initiateMultipartUpload(
        fileID: UUID? = nil,
        filename: String,
        contentType: String,
        totalSize: Int64,
        parentID: UUID?,
        lastModified: Int64?,
        createdAt: Int64? = nil,
        userID: UUID,
        maxChunkSize: Int64
    ) async throws -> InitiatedUploadSession {
        let sessionID = UUID()
        let target = try await resolveMultipartTarget(
            fileID: fileID, filename: filename, totalSize: totalSize, parentID: parentID,
            userID: userID)

        // Held in Redis only: the users table is not touched until the upload completes.
        let reservation = try await quota.reserve(
            bytes: target.quotaDelta, for: .multipart(sessionID: sessionID),
            userID: target.ownerID, ttl: UploadRules.sessionTTL)

        let uploadID: String
        do {
            uploadID = try await storageService.initiateMultipartUpload(
                id: target.fileID, userID: target.ownerID)
        } catch {
            await quota.release(reservation)
            throw error
        }

        await storeUploadSession(
            MultipartSessionPayload(
                sessionID: sessionID,
                fileID: target.fileID,
                uploadID: uploadID,
                userID: target.ownerID,
                filename: target.filename,
                totalSize: totalSize,
                parentID: target.parentID,
                expiresAt: Date().addingTimeInterval(UploadRules.sessionTTL),
                isUpdate: target.isUpdate,
                reservationID: reservation.bytes > 0 ? reservation.id : nil))

        logger.info(
            target.isUpdate ? "Multipart update initiated" : "Multipart upload initiated",
            metadata: [
                "sessionID": .string(sessionID.uuidString),
                "fileID": .string(target.fileID.uuidString),
                "uploadID": .string(uploadID),
                "filename": .string(target.filename),
            ]
        )

        return InitiatedUploadSession(
            sessionID: sessionID,
            fileID: target.fileID,
            uploadID: uploadID,
            filename: target.filename,
            contentType: MIMETypeDetector.detect(filename: target.filename, fallback: contentType),
            totalSize: totalSize,
            maxChunkSize: maxChunkSize,
            parentID: target.parentID,
            lastModified: lastModified,
            createdAt: createdAt,
            userID: target.ownerID,
            isUpdate: target.isUpdate,
            reservationID: reservation.bytes > 0 ? reservation.id : nil
        )
    }

    private func resolveMultipartTarget(
        fileID: UUID?, filename: String, totalSize: Int64, parentID: UUID?, userID: UUID
    ) async throws -> MultipartTarget {
        if let existingFileID = fileID {
            let access = try await accessService.validateAccess(
                fileID: existingFileID, userID: userID, required: .write)
            let existingFile = access.file
            guard !existingFile.isDirectory else {
                throw Abort(.badRequest, reason: "Directories cannot be updated with file content.")
                    .localized(LocalizationKeys.Error.Upload.Unknown)
            }
            return MultipartTarget(
                fileID: existingFileID,
                filename: existingFile.filename,
                parentID: existingFile.$parent.id,
                ownerID: access.ownerID,
                quotaDelta: Swift.max(0, totalSize - existingFile.size),
                isUpdate: true)
        }

        let cleanFilename = FilenameValidator.sanitize(filename: filename)
        var ownerID = userID
        if let parentID = parentID {
            let parentAccess = try await accessService.validateAccess(
                fileID: parentID, userID: userID, required: .write)
            guard parentAccess.file.isDirectory else {
                throw Abort(.badRequest, reason: "Parent must be a directory.")
            }
            ownerID = parentAccess.ownerID
        }
        try await FileNaming.ensureUnique(name: cleanFilename, parentID: parentID, ownerID: ownerID, on: db)

        return MultipartTarget(
            fileID: UUID(),
            filename: cleanFilename,
            parentID: parentID,
            ownerID: ownerID,
            quotaDelta: totalSize,
            isUpdate: false)
    }

    func uploadPart(
        fileID: UUID,
        uploadID: String,
        partNumber: Int,
        userID: UUID,
        stream: Request.Body,
        size: Int64
    ) async throws -> CompletedPart {
        guard partNumber > 0 && partNumber <= UploadRules.maxParts else {
            throw Abort(
                .badRequest, reason: "Part number must be between 1 and \(UploadRules.maxParts)")
        }

        let completedPart = try await storageService.uploadPart(
            id: fileID,
            userID: userID,
            uploadID: uploadID,
            partNumber: partNumber,
            stream: stream,
            maxSize: size
        )

        logger.debug(
            "Part uploaded",
            metadata: [
                "fileID": .string(fileID.uuidString),
                "partNumber": .string("\(partNumber)"),
                "etag": .string(completedPart.etag),
                "size": .string("\(completedPart.size)"),
            ]
        )

        return completedPart
    }

    /// Parts must be a complete, duplicate-free 1...n run or the assembled object would be corrupt.
    private static func sortedCompleteParts(_ parts: [CompletedPart]) throws -> [CompletedPart] {
        guard !parts.isEmpty else {
            throw Abort(.badRequest, reason: "No parts provided")
        }
        let numbers = Set(parts.map { $0.partNumber })
        guard numbers.count == parts.count, numbers == Set(1...parts.count) else {
            throw Abort(.badRequest, reason: "Missing or duplicate parts - upload incomplete")
        }
        return parts.sorted { $0.partNumber < $1.partNumber }
    }

    func completeMultipartUpload(
        sessionID: UUID,
        fileID: UUID,
        uploadID: String,
        userID: UUID,
        filename: String,
        contentType: String,
        totalSize: Int64,
        parentID: UUID?,
        lastModified: Int64?,
        createdAt: Int64? = nil,
        isUpdate: Bool = false,
        reservationID: String? = nil,
        parts: [CompletedPart]
    ) async throws -> FileMetadata {
        let sortedParts = try Self.sortedCompleteParts(parts)
        let reservation = reservationID.map {
            Reservation(id: $0, userID: userID, bytes: totalSize)
        }

        let metadata: FileMetadata
        if isUpdate {
            metadata = try await completeMultipartUpdate(
                fileID: fileID, uploadID: uploadID, userID: userID, contentType: contentType,
                totalSize: totalSize, lastModified: lastModified, reservation: reservation,
                parts: sortedParts)
        } else {
            metadata = try await completeMultipartCreate(
                sessionID: sessionID, fileID: fileID, uploadID: uploadID, userID: userID,
                filename: filename, contentType: contentType, totalSize: totalSize,
                parentID: parentID, lastModified: lastModified, createdAt: createdAt,
                reservation: reservation, parts: sortedParts)
        }

        await discardUploadSession(
            sessionID: sessionID, reservationID: reservationID, userID: userID)

        logger.info(
            isUpdate ? "Multipart update completed" : "Multipart upload completed",
            metadata: [
                "sessionID": .string(sessionID.uuidString),
                "fileID": .string(fileID.uuidString),
                "filename": .string(metadata.filename),
                "size": .string("\(totalSize)"),
            ]
        )

        return metadata
    }

    private func completeMultipartUpdate(
        fileID: UUID,
        uploadID: String,
        userID: UUID,
        contentType: String,
        totalSize: Int64,
        lastModified: Int64?,
        reservation: Reservation?,
        parts: [CompletedPart]
    ) async throws -> FileMetadata {
        guard let existingFile = try await FileMetadata.find(fileID, on: db) else {
            throw Abort(.notFound, reason: "File not found")
        }

        let result = try await storageService.completeMultipartUpload(
            id: fileID, userID: userID, uploadID: uploadID, parts: parts)
        try await rejectIfOversized(
            realSize: result.size, claimedTotalSize: totalSize, fileID: fileID, userID: userID,
            reservation: reservation)

        let delta = result.size - existingFile.size
        existingFile.size = result.size
        existingFile.contentType = MIMETypeDetector.detect(
            filename: existingFile.filename, fallback: contentType)
        existingFile.hash = result.hash
        existingFile.updatedAt = Date()
        if let lastModified = UploadRules.date(fromEpochMilliseconds: lastModified) {
            existingFile.lastModified = lastModified
        }

        try await existingFile.save(on: db)
        try await commitUsage(reservation, userID: userID, bytes: delta)

        await syncLogService.emitToOwnerAndGrantees(
            on: db, ownerID: userID, file: existingFile, eventType: .modify)

        return existingFile
    }

    /// A session initiated with a zero delta (a shrinking update) holds no reservation, but the
    /// durable counter still has to move.
    private func commitUsage(_ reservation: Reservation?, userID: UUID, bytes: Int64) async throws {
        if let reservation {
            try await quota.commit(reservation, actualBytes: bytes)
        } else {
            try await quota.releaseCommitted(bytes: -bytes, userID: userID)
        }
    }

    /// The client's declared `totalSize` only sizes the quota hold taken at initiate; committed
    /// usage always reflects what storage actually assembled. An assembly that lands far beyond
    /// what was reserved is rejected outright rather than silently accounted for, so a session
    /// can't be opened small and filled large.
    private func rejectIfOversized(
        realSize: Int64, claimedTotalSize: Int64, fileID: UUID, userID: UUID,
        reservation: Reservation?
    ) async throws {
        guard realSize > UploadRules.maxAllowedSize(claiming: claimedTotalSize) else { return }
        try? await storageService.delete(id: fileID, userID: userID)
        if let reservation {
            await quota.release(reservation)
        }
        logger.warning(
            "Rejected multipart completion exceeding declared size",
            metadata: [
                "fileID": .string(fileID.uuidString),
                "claimedTotalSize": .string("\(claimedTotalSize)"),
                "realSize": .string("\(realSize)"),
            ]
        )
        throw Abort(.payloadTooLarge, reason: "Quota exceeded.").localized(
            LocalizationKeys.Error.Upload.QuotaExceeded)
    }

    private func completeMultipartCreate(
        sessionID: UUID,
        fileID: UUID,
        uploadID: String,
        userID: UUID,
        filename: String,
        contentType: String,
        totalSize: Int64,
        parentID: UUID?,
        lastModified: Int64?,
        createdAt: Int64?,
        reservation: Reservation?,
        parts: [CompletedPart]
    ) async throws -> FileMetadata {
        if let existing = try await FileMetadata.find(fileID, on: db) {
            logger.warning(
                "Attempted double-completion of upload",
                metadata: [
                    "sessionID": .string(sessionID.uuidString),
                    "fileID": .string(fileID.uuidString),
                    "uploadID": .string(uploadID),
                    "existingFile": .string(existing.filename),
                ]
            )
            throw Abort(.conflict, reason: "Upload already completed")
        }

        // Checked before assembly so a doomed upload is never materialised into storage.
        try await FileNaming.ensureUnique(name: filename, parentID: parentID, ownerID: userID, on: db)

        var ancestorIDs: [UUID] = []
        if let parentID = parentID, let parent = try await FileMetadata.find(parentID, on: db) {
            ancestorIDs = parent.ancestorIDs + [parentID]
        }

        let result = try await storageService.completeMultipartUpload(
            id: fileID, userID: userID, uploadID: uploadID, parts: parts)
        try await rejectIfOversized(
            realSize: result.size, claimedTotalSize: totalSize, fileID: fileID, userID: userID,
            reservation: reservation)

        let resolvedLastModified = UploadRules.date(fromEpochMilliseconds: lastModified) ?? Date()
        let metadata = FileMetadata(
            id: fileID,
            filename: filename,
            contentType: MIMETypeDetector.detect(filename: filename, fallback: contentType),
            size: result.size,
            parentID: parentID,
            ownerID: userID,
            createdAt: UploadRules.date(fromEpochMilliseconds: createdAt) ?? resolvedLastModified,
            lastModified: resolvedLastModified,
            hash: result.hash,
            ancestorIDs: ancestorIDs
        )

        do {
            try await metadata.save(on: db)
        } catch {
            // The object is already assembled, so drop it rather than leaking storage.
            try? await storageService.delete(id: fileID, userID: userID)
            logger.scoped(to: .storage).error(
                "Failed to save metadata on upload completion",
                metadata: [
                    "file_id": .stringConvertible(fileID),
                    "filename": .string(filename),
                    "error": .string("\(error)"),
                ]
            )
            throw error
        }

        await syncLogService.emitToOwnerAndGrantees(
            on: db, ownerID: userID, file: metadata, eventType: .create)
        try await commitUsage(reservation, userID: userID, bytes: result.size)

        return metadata
    }

    func abortMultipartUpload(
        fileID: UUID,
        uploadID: String,
        sessionID: UUID,
        totalSize: Int64,
        userID: UUID,
        reservationID: String? = nil
    ) async throws {
        await discardUploadSession(
            sessionID: sessionID, reservationID: reservationID, userID: userID)

        try? await storageService.abortMultipartUpload(
            id: fileID,
            userID: userID,
            uploadID: uploadID
        )

        logger.info(
            "Multipart upload aborted",
            metadata: [
                "sessionID": .string(sessionID.uuidString),
                "fileID": .string(fileID.uuidString),
                "uploadID": .string(uploadID),
            ]
        )
    }

    func cleanupExpiredUploads() async {
        // 1. Filesystem safety sweeper for orphaned chunk directories
        await storageService.cleanupOrphanedChunkDirectories()

        // 2. Clean up expired Redis upload sessions
        let now = Date()
        for session in await activeSessions() where session.expiresAt < now {
            try? await storageService.abortMultipartUpload(
                id: session.fileID,
                userID: session.userID,
                uploadID: session.uploadID
            )
            await discardUploadSession(
                sessionID: session.sessionID, reservationID: session.reservationID,
                userID: session.userID)

            logger.info(
                "Cleaned up expired upload from Redis",
                metadata: [
                    "sessionID": .string(session.sessionID.uuidString),
                    "fileID": .string(session.fileID.uuidString),
                    "userID": .string(session.userID.uuidString),
                ]
            )
        }
    }

}
