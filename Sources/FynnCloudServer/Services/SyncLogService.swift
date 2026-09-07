import Fluent
import FluentSQL
import SQLKit
import Vapor

struct SyncLogService: Sendable {
    let logger: Logger

    init(logger: Logger = Logger(label: "sync-log")) {
        self.logger = logger
    }

    /// Emitting never throws: a failed entry must not fail the user's operation. It is logged
    /// instead, because a lost entry silently desyncs every connected client.
    func emit(
        on db: any Database,
        userID: UUID,
        fileID: UUID,
        eventType: SyncLog.EventType,
        contentUpdated: Bool,
        filename: String? = nil,
        isDirectory: Bool? = nil,
        size: Int64? = nil,
        hash: String? = nil,
        parentID: UUID? = nil,
        lastModified: Date? = nil,
        oldFilename: String? = nil,
        oldParentID: UUID? = nil
    ) async {
        do {
            try await write(
                on: db, userID: userID, fileID: fileID, eventType: eventType,
                contentUpdated: contentUpdated, filename: filename, isDirectory: isDirectory,
                size: size, hash: hash, parentID: parentID, lastModified: lastModified,
                oldFilename: oldFilename, oldParentID: oldParentID)
        } catch {
            logFailure(fileID: fileID, userID: userID, eventType: eventType, error: error)
        }
    }

    private func logFailure(
        fileID: UUID?, userID: UUID, eventType: SyncLog.EventType, error: (any Error)?
    ) {
        logger.error(
            "Failed to write sync log - clients may miss this change",
            metadata: [
                "fileID": .string(fileID?.uuidString ?? "unknown"),
                "userID": .string(userID.uuidString),
                "eventType": .string(eventType.rawValue),
                "error": .string(error.map { String(describing: $0) } ?? "missing file id"),
            ])
    }

    /// Writes a single sync log entry atomically.
    /// In PostgreSQL, writes using `nextval('sync_seq')` to guarantee strict atomic sequence ordering with zero race conditions.
    /// In SQLite (in-memory unit tests), calculates the next sequence for the user and saves via Fluent.
    private func write(
        on db: any Database,
        userID: UUID,
        fileID: UUID,
        eventType: SyncLog.EventType,
        contentUpdated: Bool,
        filename: String? = nil,
        isDirectory: Bool? = nil,
        size: Int64? = nil,
        hash: String? = nil,
        parentID: UUID? = nil,
        lastModified: Date? = nil,
        oldFilename: String? = nil,
        oldParentID: UUID? = nil
    ) async throws {
        if let sql = db as? any SQLDatabase, sql.dialect.name == "postgresql" {
            try await sql.raw(
                """
                    INSERT INTO sync_logs (
                        id, user_id, file_id, seq, event_type, content_updated,
                        filename, is_directory, size, hash, parent_id, last_modified,
                        old_filename, old_parent_id, created_at
                    ) VALUES (
                        \(bind: UUID()), \(bind: userID), \(bind: fileID), nextval('sync_seq'),
                        \(bind: eventType.rawValue), \(bind: contentUpdated), \(bind: filename),
                        \(bind: isDirectory), \(bind: size), \(bind: hash), \(bind: parentID),
                        \(bind: lastModified), \(bind: oldFilename), \(bind: oldParentID), NOW()
                    )
                """
            ).run()
        } else {
            let nextSeq =
                (try await SyncLog.query(on: db).filter(\.$user.$id == userID).max(\.$seq) ?? 0) + 1
            let log = SyncLog(
                id: UUID(),
                userID: userID,
                fileID: fileID,
                seq: nextSeq,
                eventType: eventType,
                contentUpdated: contentUpdated,
                filename: filename,
                isDirectory: isDirectory,
                size: size,
                hash: hash,
                parentID: parentID,
                lastModified: lastModified,
                oldFilename: oldFilename,
                oldParentID: oldParentID
            )
            try await log.save(on: db)
        }
    }

    /// Convenience overload for emitting sync logs from a `FileMetadata` model.
    func emit(
        on db: any Database,
        userID: UUID,
        file: FileMetadata,
        eventType: SyncLog.EventType,
        contentUpdated: Bool? = nil,
        parentID: UUID? = nil,
        oldFilename: String? = nil,
        oldParentID: UUID? = nil
    ) async {
        guard let fileID = file.id else {
            logFailure(fileID: nil, userID: userID, eventType: eventType, error: nil)
            return
        }
        let isContent = contentUpdated ?? (eventType == .create || eventType == .modify)
        await emit(
            on: db,
            userID: userID,
            fileID: fileID,
            eventType: eventType,
            contentUpdated: isContent,
            filename: file.filename,
            isDirectory: file.isDirectory,
            size: file.size,
            hash: file.hash,
            parentID: parentID ?? file.$parent.id,
            lastModified: file.lastModified,
            oldFilename: oldFilename,
            oldParentID: oldParentID
        )
    }

