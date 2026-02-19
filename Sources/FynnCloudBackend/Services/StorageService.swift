import Fluent
import FluentSQL
import SQLKit
import Vapor

struct StorageService: Sendable {
    let db: any Database
    let logger: Logger
    let provider: any FileStorageProvider
    let eventLoop: any EventLoop

    // MARK: - Sync Engine Helper

    /// Records a change in the user's sync timeline.
    private func recordSyncChange(
        fileID: UUID,
        userID: UUID,
        type: SyncLog.EventType,
        contentUpdated: Bool = false,
        on transaction: any Database
    ) async throws {
        // Disabled for now as it's buggy
        return
    }

    // MARK: - Retrieval Logic

    /// The unified engine for all file listing views (Root, Subfolders, Favorites, etc.)
    func list(filter: FileFilter, userID: UUID) async throws -> FileIndexDTO {
        let query = FileMetadata.query(on: db).filter(\.$owner.$id == userID)
        var parentID: UUID? = nil
        var breadcrumbs: [Breadcrumb] = []

        switch filter {

        case .all:
            query.filter(\.$deletedAt == nil)
            query.sort(\.$updatedAt, .descending)
            breadcrumbs = [Breadcrumb(name: "All", id: nil)]

        case .folder(let id):
            parentID = id
            query.filter(\.$parent.$id == id)
            query.filter(\.$deletedAt == nil)
            query.sort(\.$isDirectory, .descending).sort(\.$filename, .ascending)
            breadcrumbs = try await getBreadcrumbs(for: id, userID: userID)

        case .favorites:
            query.filter(\.$isFavorite == true).filter(\.$deletedAt == nil)
            query.sort(\.$updatedAt, .descending)
            breadcrumbs = [Breadcrumb(name: "Favorites", id: nil)]

        case .recent:
            query.filter(\.$deletedAt == nil).filter(\.$isDirectory == false)
            query.sort(\.$updatedAt, .descending).range(0..<50)
            breadcrumbs = [Breadcrumb(name: "Recent", id: nil)]

        case .shared:
            query.filter(\.$isShared == true).filter(\.$deletedAt == nil)
            query.sort(\.$updatedAt, .descending)
            breadcrumbs = [Breadcrumb(name: "Shared", id: nil)]

        case .trash(let folderID):
            if let folderID = folderID {
                // Browsing into a trashed folder — show children that were
                // trashed as part of the same action (matching deleted_at).
                // Independently trashed children live at the trash root instead.
                guard
                    let folder = try await FileMetadata.query(on: db)
                        .withDeleted()
                        .filter(\.$id == folderID)
                        .filter(\.$owner.$id == userID)
                        .first(),
                    let folderDeletedAt = folder.deletedAt
                else {
                    throw Abort(.notFound).localized("error.generic")
                }

                parentID = folderID
                query.withDeleted()
                    .filter(\.$parent.$id == folderID)
                    .filter(\.$deletedAt == folderDeletedAt)
                query.sort(\.$isDirectory, .descending).sort(\.$filename, .ascending)
                breadcrumbs = try await getTrashBreadcrumbs(for: folderID, userID: userID)
            } else {
                // Trash root — only show top-level trashed items
                // (items whose parent is nil or whose parent is NOT deleted)
                let trashRoots = try await fetchTrashRoots(userID: userID)
                breadcrumbs = [Breadcrumb(name: "Trash", id: nil)]
                logger.info("Queried trash roots for user \(userID)")
                return FileIndexDTO(
                    files: trashRoots,
                    parentID: nil,
                    breadcrumbs: breadcrumbs
                )
            }
        }

        let files = try await query.all()
        logger.info(
            "Queried files for user \(userID) and parent \((parentID?.uuidString) ?? "Root")"
        )
        return FileIndexDTO(
            files: files,
            parentID: parentID,
            breadcrumbs: breadcrumbs
        )
    }

