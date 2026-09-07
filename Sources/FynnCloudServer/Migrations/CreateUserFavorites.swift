import Fluent
import SQLKit

struct CreateUserFavorites: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("user_favorites")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("file_id", .uuid, .required, .references("file_metadata", "id", onDelete: .cascade))
            .field("created_at", .datetime)
            .unique(on: "user_id", "file_id")
            .create()

        let favoritedFiles = try await FileMetadata.query(on: database)
            .filter(\.$isFavorite == true)
            .filter(\.$deletedAt == nil)
            .all()

        for file in favoritedFiles {
            if let fileID = file.id {
                let fav = UserFavorite(userID: file.$owner.id, fileID: fileID)
                try? await fav.save(on: database)
            }
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema("user_favorites").delete()
    }
}
