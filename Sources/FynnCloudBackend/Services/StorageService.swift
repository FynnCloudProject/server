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
    /// Uses 'FOR UPDATE' to lock the sequence and prevent collisions.
    private func recordSyncChange(
        fileID: UUID,
        userID: UUID,
        type: SyncLog.EventType,
        contentUpdated: Bool = false,
        on transaction: any Database
    ) async throws {
        let maxRetries = 3
        var lastError: (any Error)?

        for attempt in 1...maxRetries {
            // Fetch the current highest sequence for this user
            let lastEntry = try await SyncLog.query(on: transaction)
                .filter(\.$user.$id == userID)
                .sort(\.$seq, .descending)
                .first()

            let nextSeq = (lastEntry?.seq ?? 0) + 1

            let log = SyncLog(
                userID: userID,
                fileID: fileID,
                seq: nextSeq,
                eventType: type,
                contentUpdated: contentUpdated
            )

            do {
                // Attempt to save.
                // If another thread wrote 'nextSeq' between our 'read' and 'write',
                // the Unique Constraint in the DB will throw an error here.
                try await log.save(on: transaction)
                return
            } catch {
                lastError = error
                // If we hit a unique constraint violation, we loop and try again.
                logger.warning(
                    "Sync sequence collision for user \(userID) at seq \(nextSeq). Retry attempt \(attempt)."
                )
                continue
            }
        }

        // If we exhausted retries, throw the last error encountered
        logger.error("Failed to record sync change after \(maxRetries) attempts.")
        throw lastError ?? Abort(.internalServerError)
    }

    // MARK: - Retrieval Logic

    /// The unified engine for all file listing views (Root, Subfolders, Favorites, etc.)
    func list(filter: FileFilter, userID: UUID) async throws -> FileIndexDTO {
        let query = FileMetadata.query(on: db).filter(\.$owner.$id == userID)
        var parentID: UUID? = nil
        var breadcrumbs: [Breadcrumb] = []

        switch filter {

        // Gets all files as flat list
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

        case .trash:
            query.withDeleted().filter(\.$deletedAt != nil)
            query.sort(\.$deletedAt, .descending)
            breadcrumbs = [Breadcrumb(name: "Trash", id: nil)]
        }

        let files = try await query.all()
        // Log what was queried so user id or parent id can be used to identify the query
        logger.info(
            "Queried files for user \(userID) and parent \((parentID?.uuidString) ?? "Root")"
        )
        return FileIndexDTO(
            files: files,
            parentID: parentID,
            breadcrumbs: breadcrumbs
        )
    }

    // Basically an alias for validateOwnership just make it clearer it returns metadata
    func getMetadata(for id: UUID, userID: UUID) async throws -> FileMetadata {
        let metadata = try await validateOwnership(fileID: id, userID: userID)
        return metadata
    }

    func getFileResponse(for id: UUID, userID: UUID) async throws -> Response {
        let metadata = try await validateOwnership(fileID: id, userID: userID)
        guard !metadata.isDirectory else {
            throw Abort(.badRequest, reason: "Cannot download a directory.")
        }
        return try await provider.getResponse(for: id, on: eventLoop)
    }

    // MARK: - Actions

    func upload(
        filename: String,
        stream: Request.Body,
        size: Int64,
        contentType: String,
        parentID: UUID?,
        userID: UUID,
        lastModified: Int64? = nil
    ) async throws -> FileMetadata {
        let fileID = UUID()
        try await ensureUniqueName(name: filename, parentID: parentID, userID: userID)

        // Validate and Reserve Quota
        try await reserveQuota(amount: size, userID: userID)

        // Physical Write
        do {
            try await provider.save(stream: stream, id: fileID, size: size, on: eventLoop)
        } catch {
            // FAILURE RECOVERY: If the disk write fails, decrement quota
            logger.error("Upload failed for user \(userID). Reclaiming \(size) bytes.")
            try? await decrementQuota(amount: size, userID: userID)
            throw error
        }

        // COMMIT: Save Metadata
        let metadata = FileMetadata(
            id: fileID,
            filename: filename,
            contentType: contentType,
            size: size,
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
            // If metadata fails to save, we have a "Ghost File" on disk.
            // Clean up disk and quota.
            try? await provider.delete(id: fileID)
            try? await decrementQuota(amount: size, userID: userID)
            throw error
        }
    }

    func update(
        fileID: UUID,
        stream: Request.Body,
        newSize: Int64,
        contentType: String,
        userID: UUID,
        lastModified: Int64? = nil
    ) async throws -> FileMetadata {
        // Validate ownership and existence
        let existingFile = try await validateOwnership(fileID: fileID, userID: userID)

        guard !existingFile.isDirectory else {
            throw Abort(.badRequest, reason: "Directories cannot be updated with file content.")
        }

        let sizeDelta = newSize - existingFile.size

        // Adjust Quota (only if the file is larger)
        // If smaller, we reclaim space after the successful write.
        if sizeDelta > 0 {
            try await reserveQuota(amount: sizeDelta, userID: userID)
        }

        // Physical Write (Overwrite)
        do {
            // Use same provider save method to overwrite the file
            // TODO: Maybe we should add a different method to the provider for overwriting "updating" files
            try await provider.save(stream: stream, id: fileID, size: newSize, on: eventLoop)
        } catch {
            // Rollback quota if we reserved it and failed
            if sizeDelta > 0 {
                try? await decrementQuota(amount: sizeDelta, userID: userID)
            }
            throw error
        }

        // Update Metadata
        existingFile.size = newSize
        existingFile.contentType = contentType
        existingFile.updatedAt = Date()
        if let lastModified = lastModified {
            existingFile.lastModified = Date(
                timeIntervalSince1970: TimeInterval(lastModified) / 1000)
        }

        do {
            try await existingFile.save(on: db)

            // Reclaim the space now if the file is smaller
            if sizeDelta < 0 {
                try await decrementQuota(amount: abs(sizeDelta), userID: userID)
            }

            try await recordSyncChange(
                fileID: fileID, userID: userID, type: .upsert, contentUpdated: true, on: db)
            return existingFile
        } catch {
            // This is a rare edge case: Physical file updated but DB failed.
            // We leave the quota as is to prevent under-counting, but log the desync.
            logger.critical("Metadata update failed for file \(fileID) after physical write.")
            throw error
        }
    }

    func rename(fileID: UUID, newName: String, userID: UUID) async throws -> FileMetadata {
        // Fetch the file and validate ownership
        let file = try await validateOwnership(fileID: fileID, userID: userID)

        // If name hasn't changed, just return it
        if file.filename == newName { return file }

        // Ensure the new name isn't taken in the current folder
        try await ensureUniqueName(name: newName, parentID: file.$parent.id, userID: userID)

        // Update and save
        file.filename = newName
        try await file.save(on: db)

        try await recordSyncChange(
            fileID: fileID, userID: userID, type: .upsert, contentUpdated: false, on: db)
        return file
    }

    func move(fileID: UUID, newParentID: UUID?, userID: UUID) async throws -> FileMetadata {
        // Fetch the file and validate ownership
        let file = try await validateOwnership(fileID: fileID, userID: userID)

        // If moving to the same folder, do nothing
        if file.$parent.id == newParentID { return file }

        // Ensure the new parent is valid and owned by the user
        if let pID = newParentID {
            let parent = try await validateOwnership(fileID: pID, userID: userID)
            guard parent.isDirectory else {
                throw Abort(.badRequest, reason: "Cannot move file into a non-directory item.")
            }
        }

        // Ensure the new name isn't taken in the target folder
        try await ensureUniqueName(name: file.filename, parentID: newParentID, userID: userID)

        // Update and save
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
            throw Abort(.notFound)
        }

        // Check if the parent folder exists (and is active/not in trash)
        if let parentID = file.$parent.id {
            let parentExists = try await FileMetadata.find(parentID, on: db) != nil
            if !parentExists {
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

        try await file.restore(on: db)
        try await file.save(on: db)

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

        // Wrap in a transaction to be safe and ensure the ID is available
        try await db.transaction { tx in
            try await dir.save(on: tx)

            // Use requireID() to ensure we have the UUID generated by the DB save
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

    // Soft delete
    func moveToTrash(fileID: UUID, userID: UUID) async throws {
        let file = try await validateOwnership(fileID: fileID, userID: userID)
        try await file.delete(on: db)

        try await recordSyncChange(
            fileID: fileID, userID: userID, type: .delete, contentUpdated: false, on: db)
    }

    // Hard delete "Permanent delete"
    func deleteRecursive(fileID: UUID, userID: UUID) async throws {
        let allItems = try await fetchAllDescendants(of: fileID, userID: userID)
        guard !allItems.isEmpty else { throw Abort(.notFound) }

        let totalSize = allItems.reduce(0) { $0 + $1.size }

        for item in allItems where !item.isDirectory {
            try await provider.delete(id: try item.requireID())
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
            throw Abort(.notFound)
        }
        return item
    }

    private func reserveQuota(amount: Int64, userID: UUID) async throws {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError)
        }

        // We use a subquery to check the limit against the current usage + the new file size.
        // This prevents race conditions without needing a manual 'lock' on the row.
        let result = try await sql.raw(
            """
                UPDATE users 
                SET current_storage_usage = current_storage_usage + \(bind: amount)
                WHERE id = \(bind: userID) 
                AND (
                    SELECT (u.current_storage_usage + \(bind: amount)) <= t.limit_bytes 
                    FROM users u 
                    JOIN storage_tiers t ON u.tier_id = t.id 
                    WHERE u.id = \(bind: userID)
                )
                RETURNING id;
            """
        ).first()

        if result == nil {
            throw Abort(.payloadTooLarge, reason: "Quota exceeded or user not found.")
        }
    }

    private func updateQuotaAtomic(
        amount: Int64,
        userID: UUID,
        isIncrement: Bool,
        on connection: (any Database)? = nil
    ) async throws {
        // Use the passed connection or fall back to the main pool
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
            )
        }
    }

}

// MARK: - Filter Enum
extension StorageService {
    enum FileFilter {
        case folder(id: UUID?)
        case all
        case favorites
        case recent
        case trash
        case shared
    }
}
