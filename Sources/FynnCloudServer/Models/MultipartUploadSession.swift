import Fluent
import Vapor

final class MultipartUploadSession: Model, @unchecked Sendable {
    static let schema = "multipart_upload_sessions"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "file_id")
    var fileID: UUID

    @Field(key: "upload_id")
    var uploadID: String

    @Parent(key: "user_id")
    var user: User

    @Field(key: "filename")
    var filename: String

    @Field(key: "total_size")
    var totalSize: Int64

    @Field(key: "expires_at")
    var expiresAt: Date

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        fileID: UUID,
        uploadID: String,
        userID: UUID,
        filename: String,
        totalSize: Int64,
        expiresAt: Date
    ) {
        self.id = id
        self.fileID = fileID
        self.uploadID = uploadID
        self.$user.id = userID
        self.filename = filename
        self.totalSize = totalSize
        self.expiresAt = expiresAt
    }
}
