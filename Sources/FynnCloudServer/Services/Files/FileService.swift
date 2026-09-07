import Crypto
import Fluent
import FluentSQL
import SQLKit
import Vapor
@preconcurrency import Redis

/// The write side of the file tree: creating, updating, moving, copying, trashing and deleting
/// files, plus the download responses served from them.
///
/// Reads are `FileListingService` and `FileSearchService`; permissions are `FileAccessService`;
/// storage accounting is `QuotaService`; chunked uploads are `MultipartUploadService`.
struct FileService: Sendable {
    /// Expired trash is reclaimed in batches so a large backlog cannot exhaust memory.
    static let trashCleanupBatchSize = 500

    let context: FileServiceContext

    init(_ context: FileServiceContext) { self.context = context }

    private var db: any Database { context.db }
    private var logger: Logger { context.logger }
    private var storageService: StorageService { context.storage }
    private var syncLogService: SyncLogService { context.syncLog }
    private var accessService: FileAccessService { FileAccessService(context) }
    private var quota: QuotaService { QuotaService(context) }
    private var uploads: MultipartUploadService { MultipartUploadService(context) }

    // MARK: - WebDAV Path Resolution

    /// Resolves a hierarchical path (already percent-decoded segments) to its `FileMetadata`,
    /// scoped to the owner. Returns `nil` when any segment is missing. Empty segments = root.
    func resolvePath(_ segments: [String], userID: UUID) async throws -> FileMetadata? {
        var parentID: UUID? = nil
        var current: FileMetadata? = nil
        for segment in segments where !segment.isEmpty {
            guard
                let match = try await FileMetadata.query(on: db)
                    .filter(\.$owner.$id == userID)
                    .filter(\.$parent.$id == parentID)
                    .filter(\.$filename == segment)
                    .filter(\.$deletedAt == nil)
                    .first()
            else { return nil }
            current = match
            parentID = try match.requireID()
        }
        return current
    }

    /// Immediate, non-deleted children of a directory (or of the root when `dirID` is nil).
    func children(ofDirectory dirID: UUID?, userID: UUID) async throws -> [FileMetadata] {
        try await FileMetadata.query(on: db)
            .filter(\.$owner.$id == userID)
            .filter(\.$parent.$id == dirID)
            .filter(\.$deletedAt == nil)
            .sort(\.$isDirectory, .descending)
            .sort(\.$filename, .ascending)
            .all()
    }

    /// Recursively copies a file or directory tree into `destParentID` under `newName`.
    @discardableResult
    func copyItem(fileID: UUID, destParentID: UUID?, newName: String, userID: UUID) async throws -> FileMetadata {
        let sourceAccess = try await accessService.validateAccess(fileID: fileID, userID: userID, required: .read)
        let source = sourceAccess.file

        var destAncestorIDs: [UUID] = []
        var destOwnerID = userID
        if let pID = destParentID {
            let parentAccess = try await accessService.validateAccess(fileID: pID, userID: userID, required: .write)
            let parent = parentAccess.file
            guard parent.isDirectory else {
                throw Abort(.conflict, reason: "Copy destination parent must be a directory.")
            }
            if source.isDirectory, pID == fileID || parent.ancestorIDs.contains(fileID) {
                throw Abort(.forbidden, reason: "Cannot copy a folder into itself or a descendant.")
            }
            destOwnerID = parentAccess.ownerID
            destAncestorIDs = parent.ancestorIDs + [pID]
        }

        try await FileNaming.ensureUnique(name: newName, parentID: destParentID, ownerID: destOwnerID, on: db)
        return try await copyNode(
            source: source, destParentID: destParentID, destAncestorIDs: destAncestorIDs,
            newName: newName, sourceOwnerID: sourceAccess.ownerID, destOwnerID: destOwnerID)
    }