    func getMetadata(for id: UUID, userID: UUID) async throws -> FileMetadata {
        let metadata = try await validateOwnership(fileID: id, userID: userID)
        return metadata
    }

    func getFileResponse(for id: UUID, userID: UUID) async throws -> Response {
        let metadata = try await validateOwnership(fileID: id, userID: userID)
        guard !metadata.isDirectory else {
            throw Abort(.badRequest, reason: "Cannot download a directory.").localized(
                "error.generic")
        }
        return try await provider.getResponse(for: id, userID: userID, on: eventLoop)
    }

    // MARK: - Actions

    func upload(
        filename: String,
        stream: Request.Body,
        claimedSize: Int64,
        contentType: String,
        parentID: UUID?,
        userID: UUID,
        lastModified: Int64? = nil
    ) async throws -> FileMetadata {
        let fileID = UUID()
        try await ensureUniqueName(name: filename, parentID: parentID, userID: userID)

        let maxAllowedSize = claimedSize + max(claimedSize / 20, 1024 * 1024)

        try await reserveQuota(amount: claimedSize, userID: userID)

        let actualSize: Int64
        do {
            actualSize = try await provider.save(
                stream: stream,
                id: fileID,
                userID: userID,
                maxSize: maxAllowedSize,
                on: eventLoop
            )
        } catch {
            logger.error("Upload failed for user \(userID). Reclaiming \(claimedSize) bytes.")
            try? await decrementQuota(amount: claimedSize, userID: userID)
            throw error
        }

        let tolerance: Int64 = 1024 * 1024
        if actualSize > claimedSize + tolerance {
            logger.error(
                "Size mismatch: claimed \(claimedSize) bytes, actual \(actualSize) bytes"
            )
            try? await provider.delete(id: fileID, userID: userID)
            try? await decrementQuota(amount: claimedSize, userID: userID)
            throw Abort(
                .badRequest,
                reason: """
                    Upload size mismatch. Claimed \(claimedSize) bytes, \
                    but received \(actualSize) bytes.
                    """
            )
        }

        let sizeDelta = claimedSize - actualSize
        if sizeDelta > tolerance {
            try? await decrementQuota(amount: sizeDelta, userID: userID)
            logger.info(
                "Reclaimed \(sizeDelta) bytes of unused quota for user \(userID)"
            )
        }

        let metadata = FileMetadata(
            id: fileID,
            filename: filename,
            contentType: contentType,
            size: actualSize,
            parentID: parentID,
            ownerID: userID,
            lastModified: lastModified != nil
                ? Date(timeIntervalSince1970: TimeInterval(lastModified!) / 1000) : nil
        )

        do {
            try await metadata.save(on: db)
            try await recordSyncChange(
                fileID: fileID, userID: userID, type: .upsert, contentUpdated: true, on: db)
            return metadata
        } catch {
            try? await provider.delete(id: fileID, userID: userID)
            try? await decrementQuota(amount: actualSize, userID: userID)
            throw error
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
        let existingFile = try await validateOwnership(fileID: fileID, userID: userID)

        guard !existingFile.isDirectory else {
            throw Abort(.badRequest, reason: "Directories cannot be updated with file content.")
                .localized("upload.error.unknown")
        }

        let estimatedDelta = claimedSize - existingFile.size
        let maxAllowedSize = claimedSize + max(claimedSize / 20, 1024 * 1024)

        if estimatedDelta > 0 {
            try await reserveQuota(amount: estimatedDelta, userID: userID)
        }

        let actualSize: Int64
        do {
            actualSize = try await provider.save(
                stream: stream,
                id: fileID,
                userID: userID,
                maxSize: maxAllowedSize,
                on: eventLoop
            )
        } catch {
            if estimatedDelta > 0 {
                try? await decrementQuota(amount: estimatedDelta, userID: userID)
            }
            throw error
        }

        let actualDelta = actualSize - existingFile.size

        if actualDelta > estimatedDelta {
            let additionalNeeded = actualDelta - estimatedDelta
            try await reserveQuota(amount: additionalNeeded, userID: userID)
        } else if actualDelta < estimatedDelta {
            let toReturn = estimatedDelta - actualDelta
            try? await decrementQuota(amount: toReturn, userID: userID)
        }

        existingFile.size = actualSize
        existingFile.contentType = contentType
        existingFile.updatedAt = Date()
        if let lastModified = lastModified {
            existingFile.lastModified = Date(
                timeIntervalSince1970: TimeInterval(lastModified) / 1000)
        }

        do {
            try await existingFile.save(on: db)
            try await recordSyncChange(
                fileID: fileID, userID: userID, type: .upsert, contentUpdated: true, on: db)
            return existingFile
        } catch {
            try? await decrementQuota(amount: actualDelta, userID: userID)
            throw error
        }
    }

    func rename(fileID: UUID, newName: String, userID: UUID) async throws -> FileMetadata {
        let file = try await validateOwnership(fileID: fileID, userID: userID)

        if file.filename == newName { return file }

        try await ensureUniqueName(name: newName, parentID: file.$parent.id, userID: userID)

        file.filename = newName
        try await file.save(on: db)

        try await recordSyncChange(
            fileID: fileID, userID: userID, type: .upsert, contentUpdated: false, on: db)
        return file
    }

    func move(fileID: UUID, newParentID: UUID?, userID: UUID) async throws -> FileMetadata {
        let file = try await validateOwnership(fileID: fileID, userID: userID)

        if file.$parent.id == newParentID { return file }

        if let pID = newParentID {
            let parent = try await validateOwnership(fileID: pID, userID: userID)
            guard parent.isDirectory else {
                throw Abort(.badRequest, reason: "Cannot move file into a non-directory item.")
                    .localized("files.alerts.moveFailed")
            }
        }

        try await ensureUniqueName(name: file.filename, parentID: newParentID, userID: userID)

        file.$parent.id = newParentID
        try await file.save(on: db)

        try await recordSyncChange(
            fileID: fileID, userID: userID, type: .upsert, contentUpdated: false, on: db)
        return file
    }

    func restore(fileID: UUID, userID: UUID) async throws -> FileMetadata {

        let file = try await FileMetadata.query(on: db)
            .withDeleted()
            .filter(\.$id == fileID)
            .filter(\.$owner.$id == userID)
            .first()

        guard let file = file else {
            throw Abort(.notFound).localized("files.alerts.restoreFailed")
        }

        guard let deletedAt = file.deletedAt else {
            throw Abort(.badRequest, reason: "File is not in trash.").localized(
                "files.alerts.restoreFailed")
        }

        // Check if the parent folder exists (and is active/not in trash)
        if let parentID = file.$parent.id {
            let parent = try await FileMetadata.query(on: db)
                .filter(\.$id == parentID)
                .first()
            // If parent doesn't exist or is itself deleted, move to root
            if parent == nil {
                file.$parent.id = nil
            }
        }

        // Check for name conflict and rename if necessary
        var currentName = file.filename

        while try await FileMetadata.query(on: db)
            .filter(\.$parent.$id == file.$parent.id)
            .filter(\.$filename == currentName)
            .filter(\.$id != file.requireID())
            .first() != nil
        {

            if !file.isDirectory {
                let parts = currentName.split(
                    separator: ".", omittingEmptySubsequences: false)
                if parts.count > 1 {
                    let name = parts.dropLast().joined(separator: ".")
                    let ext = parts.last!
                    currentName = "\(name) (restored).\(ext)"
                } else {
                    currentName = "\(currentName) (restored)"
                }
            } else {
                currentName = "\(currentName) (restored)"
            }
        }

        file.filename = currentName

        // Restore the file itself
        try await file.restore(on: db)
        try await file.save(on: db)

        // Recursively restore descendants that were trashed at the same time.
        // Items that were independently trashed before this folder (different deletedAt)
        // will remain in the trash.
        if file.isDirectory {
            try await restoreDescendants(
                of: try file.requireID(), userID: userID, deletedAt: deletedAt)
        }

        logger.info(
            "File restored from trash",
            metadata: [
                "fileID": .string(fileID.uuidString),
                "userID": .string(userID.uuidString),
                "action": "restore_file",
                "newFilename": .string(file.filename),
            ])

        try await recordSyncChange(
            fileID: fileID, userID: userID, type: .upsert, contentUpdated: false, on: db)
        return file
    }

    func createDirectory(name: String, parentID: UUID?, userID: UUID) async throws -> FileMetadata {
        if let pID = parentID {
            try await validateOwnership(fileID: pID, userID: userID)
        }

        try await ensureUniqueName(name: name, parentID: parentID, userID: userID)

        let dir = FileMetadata(
            filename: name,
            contentType: "directory",
            size: 0,
            isDirectory: true,
            parentID: parentID,
            ownerID: userID
        )

        try await db.transaction { tx in
            try await dir.save(on: tx)

            let dirID = try dir.requireID()

            logger.info("Directory created with ID: \(dirID)")

            try await recordSyncChange(
                fileID: dirID,
                userID: userID,
                type: .upsert,
                contentUpdated: false,
                on: tx
            )
        }

        return dir
    }

    /// Soft delete a file or directory, recursively marking all descendants as deleted.
    func moveToTrash(fileID: UUID, userID: UUID) async throws {
        let file = try await validateOwnership(fileID: fileID, userID: userID)
        let now = Date()

        // If it's a directory, recursively soft-delete all non-deleted descendants first
        // so they share the same deletedAt timestamp (used for selective restore).
        if file.isDirectory {
            try await softDeleteDescendants(of: fileID, userID: userID, deletedAt: now)
        }

        // Soft-delete the root item itself via Fluent.
        // We set deletedAt explicitly so it matches the descendants' timestamp.
        file.deletedAt = now
        try await file.save(on: db)

        try await recordSyncChange(
            fileID: fileID, userID: userID, type: .delete, contentUpdated: false, on: db)
    }

    // Hard delete "Permanent delete"
    func deleteRecursive(fileID: UUID, userID: UUID) async throws {
        let allItems = try await fetchAllDescendants(of: fileID, userID: userID)
        guard !allItems.isEmpty else { throw Abort(.notFound).localized("error.generic") }

        let totalSize = allItems.reduce(0) { $0 + $1.size }

        for item in allItems where !item.isDirectory {
            try await provider.delete(id: try item.requireID(), userID: userID)
        }

        try await db.transaction { transaction in
            for item in allItems.reversed() {
                try await item.delete(force: true, on: transaction)
                try await recordSyncChange(
                    fileID: item.requireID(),
                    userID: userID,
                    type: .delete,
                    contentUpdated: true,
                    on: transaction)
            }
            try await decrementQuota(amount: totalSize, userID: userID, on: transaction)
        }
    }

    // MARK: - Helpers

    @discardableResult
    private func validateOwnership(fileID: UUID, userID: UUID, on specificDB: (any Database)? = nil)
        async throws -> FileMetadata
    {
        let activeDB = specificDB ?? self.db
        guard
            let item = try await FileMetadata.query(on: activeDB)
                .filter(\.$id == fileID)
                .filter(\.$owner.$id == userID)
                .first()
        else {
            throw Abort(.notFound).localized("error.generic")
        }
        return item
    }

    private func reserveQuota(amount: Int64, userID: UUID) async throws {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError).localized("error.generic")
        }

