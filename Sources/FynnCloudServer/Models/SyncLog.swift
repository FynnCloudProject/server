import Fluent
import Vapor

final class SyncLog: Model, Content, @unchecked Sendable {
    static let schema = "sync_logs"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @OptionalParent(key: "file_id")
    var file: FileMetadata?

    @Field(key: "seq")
    var seq: Int64

    @Field(key: "event_type")
    var eventType: SyncLog.EventType

    @Field(key: "content_updated")
    var contentUpdated: Bool

    @OptionalField(key: "filename")
    var filename: String?

    @OptionalField(key: "is_directory")
    var isDirectory: Bool?

    @OptionalField(key: "size")
    var size: Int64?

    @OptionalField(key: "hash")
    var hash: String?

    @OptionalField(key: "parent_id")
    var parentID: UUID?

    @OptionalField(key: "last_modified")
    var lastModified: Date?

    @OptionalField(key: "old_filename")
    var oldFilename: String?

    @OptionalField(key: "old_parent_id")
    var oldParentID: UUID?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userID: UUID,
        fileID: UUID,
        seq: Int64,
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
    ) {
        self.id = id
        self.$user.id = userID
        self.$file.id = fileID
        self.seq = seq
        self.eventType = eventType
        self.contentUpdated = contentUpdated
        self.filename = filename
        self.isDirectory = isDirectory
        self.size = size
        self.hash = hash
        self.parentID = parentID
        self.lastModified = lastModified
        self.oldFilename = oldFilename
        self.oldParentID = oldParentID
    }
}

extension SyncLog {
    enum EventType: String, Codable {
        case create      // Newly Created
        case modify      // Content or Last-Modified Changed
        case rename      // Renamed
        case move        // Moved to Different Parent
        case trash       // Soft Deleted
        case restore     // Restored from Trash
        case delete      // Hard Deleted
        case favorite    // Favorited
        case unfavorite  // Unfavorited
        case share       // Shared with user/group or public link created
        case unshare     // Unshared
        case upsert      // Legacy fallback
    }
}