    private func copyNode(
        source: FileMetadata, destParentID: UUID?, destAncestorIDs: [UUID], newName: String,
        sourceOwnerID: UUID, destOwnerID: UUID
    ) async throws -> FileMetadata {
        if source.isDirectory {
            let newDir = FileMetadata(
                filename: newName, contentType: "directory", size: 0, isDirectory: true,
                parentID: destParentID, ownerID: destOwnerID, lastModified: Date(),
                ancestorIDs: destAncestorIDs)
            try await newDir.save(on: db)
            let newDirID = try newDir.requireID()
            await syncLogService.emitToOwnerAndGrantees(
                on: db, ownerID: destOwnerID, file: newDir, eventType: .create)

            let kids = try await FileMetadata.query(on: db)
                .filter(\.$parent.$id == source.id)
                .filter(\.$deletedAt == nil)
                .all()
            for kid in kids {
                _ = try await copyNode(
                    source: kid, destParentID: newDirID,
                    destAncestorIDs: destAncestorIDs + [newDirID], newName: kid.filename,
                    sourceOwnerID: sourceOwnerID, destOwnerID: destOwnerID)
            }
            return newDir
        }

        let newID = UUID()
        return try await quota.withReservation(
            bytes: source.size, for: .copy(fileID: newID), userID: destOwnerID
        ) { reservation in
            try await storageService.copy(
                sourceID: try source.requireID(), destID: newID, sourceUserID: sourceOwnerID,
                destUserID: destOwnerID)

            let meta = FileMetadata(
                id: newID, filename: newName, contentType: source.contentType, size: source.size,
                parentID: destParentID, ownerID: destOwnerID, lastModified: source.lastModified,
                hash: source.hash, ancestorIDs: destAncestorIDs)
            do {
                try await meta.save(on: db)
            } catch {
                try? await storageService.delete(id: newID, userID: destOwnerID)
                throw error
            }

            try await quota.commit(reservation, actualBytes: source.size)
            await syncLogService.emitToOwnerAndGrantees(
                on: db, ownerID: destOwnerID, file: meta, eventType: .create)
            return meta
        }
    }

    func getFileResponse(for id: UUID, userID: UUID, range: HTTPHeaders.Range? = nil) async throws -> Response {
        let access = try await accessService.validateAccess(fileID: id, userID: userID, required: .read)
        guard !access.file.isDirectory else {
            throw Abort(.badRequest, reason: "Cannot download a directory.").localized(
                LocalizationKeys.Error.Http.Generic)
        }
        return try await storageService.getFileResponse(for: id, userID: access.ownerID, range: range)
    }

    func getFileResponse(for metadata: FileMetadata, userID: UUID, range: HTTPHeaders.Range? = nil) async throws -> Response {
        try await getFileResponse(for: try metadata.requireID(), userID: userID, range: range)
    }

    /// Streams a file WITHOUT any permission check. Only for callers that have already authorised
    /// the request by other means (a validated share link or WOPI token).
    func getPreauthorizedFileResponse(
        for id: UUID, ownerID: UUID, range: HTTPHeaders.Range? = nil
    ) async throws -> Response {
        try await storageService.getFileResponse(for: id, userID: ownerID, range: range)
    }

    /// Strong validator for a stored file: its content hash when known, otherwise identity plus
    /// modification time and size.
    static func etag(for file: FileMetadata, fallbackID: UUID? = nil) -> String {
        if let contentHash = file.hash { return "\"\(contentHash)\"" }
        let id = file.id ?? fallbackID ?? UUID()
        let lastModified = file.updatedAt ?? file.createdAt ?? Date()
        return "\"\(id.uuidString)-\(Int(lastModified.timeIntervalSince1970))-\(file.size)\""
    }

    /// RFC 6266 value carrying both an ASCII fallback and the real UTF-8 filename.
    static func contentDispositionValue(filename: String, isInline: Bool) -> String {
        let ascii = filename
            .folding(options: .diacriticInsensitive, locale: .current)
            .filter { $0.isASCII && $0 != "\"" && $0 != "\\" }
        let fallback = ascii.isEmpty ? "file" : ascii
        let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
        let disposition = isInline ? "inline" : "attachment"
        return "\(disposition); filename=\"\(fallback)\"; filename*=UTF-8''\(encoded)"
    }

    /// No-ops for provider redirects to presigned URLs, which carry their own headers.
    static func applyDownloadHeaders(
        to response: Response, file: FileMetadata, etag: String, isInline: Bool
    ) {
        guard ![.seeOther, .temporaryRedirect].contains(response.status) else { return }
        response.headers.replaceOrAdd(
            name: .contentDisposition,
            value: contentDispositionValue(filename: file.filename, isInline: isInline))
        response.headers.replaceOrAdd(
            name: .contentType,
            value: MIMETypeDetector.detect(filename: file.filename, fallback: file.contentType))
        response.headers.replaceOrAdd(name: .eTag, value: etag)
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
    }

    static func notModifiedResponse(etag: String) -> Response {
        let response = Response(status: .notModified)
        response.headers.replaceOrAdd(name: .eTag, value: etag)
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
        return response
    }