        let user = try await User.query(on: db)
            .filter(\.$id == userID)
            .with(\.$tier)
            .first()

        guard let user = user else {
            throw Abort(.notFound).localized("upload.error.quotaExceeded")
        }

        let userTierLimit = user.tier?.limitBytes ?? 0

        var groupMaxLimit: Int64 = 0

        let groupLimitRow = try await sql.raw(
            """
                SELECT MAX(t.limit_bytes) as max_limit
                FROM user_groups ug 
                JOIN groups g ON ug.group_id = g.id 
                JOIN storage_tiers t ON g.tier_id = t.id 
                WHERE ug.user_id = \(bind: userID)
            """
        ).first()

        if let row = groupLimitRow {
            groupMaxLimit = try row.decode(column: "max_limit", as: Int64?.self) ?? 0
        }

        let effectiveLimit = max(userTierLimit, groupMaxLimit)

        let result = try await sql.raw(
            """
                UPDATE users 
                SET current_storage_usage = current_storage_usage + \(bind: amount)
                WHERE id = \(bind: userID) 
                AND (current_storage_usage + \(bind: amount)) <= \(bind: effectiveLimit)
                RETURNING id;
            """
        ).first()

        if result == nil {
            throw Abort(.payloadTooLarge, reason: "Quota exceeded or user not found.").localized(
                "upload.error.quotaExceeded")
        }
    }

    private func updateQuotaAtomic(
        amount: Int64,
        userID: UUID,
        isIncrement: Bool,
        on connection: (any Database)? = nil
    ) async throws {
        let activeDB = connection ?? self.db
        guard let sql = activeDB as? any SQLDatabase else { return }

        let sign = isIncrement ? "+" : "-"

        try await sql.raw(
            """
            UPDATE users 
            SET current_storage_usage = current_storage_usage \(unsafeRaw: sign) \(bind: amount) 
            WHERE id = \(bind: userID)
            """
        ).run()
    }

    private func decrementQuota(
        amount: Int64,
        userID: UUID,
        on connection: (any Database)? = nil
    ) async throws {
        try await updateQuotaAtomic(
            amount: amount, userID: userID, isIncrement: false, on: connection)
    }

    private func getBreadcrumbs(for parentID: UUID?, userID: UUID) async throws -> [Breadcrumb] {
        var crumbs: [Breadcrumb] = [
            Breadcrumb(name: "All Files", id: nil)
        ]
        var currentID = parentID
        var pathCrumbs: [Breadcrumb] = []

        while let id = currentID {
            let dir = try await validateOwnership(fileID: id, userID: userID)
            pathCrumbs.insert(Breadcrumb(name: dir.filename, id: dir.id), at: 0)
            currentID = dir.$parent.id
        }

        crumbs.append(contentsOf: pathCrumbs)
        return crumbs
    }

    /// Builds breadcrumbs for navigating within the trash view.
    /// Walks up the ancestor chain until it finds a non-deleted parent (the trash boundary).
    private func getTrashBreadcrumbs(for folderID: UUID, userID: UUID) async throws -> [Breadcrumb]
    {
        var crumbs: [Breadcrumb] = [Breadcrumb(name: "Trash", id: nil)]
        var currentID: UUID? = folderID
        var pathCrumbs: [Breadcrumb] = []

        while let id = currentID {
            guard
                let dir = try await FileMetadata.query(on: db)
                    .withDeleted()
                    .filter(\.$id == id)
                    .filter(\.$owner.$id == userID)
                    .first()
            else { break }

            pathCrumbs.insert(Breadcrumb(name: dir.filename, id: dir.id), at: 0)

            // Stop climbing once we reach an item whose parent is not in trash
            if let parentID = dir.$parent.id {
                let parent = try await FileMetadata.query(on: db)
                    .withDeleted()
                    .filter(\.$id == parentID)
                    .filter(\.$owner.$id == userID)
                    .first()
                if parent == nil || parent?.deletedAt == nil {
                    break
                }
                currentID = parentID
            } else {
                break
            }
        }

        crumbs.append(contentsOf: pathCrumbs)
        return crumbs
    }

    /// Fetches top-level trash items. An item appears at the trash root if:
    /// - It has no parent, OR
    /// - Its parent is not deleted, OR
    /// - Its deleted_at differs from its parent's (independently trashed)
    private func fetchTrashRoots(userID: UUID) async throws -> [FileMetadata] {
        guard let sql = db as? any SQLDatabase else { return [] }
        return try await sql.raw(
            """
            SELECT f.* FROM file_metadata f
            LEFT JOIN file_metadata p ON f.parent_id = p.id
            WHERE f.owner_id = \(bind: userID)
            AND f.deleted_at IS NOT NULL
            AND (
                f.parent_id IS NULL
                OR p.deleted_at IS NULL
                OR f.deleted_at != p.deleted_at
            )
            ORDER BY f.deleted_at DESC
            """
        ).all(decodingFluent: FileMetadata.self)
    }

    /// Recursively soft-deletes all non-deleted descendants of a directory.
    /// Only touches items that are not already in trash (deletedAt IS NULL),
    /// preserving the original deletedAt of independently trashed items.
    private func softDeleteDescendants(
        of parentID: UUID, userID: UUID, deletedAt: Date
    ) async throws {
        guard let sql = db as? any SQLDatabase else { return }

        try await sql.raw(
            """
            WITH RECURSIVE descendants AS (
                SELECT id FROM file_metadata
                WHERE parent_id = \(bind: parentID)
                AND owner_id = \(bind: userID)
                AND deleted_at IS NULL
                UNION ALL
                SELECT f.id FROM file_metadata f
                INNER JOIN descendants d ON f.parent_id = d.id
                WHERE f.owner_id = \(bind: userID)
                AND f.deleted_at IS NULL
            )
            UPDATE file_metadata SET deleted_at = \(bind: deletedAt)
            WHERE id IN (SELECT id FROM descendants)
            """
        ).run()
    }

    /// Recursively restores descendants that were trashed as part of the same action
    /// (matching deleted_at timestamp). Independently trashed items remain in trash.
    private func restoreDescendants(
        of parentID: UUID, userID: UUID, deletedAt: Date
    ) async throws {
        guard let sql = db as? any SQLDatabase else { return }

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
            UPDATE file_metadata SET deleted_at = NULL
            WHERE id IN (SELECT id FROM descendants)
            AND deleted_at = \(bind: deletedAt)
            """
        ).run()
    }

    private func fetchAllDescendants(of parentID: UUID, userID: UUID) async throws -> [FileMetadata]
    {
        guard let sql = db as? any SQLDatabase else { return [] }
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

    private func ensureUniqueName(name: String, parentID: UUID?, userID: UUID) async throws {
        let existing = try await FileMetadata.query(on: db)
            .filter(\.$owner.$id == userID)
            .filter(\.$parent.$id == parentID)
            .filter(\.$filename == name)
            .first()

        if existing != nil {
            throw Abort(
                .conflict,
                reason: "A file or folder with the name '\(name)' already exists in this directory."
            ).localized("upload.error.nameConflict")
        }
    }
}

extension StorageService {

    // MARK: - Multipart Upload Operations

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
        let userID: UUID
    }

    func initiateMultipartUpload(
        filename: String,
        contentType: String,
        totalSize: Int64,
        parentID: UUID?,
        lastModified: Int64?,
        userID: UUID,
        request: Request
    ) async throws -> InitiatedUploadSession {

        if let parentID = parentID {
            try await validateOwnership(fileID: parentID, userID: userID)
        }
        try await ensureUniqueName(name: filename, parentID: parentID, userID: userID)
        try await reserveQuota(amount: totalSize, userID: userID)

        let fileID = UUID()
        let sessionID = UUID()
        let maxChunkSize = request.application.config.maxChunkSize

        let uploadID = try await provider.initiateMultipartUpload(id: fileID, userID: userID)

        let session = MultipartUploadSession(
            id: sessionID,
            fileID: fileID,
            uploadID: uploadID,
            userID: userID,
            filename: filename,
            totalSize: totalSize,
            expiresAt: Date().addingTimeInterval(86400)
        )

        try await session.save(on: db)

        logger.info(
            "Multipart upload initiated",
            metadata: [
                "sessionID": .string(sessionID.uuidString),
                "fileID": .string(fileID.uuidString),
                "uploadID": .string(uploadID),
                "filename": .string(filename),
            ]
        )

        return InitiatedUploadSession(
            sessionID: sessionID,
            fileID: fileID,
            uploadID: uploadID,
            filename: filename,
            contentType: contentType,
            totalSize: totalSize,
            maxChunkSize: Int64(maxChunkSize.value),
            parentID: parentID,
            lastModified: lastModified,
            userID: userID
        )
    }

    func uploadPartWithToken(
        fileID: UUID,
        uploadID: String,
        partNumber: Int,
        userID: UUID,
        stream: Request.Body,
        size: Int64
    ) async throws -> CompletedPart {

        guard partNumber > 0 && partNumber <= 10000 else {
            throw Abort(.badRequest, reason: "Part number must be between 1 and 10000")
        }

        let completedPart = try await provider.uploadPart(
            id: fileID,
            userID: userID,
            uploadID: uploadID,
            partNumber: partNumber,
            stream: stream,
            maxSize: size,
            on: eventLoop
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

    func completeMultipartUploadWithToken(
        sessionID: UUID,
        fileID: UUID,
        uploadID: String,
        userID: UUID,
        filename: String,
        contentType: String,
        totalSize: Int64,
        parentID: UUID?,
        lastModified: Int64?,
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

        guard !parts.isEmpty else {
            throw Abort(.badRequest, reason: "No parts provided")
        }

        let sortedParts = parts.sorted { $0.partNumber < $1.partNumber }
        let expectedParts = Set(1...sortedParts.count)
        let actualParts = Set(sortedParts.map { $0.partNumber })

        guard expectedParts == actualParts else {
            throw Abort(.badRequest, reason: "Missing or duplicate parts - upload incomplete")
        }

        try await provider.completeMultipartUpload(
            id: fileID,
            userID: userID,
            uploadID: uploadID,
            parts: sortedParts
        )

        let metadata = FileMetadata(
            id: fileID,
            filename: filename,
            contentType: contentType,
            size: totalSize,
            parentID: parentID,
            ownerID: userID,
            lastModified: lastModified != nil
                ? Date(timeIntervalSince1970: TimeInterval(lastModified!) / 1000) : nil
        )

        try await metadata.save(on: db)

        try await recordSyncChange(
            fileID: fileID,
            userID: userID,
            type: .upsert,
            contentUpdated: true,
            on: db
        )

        if let session = try await MultipartUploadSession.find(sessionID, on: db) {
            try await session.delete(on: db)
        }

        logger.info(
            "Multipart upload completed",
            metadata: [
                "sessionID": .string(sessionID.uuidString),
                "fileID": .string(fileID.uuidString),
                "filename": .string(filename),
                "size": .string("\(totalSize)"),
            ]
        )

        return metadata
    }

    func abortMultipartUpload(
        fileID: UUID,
        uploadID: String,
        sessionID: UUID,
        totalSize: Int64,
        userID: UUID
    ) async throws {
        try? await decrementQuota(amount: totalSize, userID: userID)

        try? await provider.abortMultipartUpload(
            id: fileID,
            userID: userID,
            uploadID: uploadID,
        )

        if let session = try await MultipartUploadSession.find(sessionID, on: db) {
            try await session.delete(on: db)
        }

        logger.info(
            "Multipart upload aborted",
            metadata: [
                "sessionID": .string(sessionID.uuidString),
                "fileID": .string(fileID.uuidString),
                "uploadID": .string(uploadID),
            ]
        )
    }
}

// MARK: - Filter Enum
extension StorageService {
    enum FileFilter {
        case folder(id: UUID?)
        case all
        case favorites
        case recent
        case trash(parentID: UUID?)
        case shared
    }
}
