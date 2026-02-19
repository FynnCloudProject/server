import Fluent
import Vapor

final class FileMetadata: Model, Content, @unchecked Sendable {
    static let schema = "file_metadata"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "filename")
    var filename: String

    @Field(key: "content_type")
    var contentType: String

    @Field(key: "size")
    var size: Int64

    @Field(key: "is_directory")
    var isDirectory: Bool

    @OptionalParent(key: "parent_id")
    var parent: FileMetadata?

    @Parent(key: "owner_id")
    var owner: User

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    @Field(key: "last_modified")
    var lastModified: Date?

    @Timestamp(key: "deleted_at", on: .delete)
    var deletedAt: Date?

    @Field(key: "is_favorite")
    var isFavorite: Bool

    @Field(key: "is_shared")
    var isShared: Bool

    init() {}

    init(
        id: UUID? = nil, filename: String, contentType: String, size: Int64,
        isDirectory: Bool = false, parentID: FileMetadata.IDValue? = nil, ownerID: User.IDValue,
        isFavorite: Bool = false, isShared: Bool = false, lastModified: Date? = nil
    ) {
        self.id = id
        self.filename = filename
        self.contentType = contentType
        self.size = size
        self.isDirectory = isDirectory
        self.$parent.id = parentID
        self.$owner.id = ownerID
        self.isFavorite = isFavorite
        self.isShared = isShared
        self.lastModified = lastModified
    }
}