    func getDownloadResponse(
        fileID: UUID,
        userID: UUID,
        range: HTTPHeaders.Range? = nil,
        ifNoneMatch: String? = nil,
        isInline: Bool = false
    ) async throws -> Response {
        let access = try await accessService.validateAccess(fileID: fileID, userID: userID, required: .read)
        let file = access.file

        guard !file.isDirectory else {
            throw Abort(.badRequest, reason: "Cannot download a directory.").localized(LocalizationKeys.Error.Http.Generic)
        }

        let etag = Self.etag(for: file, fallbackID: fileID)
        if let ifNoneMatch, ifNoneMatch == etag {
            return Self.notModifiedResponse(etag: etag)
        }

        let response = try await storageService.getFileResponse(
            for: file.id ?? fileID, userID: access.ownerID, range: range)
        Self.applyDownloadHeaders(to: response, file: file, etag: etag, isInline: isInline)
        return response
    }

    /// A thumbnail, or the file it should be generated for. Job dispatch is the caller's business
    /// so the service stays free of the request/queue layer.
    enum ThumbnailLookup {
        case available(Response)
        case needsGeneration(FileMetadata)
    }

    func getThumbnail(fileID: UUID, userID: UUID) async throws -> ThumbnailLookup {
        let access = try await accessService.validateAccess(fileID: fileID, userID: userID, required: .read)
        let file = access.file

        guard !file.isDirectory else {
            throw Abort(.badRequest, reason: "Cannot get thumbnail for a directory.")
        }

        guard file.hasThumbnail else { return .needsGeneration(file) }

        do {
            return .available(
                try await storageService.thumbnailResponse(fileID: fileID, userID: access.ownerID))
        } catch {
            // The flag is stale: the blob is gone, so let the caller queue a regeneration.
            file.hasThumbnail = false
            try? await file.save(on: db)
            return .needsGeneration(file)
        }
    }

    // MARK: - Actions

    func upload(
        filename: String,
        stream: Request.Body,
        claimedSize: Int64,
        contentType: String,
        parentID: UUID?,
        userID: UUID,
        lastModified: Int64? = nil,
        createdAt: Int64? = nil
    ) async throws -> FileMetadata {
        let fileID = UUID()
        var targetOwnerID = userID
        var ancestorIDs: [UUID] = []
        if let pID = parentID {
            let parentAccess = try await accessService.validateAccess(fileID: pID, userID: userID, required: .write)
            let parent = parentAccess.file
            guard parent.isDirectory else {
                throw Abort(.badRequest, reason: "Parent must be a directory.")
            }
            targetOwnerID = parentAccess.ownerID
            ancestorIDs = parent.ancestorIDs + [pID]
        }

        let cleanFilename = FilenameValidator.sanitize(filename: filename)

        try await FileNaming.ensureUnique(name: cleanFilename, parentID: parentID, ownerID: targetOwnerID, on: db)

        let maxAllowedSize = UploadRules.maxAllowedSize(claiming: claimedSize)

        return try await quota.withReservation(
            bytes: claimedSize, for: .upload(fileID: fileID), userID: targetOwnerID
        ) { reservation in
            let saveResult = try await storageService.save(
                stream: stream,
                id: fileID,
                userID: targetOwnerID,
                maxSize: maxAllowedSize
            )

            let actualSize = saveResult.size
            if actualSize > claimedSize + UploadRules.sizeTolerance {
                logger.scoped(to: .storage).error(
                    "Upload size mismatch, discarding",
                    metadata: [
                        "user_id": .stringConvertible(targetOwnerID),
                        "claimed_size": .stringConvertible(claimedSize),
                        "actual_size": .stringConvertible(actualSize),
                    ]
                )
                try? await storageService.delete(id: fileID, userID: targetOwnerID)
                throw Abort(
                    .badRequest,
                    reason: """
                        Upload size mismatch. Claimed \(claimedSize) bytes, \
                        but received \(actualSize) bytes.
                        """
                )
            }

            let resolvedLastModified = UploadRules.date(fromEpochMilliseconds: lastModified) ?? Date()
            let resolvedCreatedAt =
                UploadRules.date(fromEpochMilliseconds: createdAt) ?? resolvedLastModified

            let metadata = FileMetadata(
                id: fileID,
                filename: cleanFilename,
                contentType: MIMETypeDetector.detect(filename: cleanFilename, fallback: contentType),
                size: actualSize,
                parentID: parentID,
                ownerID: targetOwnerID,
                createdAt: resolvedCreatedAt,
                lastModified: resolvedLastModified,
                hash: saveResult.hash,
                ancestorIDs: ancestorIDs
            )

            do {
                try await metadata.save(on: db)
            } catch {
                try? await storageService.delete(id: fileID, userID: targetOwnerID)
                throw error
            }

            // The durable counter only ever sees the bytes actually stored.
            try await quota.commit(reservation, actualBytes: actualSize)
            await syncLogService.emitToOwnerAndGrantees(
                on: db, ownerID: targetOwnerID, file: metadata, eventType: .create)
            return metadata
        }
    }

