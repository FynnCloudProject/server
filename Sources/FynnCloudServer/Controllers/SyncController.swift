import Fluent
import FluentSQL
import SQLKit
import Vapor

struct SyncController: RouteCollection {

    private static let defaultLimit = 500
    private static let maxLimit = 2000
    /// Maximum pending delta entries a client can catch up with before we signal a reset
    /// to trigger a clean, efficient re-enumeration instead of replaying thousands of individual logs.
    private static let maxDeltaLag = 1000

    func boot(routes: any RoutesBuilder) throws {
        let api = routes.grouped("api", "sync")

        let protected = api.grouped(UserPayloadAuthenticator(), UserPayload.guardMiddleware())
        protected.get("delta", use: delta)
        protected.post("ack", use: acknowledge)
        protected.get("cursors", use: listCursors)
        protected.delete("cursors", ":deviceID", use: deleteCursor)
        protected.get("activity", use: activity)
    }

    /// `GET /api/sync/delta?after=123&limit=500`
    /// Returns changes since the given seq number.
    func delta(req: Request) async throws -> DeltaResponse {
        let userID = try req.auth.require(UserPayload.self).getID()
        let params = try req.query.decode(DeltaRequest.self)
        let limit = min(params.limit ?? Self.defaultLimit, Self.maxLimit)

        let currentSeq = try await getCurrentSeq(on: req.db)

        if params.after >= currentSeq {
            return DeltaResponse(logs: [], hasMore: false, reset: false, currentSeq: currentSeq)
        }

        let oldestAvailable = try await getOldestSeq(for: userID, on: req.db)
        if let oldest = oldestAvailable, params.after < oldest && params.after > 0 {
            // Client is too far behind (logs were pruned) - signal reset so the
            // FileProvider throws .syncAnchorExpired and re-enumerates via /api/files
            req.logger(subsystem: .sync).info(
                "Sync delta reset signaled to client: logs pruned",
                metadata: [
                    "user_id": .stringConvertible(userID),
                    "after_seq": .stringConvertible(params.after),
                    "oldest_available": .stringConvertible(oldest),
                    "current_seq": .stringConvertible(currentSeq),
                ]
            )
            return DeltaResponse(logs: [], hasMore: false, reset: true, currentSeq: currentSeq)
        }

        // If client is lagging behind by more than maxDeltaLag events, signal reset
        // to cleanly re-enumerate rather than churning through thousands of individual delta fetches
        if params.after > 0 {
            let pendingCount = try await SyncLog.query(on: req.db)
                .filter(\.$user.$id == userID)
                .filter(\.$seq > params.after)
                .limit(Self.maxDeltaLag + 1)
                .count()

            if pendingCount > Self.maxDeltaLag {
                req.logger(subsystem: .sync).info(
                    "Sync delta reset signaled to client: delta lag exceeded",
                    metadata: [
                        "user_id": .stringConvertible(userID),
                        "after_seq": .stringConvertible(params.after),
                        "pending_count": .stringConvertible(pendingCount),
                        "max_lag": .stringConvertible(Self.maxDeltaLag),
                        "current_seq": .stringConvertible(currentSeq),
                    ]
                )
                return DeltaResponse(logs: [], hasMore: false, reset: true, currentSeq: currentSeq)
            }
        }

        let logs = try await SyncLog.query(on: req.db)
            .filter(\.$user.$id == userID)
            .filter(\.$seq > params.after)
            .sort(\.$seq, .ascending)
            .limit(limit + 1)
            .all()

        let hasMore = logs.count > limit
        let entries = logs.prefix(limit).map { log in
            SyncLogEntry(
                seq: log.seq,
                fileID: log.$file.id ?? UUID(),
                eventType: log.eventType.rawValue,
                contentUpdated: log.contentUpdated,
                filename: log.filename,
                isDirectory: log.isDirectory,
                size: log.size,
                hash: log.hash,
                parentID: log.parentID,
                lastModified: log.lastModified,
                oldFilename: log.oldFilename,
                oldParentID: log.oldParentID,
                createdAt: log.createdAt
            )
        }

        req.logger(subsystem: .sync).debug(
            "Sync delta fetched",
            metadata: [
                "user_id": .stringConvertible(userID),
                "after_seq": .stringConvertible(params.after),
                "count": .stringConvertible(entries.count),
                "has_more": .stringConvertible(hasMore),
            ]
        )

        return DeltaResponse(
            logs: Array(entries),
            hasMore: hasMore,
            reset: false,
            currentSeq: currentSeq
        )
    }

    /// `POST /api/sync/ack` - Client confirms it has processed up to a given seq.
    func acknowledge(req: Request) async throws -> HTTPStatus {
        let userID = try req.auth.require(UserPayload.self).getID()
        let body = try req.content.decode(AckRequest.self)

        if let existing = try await SyncCursor.query(on: req.db)
            .filter(\.$user.$id == userID)
            .filter(\.$deviceID == body.deviceID)
            .first()
        {
            existing.lastSeq = body.seq
            existing.lastSyncedAt = Date()
            if let name = body.deviceName {
                existing.deviceName = name
            }
            try await existing.save(on: req.db)
        } else {
            let cursor = SyncCursor(
                userID: userID,
                deviceID: body.deviceID,
                deviceName: body.deviceName,
                lastSeq: body.seq
            )
            try await cursor.save(on: req.db)
        }

        req.logger(subsystem: .sync).debug(
            "Sync cursor acknowledged",
            metadata: [
                "user_id": .stringConvertible(userID),
                "device_id": .string(body.deviceID),
                "seq": .stringConvertible(body.seq),
            ]
        )

        return .noContent
    }

