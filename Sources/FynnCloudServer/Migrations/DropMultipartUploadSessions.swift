import Fluent

struct DropMultipartUploadSessions: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("multipart_upload_sessions").delete()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("multipart_upload_sessions")
            .id()
            .field("file_id", .uuid, .required)
            .field("upload_id", .string, .required)
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("filename", .string, .required)
            .field("total_size", .int64, .required)
            .field("expires_at", .datetime, .required)
            .field("created_at", .datetime)
            .create()
    }
}