    func update(
        fileID: UUID,
        stream: Request.Body,
        claimedSize: Int64,
        contentType: String,
        userID: UUID,
        lastModified: Int64? = nil
    ) async throws -> FileMetadata {
        let access = try await accessService.validateAccess(fileID: fileID, userID: userID, required: .write)
        let existingFile = access.file
        let targetOwnerID = access.ownerID

        guard !existingFile.isDirectory else {
            throw Abort(.badRequest, reason: "Directories cannot be updated with file content.")
                .localized(LocalizationKeys.Error.Upload.Unknown)
        }

        let claimedDelta = Swift.max(0, claimedSize - existingFile.size)
        let maxAllowedSize = UploadRules.maxAllowedSize(claiming: claimedSize)

        // Admission happens before a single byte reaches the provider: a rejection here must not
        // leave new content on disk with the old size in the database.
        return try await quota.withReservation(
            bytes: claimedDelta, for: .update(fileID: fileID), userID: targetOwnerID
        ) { reservation in
            let saveResult = try await storageService.save(
                stream: stream,
                id: fileID,
                userID: targetOwnerID,
                maxSize: maxAllowedSize
            )

            let actualSize = saveResult.size
            let previousSize = existingFile.size

            existingFile.size = actualSize
            existingFile.contentType = MIMETypeDetector.detect(
                filename: existingFile.filename, fallback: contentType)
            existingFile.hash = saveResult.hash
            existingFile.updatedAt = Date()
            if let lastModified = UploadRules.date(fromEpochMilliseconds: lastModified) {
                existingFile.lastModified = lastModified
            }

            try await existingFile.save(on: db)
            try await quota.commit(reservation, actualBytes: actualSize - previousSize)
            await syncLogService.emitToOwnerAndGrantees(
                on: db, ownerID: targetOwnerID, file: existingFile, eventType: .modify)
            return existingFile
        }
    }

    /// Overwrites an existing file's content from an in-memory buffer. Used by the native EuroOffice
    /// save callback, which downloads the edited document server-side (no `Request.Body` stream).
    func updateFromData(
        fileID: UUID,
        buffer: ByteBuffer,
        contentType: String,
        userID: UUID,
        lastModified: Int64? = nil
    ) async throws -> FileMetadata {
        let access = try await accessService.validateAccess(fileID: fileID, userID: userID, required: .write)
        let existingFile = access.file
        let targetOwnerID = access.ownerID

        guard !existingFile.isDirectory else {
            throw Abort(.badRequest, reason: "Directories cannot be updated with file content.")
        }

        let newSize = Int64(buffer.readableBytes)
        let delta = newSize - existingFile.size

        return try await quota.withReservation(
            bytes: Swift.max(0, delta), for: .update(fileID: fileID), userID: targetOwnerID
        ) { reservation in
            try await storageService.saveFileBuffer(
                id: fileID, userID: targetOwnerID, buffer: buffer, contentType: contentType)

            // Content hash uses the same MD5 scheme as the streaming storage save path.
            let hash = Insecure.MD5.hash(data: Data(buffer.readableBytesView))
                .map { String(format: "%02x", $0) }.joined()

            existingFile.size = newSize
            existingFile.contentType = MIMETypeDetector.detect(
                filename: existingFile.filename, fallback: contentType)
            existingFile.hash = hash
            existingFile.updatedAt = Date()
            if let lastModified = UploadRules.date(fromEpochMilliseconds: lastModified) {
                existingFile.lastModified = lastModified
            }
            try await existingFile.save(on: db)

            try await quota.commit(reservation, actualBytes: delta)
            await syncLogService.emitToOwnerAndGrantees(
                on: db, ownerID: targetOwnerID, file: existingFile, eventType: .modify)
            return existingFile
        }
    }

    func rename(fileID: UUID, newName: String, userID: UUID) async throws -> FileMetadata {
        try FilenameValidator.validate(filename: newName)
        let access = try await accessService.validateAccess(fileID: fileID, userID: userID, required: .write)
        let file = access.file
        let oldFilename = file.filename

        if !file.isDirectory {
            file.contentType = MIMETypeDetector.detect(filename: newName)
        }

        if file.filename == newName {
            if file.hasChanges {
                try await file.save(on: db)
            }
            return file
        }

        try await FileNaming.ensureUnique(
            name: newName, parentID: file.$parent.id, ownerID: access.ownerID, on: db)

        file.filename = newName
        try await file.save(on: db)
        await syncLogService.emitToOwnerAndGrantees(
            on: db,
            ownerID: access.ownerID,
            file: file,
            eventType: .rename,
            oldFilename: oldFilename
        )

        return file
    }

