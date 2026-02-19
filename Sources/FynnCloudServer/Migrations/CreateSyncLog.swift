import Fluent

struct CreateSyncLog: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("sync_logs")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            // Plain UUID (no reference) so we can log deletions of files that no longer exist
            .field("file_id", .uuid, .required)
            .field("seq", .int64, .required)
            .field("event_type", .string, .required)
            .field("content_updated", .bool, .required, .custom("DEFAULT FALSE"))
            .field("created_at", .datetime)
            .unique(on: "user_id", "seq")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("sync_logs").delete()
    }
}