    /// Emits sync logs for internal share creation, update, or revocation.
    /// Handles owner notification as well as recipient / group member fan-out.
    func emitInternalShare(
        on db: any Database,
        share: InternalShare,
        file: FileMetadata,
        eventType: SyncLog.EventType
    ) async {
        guard let fileID = file.id else {
            logFailure(fileID: nil, userID: file.$owner.id, eventType: eventType, error: nil)
            return
        }
        let ownerID = file.$owner.id

        // 1. SyncLog for owner/sharer (share / unshare)
        if eventType == .share || eventType == .unshare {
            await emit(
                on: db,
                userID: ownerID,
                file: file,
                eventType: eventType,
                contentUpdated: false
            )
        }

        // 2. SyncLog for recipient(s):
        // When shared: recipient gets 'create' with parentID = nil (virtual "Shared with me" folder)
        // When unshared: recipient gets 'delete' (removed from working set)
        // When modified: recipient gets 'modify' (contentUpdated = false)
        let recipientEventType: SyncLog.EventType
        switch eventType {
        case .share:
            recipientEventType = .create
        case .unshare:
            recipientEventType = .delete
        case .modify:
            recipientEventType = .modify
        default:
            recipientEventType = eventType
        }

        if let granteeUserID = share.$granteeUser.id, granteeUserID != ownerID {
            await emit(
                on: db,
                userID: granteeUserID,
                fileID: fileID,
                eventType: recipientEventType,
                contentUpdated: false,
                filename: file.filename,
                isDirectory: file.isDirectory,
                size: file.size,
                hash: file.hash,
                parentID: nil,
                lastModified: file.lastModified
            )
        } else if let groupID = share.$granteeGroup.id {
            let members: [UserGroup]
            do {
                members = try await UserGroup.query(on: db)
                    .filter(\.$group.$id == groupID)
                    .filter(\.$user.$id != ownerID)
                    .all()
            } catch {
                logFailure(
                    fileID: fileID, userID: ownerID, eventType: recipientEventType, error: error)
                return
            }
            for member in members {
                await emit(
                    on: db,
                    userID: member.$user.id,
                    fileID: fileID,
                    eventType: recipientEventType,
                    contentUpdated: false,
                    filename: file.filename,
                    isDirectory: file.isDirectory,
                    size: file.size,
                    hash: file.hash,
                    parentID: nil,
                    lastModified: file.lastModified
                )
            }
        }
    }

    /// Emits an ordinary mutation to the owner and to everyone the file (or an ancestor of it) is
    /// shared with, so a grantee's client learns about renames, moves and deletions too.
    func emitToOwnerAndGrantees(
        on db: any Database,
        ownerID: UUID,
        file: FileMetadata,
        eventType: SyncLog.EventType,
        contentUpdated: Bool? = nil,
        oldFilename: String? = nil,
        oldParentID: UUID? = nil
    ) async {
        await emit(
            on: db, userID: ownerID, file: file, eventType: eventType,
            contentUpdated: contentUpdated, oldFilename: oldFilename, oldParentID: oldParentID)
        await emitToGrantees(
            on: db, ownerID: ownerID, file: file, eventType: eventType,
            contentUpdated: contentUpdated, oldFilename: oldFilename, oldParentID: oldParentID)
    }

    /// Notifies only the users the file is shared with, skipping the owner.
    func emitToGrantees(
        on db: any Database,
        ownerID: UUID,
        file: FileMetadata,
        eventType: SyncLog.EventType,
        contentUpdated: Bool? = nil,
        oldFilename: String? = nil,
        oldParentID: UUID? = nil
    ) async {
        guard let fileID = file.id else { return }
        // A root-level file nobody has shared can't have recipients, so skip the lookup.
        guard file.isShared || !file.ancestorIDs.isEmpty else { return }

        for granteeID in await granteeIDs(
            on: db, fileID: fileID, ancestorIDs: file.ancestorIDs, ownerID: ownerID,
            eventType: eventType)
        {
            await emit(
                on: db, userID: granteeID, file: file, eventType: eventType,
                contentUpdated: contentUpdated, oldFilename: oldFilename, oldParentID: oldParentID)
        }
    }

    /// Users who hold a share on the file itself or on any of its ancestors, individually or
    /// through a group.
    private func granteeIDs(
        on db: any Database, fileID: UUID, ancestorIDs: [UUID], ownerID: UUID,
        eventType: SyncLog.EventType
    ) async -> [UUID] {
        do {
            let shares = try await InternalShare.query(on: db)
                .filter(\.$file.$id ~~ ([fileID] + ancestorIDs))
                .all()
            guard !shares.isEmpty else { return [] }

            var ids = Set(shares.compactMap { $0.$granteeUser.id })

            let groupIDs = shares.compactMap { $0.$granteeGroup.id }
            if !groupIDs.isEmpty {
                let members = try await UserGroup.query(on: db)
                    .filter(\.$group.$id ~~ groupIDs)
                    .all()
                ids.formUnion(members.map { $0.$user.id })
            }

            ids.remove(ownerID)
            return Array(ids)
        } catch {
            logger.error(
                "Failed to resolve share recipients - they may miss this change",
                metadata: [
                    "fileID": .string(fileID.uuidString),
                    "eventType": .string(eventType.rawValue),
                    "error": .string(String(describing: error)),
                ])
            return []
        }
    }

    /// Emits sync logs for public share link creation or revocation.
    func emitPublicShare(
        on db: any Database,
        link: ShareLink,
        file: FileMetadata,
        isRevoke: Bool
    ) async {
        await emit(
            on: db,
            userID: link.$creator.id,
            file: file,
            eventType: isRevoke ? .unshare : .share,
            contentUpdated: false
        )
    }

    /// Emits sync log for favorite toggling.
    func emitFavorite(
        on db: any Database,
        userID: UUID,
        file: FileMetadata,
        isFavorite: Bool
    ) async {
        await emit(
            on: db,
            userID: userID,
            file: file,
            eventType: isFavorite ? .favorite : .unfavorite,
            contentUpdated: false
        )
    }
}