    func move(fileID: UUID, newParentID: UUID?, userID: UUID) async throws -> FileMetadata {
        let sourceAccess = try await accessService.validateAccess(fileID: fileID, userID: userID, required: .delete)
        let file = sourceAccess.file
        let oldParentID = file.$parent.id

        if file.$parent.id == newParentID { return file }

        var newAncestorIDs: [UUID] = []
        var targetOwnerID = sourceAccess.ownerID
        if let pID = newParentID {
            let parentAccess = try await accessService.validateAccess(fileID: pID, userID: userID, required: .write)
            let parent = parentAccess.file
            guard parent.isDirectory else {
                throw Abort(.badRequest, reason: "Cannot move file into a non-directory item.")
                    .localized(LocalizationKeys.Error.Files.MoveFailed)
            }
            guard parentAccess.ownerID == sourceAccess.ownerID else {
                throw Abort(.forbidden, reason: "Cannot move items across different accounts.")
                    .localized(LocalizationKeys.Error.Files.MoveFailed)
            }
            if file.isDirectory {
                if pID == fileID || parent.ancestorIDs.contains(fileID) {
                    throw Abort(.badRequest, reason: "Cannot move a folder into itself or one of its descendants.")
                        .localized(LocalizationKeys.Error.Files.MoveFailed)
                }
            }
            targetOwnerID = parentAccess.ownerID
            newAncestorIDs = parent.ancestorIDs + [pID]
        } else {
            guard sourceAccess.ownerID == userID else {
                throw Abort(.forbidden, reason: "Cannot move shared items to personal root.")
                    .localized(LocalizationKeys.Error.Files.MoveFailed)
            }
        }

        try await FileNaming.ensureUnique(name: file.filename, parentID: newParentID, ownerID: targetOwnerID, on: db)

        let targetAncestorIDs = newAncestorIDs
        let resolvedOwnerID = targetOwnerID

        if file.isDirectory {
            let newPrefix = targetAncestorIDs + [fileID]
            let oldPrefixLength = file.ancestorIDs.count + 1

            try await db.transaction { transactionDB in
                file.$parent.id = newParentID
                file.ancestorIDs = targetAncestorIDs
                try await file.save(on: transactionDB)

                guard let sql = transactionDB as? any SQLDatabase else {
                    throw Abort(.internalServerError, reason: "Move requires a SQL database.")
                        .localized(LocalizationKeys.Error.Files.MoveFailed)
                }

                if sql.dialect.name == "postgresql" {
                    let newPrefixValues = newPrefix.map(\.uuidString)
                    try await sql.raw(
                        """
                        UPDATE file_metadata
                        SET ancestor_ids = \(bind: newPrefixValues)::uuid[]
                            || ancestor_ids[\(unsafeRaw: String(oldPrefixLength + 1)) : array_length(ancestor_ids, 1)]
                        WHERE ancestor_ids @> ARRAY[\(bind: fileID.uuidString)]::uuid[]
                        """
                    ).run()
                } else {
                    // No array operators outside Postgres, so rewrite the subtree row by row.
                    let descendants = try await self.fetchAllDescendants(
                        of: fileID, userID: resolvedOwnerID, on: transactionDB)
                    for child in descendants where child.id != fileID {
                        guard let index = child.ancestorIDs.firstIndex(of: fileID) else { continue }
                        child.ancestorIDs = newPrefix + child.ancestorIDs[(index + 1)...]
                        try await child.save(on: transactionDB)
                    }
                }
            }
        } else {
            file.$parent.id = newParentID
            file.ancestorIDs = targetAncestorIDs
            try await file.save(on: db)
        }

        // Only the owner is notified: a move can take the file out of a folder someone else has
        // shared, which is a removal for them rather than a move.
        await syncLogService.emit(
            on: db,
            userID: targetOwnerID,
            file: file,
            eventType: .move,
            oldParentID: oldParentID
        )

        return file
    }

