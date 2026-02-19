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

    init() {}

    init(
        id: UUID? = nil,
        userID: UUID,
        fileID: UUID,
        seq: Int64,
        eventType: SyncLog.EventType,
        contentUpdated: Bool
    ) {
        self.id = id
        self.$user.id = userID
        self.$file.id = fileID
        self.seq = seq
        self.eventType = eventType
        self.contentUpdated = contentUpdated
    }
}

extension SyncLog {
    enum EventType: String, Codable {
        case upsert  // Created, Renamed, Moved, or Content Changed
        case delete  // Hard Deleted
        case trash  // Soft Deleted
    }
}