    /// `GET /api/sync/cursors` - List all registered devices and their sync positions.
    func listCursors(req: Request) async throws -> [CursorResponse] {
        let userID = try req.auth.require(UserPayload.self).getID()

        let cursors = try await SyncCursor.query(on: req.db)
            .filter(\.$user.$id == userID)
            .all()

        return cursors.map { cursor in
            CursorResponse(
                deviceID: cursor.deviceID,
                deviceName: cursor.deviceName,
                lastSeq: cursor.lastSeq,
                lastSyncedAt: cursor.lastSyncedAt
            )
        }
    }

    /// `DELETE /api/sync/cursors/:deviceID` - Unregister a device.
    func deleteCursor(req: Request) async throws -> HTTPStatus {
        let userID = try req.auth.require(UserPayload.self).getID()
        guard let deviceID = req.parameters.get("deviceID") else {
            throw Abort(.badRequest)
        }

        try await SyncCursor.query(on: req.db)
            .filter(\.$user.$id == userID)
            .filter(\.$deviceID == deviceID)
            .delete()

        return .noContent
    }

    /// `GET /api/sync/activity?fileID=123&page=1&limit=30`
    /// Returns recent sync activity for the user or for a specific file.
    func activity(req: Request) async throws -> ActivityResponse {
        let userID = try req.auth.require(UserPayload.self).getID()
        let params = try req.query.decode(ActivityRequest.self)

        return try await Self.fetchActivity(
            db: req.db,
            fileAccess: req.fileAccess,
            userID: userID,
            fileID: params.fileID,
            page: params.page ?? 1,
            limit: params.limit ?? 30
        )
    }

    static func fetchActivity(
        db: any Database,
        fileAccess: FileAccessService,
        userID: UUID,
        fileID: UUID?,
        page: Int,
        limit: Int
    ) async throws -> ActivityResponse {
        let sanitizedPage = max(page, 1)
        let sanitizedLimit = min(max(limit, 1), 100)
        let offset = (sanitizedPage - 1) * sanitizedLimit

        var query = SyncLog.query(on: db).with(\.$user)

        if let fileID = fileID {
            _ = try await fileAccess.validateAccess(fileID: fileID, userID: userID, required: .read)
            query = query.filter(\.$file.$id == fileID)
        } else {
            query = query.filter(\.$user.$id == userID)
        }

        let totalCount = try await query.count()

        let logs =
            try await query
            .sort(\.$createdAt, .descending)
            .range(offset..<(offset + sanitizedLimit))
            .all()

        let folderIDs = Array(
            Set(logs.compactMap { $0.parentID } + logs.compactMap { $0.oldParentID }))
        var folderNames: [UUID: String] = [:]
        if !folderIDs.isEmpty {
            let folders = try await FileMetadata.query(on: db)
                .withDeleted()
                .filter(\.$id ~~ folderIDs)
                .all()
            for folder in folders {
                if let id = folder.id {
                    folderNames[id] = folder.filename
                }
            }
        }

        let entries = logs.map { log in
            let userDTO: ActivityUserDTO?
            if let u = log.$user.value {
                userDTO = ActivityUserDTO(
                    id: u.id ?? UUID(),
                    username: u.username,
                    displayName: u.displayName
                )
            } else {
                userDTO = nil
            }

            return ActivityEntry(
                id: log.id ?? UUID(),
                fileID: log.$file.id,
                filename: log.filename,
                isDirectory: log.isDirectory,
                eventType: log.eventType.rawValue,
                contentUpdated: log.contentUpdated,
                size: log.size,
                hash: log.hash,
                parentID: log.parentID,
                parentName: log.parentID.flatMap { folderNames[$0] },
                lastModified: log.lastModified,
                oldFilename: log.oldFilename,
                oldParentID: log.oldParentID,
                oldParentName: log.oldParentID.flatMap { folderNames[$0] },
                createdAt: log.createdAt,
                user: userDTO
            )
        }

        let totalPages = max(1, Int(ceil(Double(totalCount) / Double(sanitizedLimit))))

        return ActivityResponse(
            entries: entries,
            page: sanitizedPage,
            totalPages: totalPages,
            totalCount: totalCount
        )
    }

    // MARK: - Helpers

    private func getCurrentSeq(on db: any Database) async throws -> Int64 {
        guard let sql = db as? any SQLDatabase else {
            return 0
        }
        let rows = try await sql.raw("SELECT last_value FROM sync_seq").all()
        guard let row = rows.first else { return 0 }
        return try row.decode(column: "last_value", as: Int64.self)
    }

    private func getOldestSeq(for userID: UUID, on db: any Database) async throws -> Int64? {
        let oldest = try await SyncLog.query(on: db)
            .filter(\.$user.$id == userID)
            .sort(\.$seq, .ascending)
            .first()
        return oldest?.seq
    }
}