    func restore(fileID: UUID, userID: UUID) async throws -> FileMetadata {
        let file = try await FileMetadata.query(on: db)
            .withDeleted()
            .filter(\.$id == fileID)
            .filter(\.$owner.$id == userID)
            .first()

        guard let file = file else {
            throw Abort(.notFound).localized(LocalizationKeys.Error.Files.RestoreFailed)
        }

        guard let trashGroupID = file.trashGroupID else {
            throw Abort(.badRequest, reason: "File is not in trash.").localized(
                LocalizationKeys.Error.Files.RestoreFailed)
        }

        if let originalParentID = file.originalParentID {
            let parent = try await FileMetadata.query(on: db)
                .filter(\.$id == originalParentID)
                .first()
            file.$parent.id = parent == nil ? nil : originalParentID
        } else {
            file.$parent.id = nil
        }

        file.filename = try await FileNaming.available(
            basedOn: file.filename,
            isDirectory: file.isDirectory,
            parentID: file.$parent.id,
            ownerID: userID,
            excluding: fileID,
            on: db)
        try await file.restore(on: db)

        file.trashGroupID = nil
        file.originalParentID = nil
        try await file.save(on: db)

        await syncLogService.emitToOwnerAndGrantees(
            on: db, ownerID: userID, file: file, eventType: .restore)

        if file.isDirectory {
            try await restoreDescendants(
                of: try file.requireID(), userID: userID, trashGroupID: trashGroupID)
            let descendants = try await fetchAllDescendants(of: try file.requireID(), userID: userID)
            for descendant in descendants where descendant.id != file.id {
                await syncLogService.emitToOwnerAndGrantees(
                    on: db, ownerID: userID, file: descendant, eventType: .restore)
            }
        }

        logger.info(
            "File restored from trash",
            metadata: [
                "fileID": .string(fileID.uuidString),
                "userID": .string(userID.uuidString),
                "action": "restore_file",
                "newFilename": .string(file.filename),
            ])

        return file
    }

    func createDirectory(name: String, parentID: UUID?, userID: UUID) async throws -> FileMetadata {
        try FilenameValidator.validate(filename: name)
        var targetOwnerID = userID
        let ancestorIDs: [UUID]
        if let pID = parentID {
            let parentAccess = try await accessService.validateAccess(fileID: pID, userID: userID, required: .write)
            guard parentAccess.file.isDirectory else {
                throw Abort(.badRequest, reason: "Parent must be a directory.")
            }
            targetOwnerID = parentAccess.ownerID
            ancestorIDs = parentAccess.file.ancestorIDs + [pID]
        } else {
            ancestorIDs = []
        }

        try await FileNaming.ensureUnique(name: name, parentID: parentID, ownerID: targetOwnerID, on: db)

        let dir = FileMetadata(
            filename: name,
            contentType: "directory",
            size: 0,
            isDirectory: true,
            parentID: parentID,
            ownerID: targetOwnerID,
            lastModified: Date(),
            ancestorIDs: ancestorIDs
        )

        try await dir.save(on: db)
        await syncLogService.emitToOwnerAndGrantees(
            on: db, ownerID: targetOwnerID, file: dir, eventType: .create)

        let dirID = try dir.requireID()
        logger.debug("Directory entity saved", metadata: ["fileID": .string(dirID.uuidString)])

        return dir
    }

    func createFile(name: String, type: NewFileType, parentID: UUID?, userID: UUID) async throws -> FileMetadata {
        try FilenameValidator.validate(filename: name)
        let filename = "\(name).\(type.fileExtension)"
        try FilenameValidator.validate(filename: filename)
        var targetOwnerID = userID
        let ancestorIDs: [UUID]
        if let pID = parentID {
            let parentAccess = try await accessService.validateAccess(fileID: pID, userID: userID, required: .write)
            guard parentAccess.file.isDirectory else {
                throw Abort(.badRequest, reason: "Parent must be a directory.")
            }
            targetOwnerID = parentAccess.ownerID
            ancestorIDs = parentAccess.file.ancestorIDs + [pID]
        } else {
            ancestorIDs = []
        }

        try await FileNaming.ensureUnique(name: filename, parentID: parentID, ownerID: targetOwnerID, on: db)

        // Load initial template content from resources
        let buffer = try type.initialBuffer()

        let fileSize = Int64(buffer.readableBytes)
        let fileID = UUID()

        let metadata = try await quota.withReservation(
            bytes: fileSize, for: .create(fileID: fileID), userID: targetOwnerID
        ) { reservation in
            try await storageService.saveFileBuffer(
                id: fileID, userID: targetOwnerID, buffer: buffer, contentType: type.contentType)

            let metadata = FileMetadata(
                id: fileID,
                filename: filename,
                contentType: type.contentType,
                size: fileSize,
                parentID: parentID,
                ownerID: targetOwnerID,
                lastModified: Date(),
                ancestorIDs: ancestorIDs
            )

            do {
                try await metadata.save(on: db)
            } catch {
                try? await storageService.delete(id: fileID, userID: targetOwnerID)
                throw error
            }

            try await quota.commit(reservation, actualBytes: fileSize)
            await syncLogService.emitToOwnerAndGrantees(
                on: db, ownerID: targetOwnerID, file: metadata, eventType: .create)
            return metadata
        }

        let createdID = try metadata.requireID()
        logger.debug("File entity saved", metadata: ["fileID": .string(createdID.uuidString), "type": .string(type.rawValue)])

        return metadata
    }

