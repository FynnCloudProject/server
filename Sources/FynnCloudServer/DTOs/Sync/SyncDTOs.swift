import Vapor

// MARK: - Sync DTOs

struct DeltaRequest: Content {
    /// The last seq the client has processed. Send 0 for first sync attempt.
    var after: Int64
    /// Max entries to return (default 500, max 2000)
    var limit: Int?
    /// Optional client device identifier
    var deviceID: String?
}

struct DeltaResponse: Content {
    /// The sync log entries since `after`
    var logs: [SyncLogEntry]
    /// Whether there are more entries beyond this batch
    var hasMore: Bool
    /// If true, client must do a full state sync (logs were pruned)
    var reset: Bool
    /// The current head of the sync timeline
    var currentSeq: Int64
}

struct SyncLogEntry: Content {
    var seq: Int64
    var fileID: UUID
    var eventType: String
    var contentUpdated: Bool
    var filename: String?
    var isDirectory: Bool?
    var size: Int64?
    var hash: String?
    var parentID: UUID?
    var lastModified: Date?
    var oldFilename: String?
    var oldParentID: UUID?
    var createdAt: Date?
}

struct AckRequest: Content {
    var deviceID: String
    var deviceName: String?
    var seq: Int64
}

struct CursorResponse: Content {
    var deviceID: String
    var deviceName: String?
    var lastSeq: Int64
    var lastSyncedAt: Date
}

struct ActivityRequest: Content {
    var page: Int?
    var limit: Int?
    var fileID: UUID?
}

struct ActivityUserDTO: Content {
    var id: UUID
    var username: String
    var displayName: String?
}

struct ActivityEntry: Content {
    var id: UUID
    var fileID: UUID?
    var filename: String?
    var isDirectory: Bool?
    var eventType: String
    var contentUpdated: Bool
    var size: Int64?
    var hash: String?
    var parentID: UUID?
    var parentName: String?
    var lastModified: Date?
    var oldFilename: String?
    var oldParentID: UUID?
    var oldParentName: String?
    var createdAt: Date?
    var user: ActivityUserDTO?
}

struct ActivityResponse: Content {
    var entries: [ActivityEntry]
    var page: Int
    var totalPages: Int
    var totalCount: Int
}

