import Fluent
import SQLKit
import Vapor

struct CreateMultipartUploadSessions: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("multipart_upload_sessions")
            .id()
            .field("file_id", .uuid, .required)
            .field("upload_id", .string, .required)
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("filename", .string, .required)
            .field("total_size", .int64, .required)
            .field("expires_at", .datetime, .required)
            .field("created_at", .datetime)
            .unique(on: "upload_id")
            .create()

        // Create indexes for performance
        if let sql = database as? any SQLDatabase {
            // Index on user_id for user cleanup queries
            try await sql.raw(
                "CREATE INDEX idx_multipart_sessions_user_id ON multipart_upload_sessions(user_id)"
            ).run()

            // Index on expires_at for cleanup job
            try await sql.raw(
                "CREATE INDEX idx_multipart_sessions_expires_at ON multipart_upload_sessions(expires_at)"
            ).run()

            // Index on file_id for duplicate completion check
            try await sql.raw(
                "CREATE INDEX idx_multipart_sessions_file_id ON multipart_upload_sessions(file_id)"
            ).run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema("multipart_upload_sessions").delete()
    }
}