    func moveToTrash(fileID: UUID, userID: UUID) async throws {
        let access = try await accessService.validateAccess(fileID: fileID, userID: userID, required: .delete)
        let file = access.file
        let targetOwnerID = access.ownerID
        let now = Date()
        let trashGroupID = UUID()

        file.originalParentID = file.$parent.id

        var descendants: [FileMetadata] = []
        if file.isDirectory {
            descendants = try await fetchAllDescendants(of: fileID, userID: targetOwnerID)
            try await softDeleteDescendants(of: fileID, userID: targetOwnerID, deletedAt: now, trashGroupID: trashGroupID)
        }

        file.deletedAt = now
        file.trashGroupID = trashGroupID
        try await file.save(on: db)

        await syncLogService.emitToOwnerAndGrantees(
            on: db, ownerID: targetOwnerID, file: file, eventType: .trash)
        for descendant in descendants where descendant.id != file.id {
            await syncLogService.emitToOwnerAndGrantees(
                on: db, ownerID: targetOwnerID, file: descendant, eventType: .trash)
        }
    }

    func deleteRecursive(fileID: UUID, userID: UUID) async throws {
        let access = try await accessService.validateAccess(fileID: fileID, userID: userID, required: .delete)
        let targetOwnerID = access.ownerID
        let allItems = try await fetchAllDescendants(of: fileID, userID: targetOwnerID)
        guard !allItems.isEmpty else { throw Abort(.notFound).localized(LocalizationKeys.Error.Http.Generic) }

        let totalSize = allItems.reduce(0) { $0 + $1.size }
        let itemIDs = allItems.compactMap { $0.id }

        // Metadata goes first: if this fails the blobs are still reachable, whereas deleting blobs
        // first would leave rows pointing at missing objects.
        try await db.transaction { transaction in
            if !itemIDs.isEmpty {
                try await FileMetadata.query(on: transaction)
                    .withDeleted()
                    .filter(\.$id ~~ itemIDs)
                    .delete(force: true)
            }
            try await quota.releaseCommitted(
                bytes: totalSize, userID: targetOwnerID, on: transaction)
        }

        for item in allItems where !item.isDirectory {
            guard let itemID = item.id else { continue }
            do {
                try await storageService.delete(id: itemID, userID: targetOwnerID)
            } catch {
                logger.scoped(to: .storage).error(
                    "Failed to delete stored object for a deleted file",
                    metadata: [
                        "file_id": .stringConvertible(itemID),
                        "error": .string("\(error)"),
                    ]
                )
            }
        }

        for item in allItems where item.id != nil {
            await syncLogService.emitToOwnerAndGrantees(
                on: db,
                ownerID: targetOwnerID,
                file: item,
                eventType: .delete,
                contentUpdated: false
            )
        }
    }

    // MARK: - Recursive Subtree Helpers

    private func softDeleteDescendants(
        of parentID: UUID, userID: UUID, deletedAt: Date, trashGroupID: UUID
    ) async throws {
        let sql = try context.requireSQL()

        try await sql.raw(
            """
            WITH RECURSIVE descendants AS (
                SELECT id, parent_id FROM file_metadata
                WHERE parent_id = \(bind: parentID)
                AND owner_id = \(bind: userID)
                AND deleted_at IS NULL
                UNION ALL
                SELECT f.id, f.parent_id FROM file_metadata f
                INNER JOIN descendants d ON f.parent_id = d.id
                WHERE f.owner_id = \(bind: userID)
                AND f.deleted_at IS NULL
            )
            UPDATE file_metadata SET
                deleted_at = \(bind: deletedAt),
                trash_group_id = \(bind: trashGroupID),
                original_parent_id = parent_id
            WHERE id IN (SELECT id FROM descendants)
            """
        ).run()
    }

