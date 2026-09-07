import Fluent
import Vapor

final class UserFavorite: Model, Content, @unchecked Sendable {
    static let schema = "user_favorites"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Parent(key: "file_id")
    var file: FileMetadata

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, userID: User.IDValue, fileID: FileMetadata.IDValue) {
        self.id = id
        self.$user.id = userID
        self.$file.id = fileID
    }
}

extension UserFavorite {
    static func exists(fileID: UUID, userID: UUID, on db: any Database) async throws -> Bool {
        try await query(on: db)
            .filter(\.$user.$id == userID)
            .filter(\.$file.$id == fileID)
            .count() > 0
    }

    /// Favourite state for a whole batch of files in one query.
    static func ids(among fileIDs: [UUID], userID: UUID, on db: any Database) async throws -> Set<UUID> {
        guard !fileIDs.isEmpty else { return [] }
        return Set(
            try await query(on: db)
                .filter(\.$user.$id == userID)
                .filter(\.$file.$id ~~ fileIDs)
                .all()
                .map { $0.$file.id })
    }
}
