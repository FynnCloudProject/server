import Fluent
import Vapor

final class SyncCursor: Model, Content, @unchecked Sendable {
    static let schema = "sync_cursors"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "device_id")
    var deviceID: String

    @OptionalField(key: "device_name")
    var deviceName: String?

    @Field(key: "last_seq")
    var lastSeq: Int64

    @Field(key: "last_synced_at")
    var lastSyncedAt: Date

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userID: UUID,
        deviceID: String,
        deviceName: String? = nil,
        lastSeq: Int64 = 0
    ) {
        self.id = id
        self.$user.id = userID
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.lastSeq = lastSeq
        self.lastSyncedAt = Date()
    }
}