    private func restoreDescendants(
        of parentID: UUID, userID: UUID, trashGroupID: UUID
    ) async throws {
        let sql = try context.requireSQL()

        try await sql.raw(
            """
            WITH RECURSIVE descendants AS (
                SELECT id FROM file_metadata
                WHERE parent_id = \(bind: parentID)
                AND owner_id = \(bind: userID)
                UNION ALL
                SELECT f.id FROM file_metadata f
                INNER JOIN descendants d ON f.parent_id = d.id
                WHERE f.owner_id = \(bind: userID)
            )
            UPDATE file_metadata SET
                deleted_at = NULL,
                trash_group_id = NULL,
                original_parent_id = NULL
            WHERE id IN (SELECT id FROM descendants)
            AND trash_group_id = \(bind: trashGroupID)
            """
        ).run()
    }

    private func fetchAllDescendants(
        of parentID: UUID, userID: UUID, on connection: (any Database)? = nil
    ) async throws -> [FileMetadata] {
        let sql = try context.requireSQL(connection)
        return try await sql.raw(
            """
            WITH RECURSIVE descendants AS (
                SELECT * FROM file_metadata 
                WHERE id = \(bind: parentID) AND owner_id = \(bind: userID)
                UNION ALL
                SELECT f.* FROM file_metadata f
                INNER JOIN descendants d ON f.parent_id = d.id
                WHERE f.owner_id = \(bind: userID)
            )
            SELECT * FROM descendants
            """
        ).all(decodingFluent: FileMetadata.self)
    }
}

// MARK: - Maintenance
extension FileService {
    /// Permanently deletes files and folders that have been in the trash for longer than the specified number of days (default 30).
    func cleanupExpiredTrash(days: Int = 30) async {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())
            ?? Date().addingTimeInterval(-TimeInterval(days * 86400))

        var deletedCount = 0
        var processedRoots = Set<UUID>()

        // Deleting a folder takes its subtree with it, so each batch is re-queried rather than
        // paged through a snapshot that the previous batch may have invalidated.
        while true {
            let expiredItems: [FileMetadata]
            do {
                expiredItems = try await FileMetadata.query(on: db)
                    .withDeleted()
                    .filter(\.$deletedAt != nil)
                    .filter(\.$deletedAt <= cutoffDate)
                    .sort(\.$deletedAt, .ascending)
                    .limit(Self.trashCleanupBatchSize)
                    .all()
            } catch {
                logger.scoped(to: .storage).error(
                    "Failed to query expired trash items",
                    metadata: ["error": .string("\(error)")]
                )
                return
            }

            let pending = expiredItems.filter { $0.id.map { !processedRoots.contains($0) } ?? false }
            guard !pending.isEmpty else { break }

            for item in pending {
                guard let itemID = item.id else { continue }
                processedRoots.insert(itemID)
                let ownerID = item.$owner.id

                do {
                    try await deleteRecursive(fileID: itemID, userID: ownerID)
                    deletedCount += 1
                } catch let error as any AbortError where error.status == .notFound {
                    // Already removed as part of an ancestor's subtree earlier in this sweep.
                    continue
                } catch {
                    logger.error(
                        "Failed to clean up expired trash item",
                        metadata: [
                            "fileID": .string(itemID.uuidString),
                            "error": .string(String(describing: error)),
                        ]
                    )
                }
            }
        }

        guard deletedCount > 0 else { return }
        logger.scoped(to: .storage).info(
            "Completed trash cleanup",
            metadata: [
                "deleted_count": .stringConvertible(deletedCount),
                "cutoff_date": .string(ISO8601DateFormatter().string(from: cutoffDate)),
            ]
        )
    }


    // MARK: - User Data Cleanup

    func deleteAllUserData(userID: UUID) async throws {
        await uploads.abortAllSessions(userID: userID)

        let userFiles = try await FileMetadata.query(on: db)
            .filter(\.$owner.$id == userID)
            .all()

        let userFileIDs = userFiles.compactMap { $0.id }
        if !userFileIDs.isEmpty {
            // The account's own sync log is deleted with it, but people it shared files with are
            // still listening and would otherwise keep showing files that no longer exist.
            for file in userFiles where file.isShared {
                await syncLogService.emitToGrantees(
                    on: db, ownerID: userID, file: file, eventType: .delete, contentUpdated: false)
            }

            try await FileEmbedding.query(on: db)
                .filter(\.$file.$id ~~ userFileIDs)
                .delete()

            try await ShareLink.query(on: db)
                .filter(\.$file.$id ~~ userFileIDs)
                .delete()

            try await FileMetadata.query(on: db)
                .filter(\.$owner.$id == userID)
                .set(\.$parent.$id, to: nil)
                .update()

            try await FileMetadata.query(on: db)
                .filter(\.$owner.$id == userID)
                .delete(force: true)
        }

        try await storageService.deleteUserData(userID: userID)
    }
}
