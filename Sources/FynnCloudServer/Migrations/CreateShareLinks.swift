import Fluent

struct CreateShareLinks: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("share_links")
            .id()
            .field("token", .string, .required)
            .field("file_id", .uuid, .required, .references("file_metadata", "id", onDelete: .cascade))
            .field("created_by", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("expires_at", .datetime)
            .field("password_hash", .string)
            .field("created_at", .datetime)
            .unique(on: "token")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("share_links").delete()
    }
}
