import Fluent
import FluentSQL
import Foundation

struct AddUploadedAtToFileMetadata: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("file_metadata")
            .field("uploaded_at", .datetime)
            .update()

        if let sql = database as? any SQLDatabase {
            try await sql.raw(
                """
                UPDATE file_metadata
                SET uploaded_at = COALESCE(created_at, updated_at, CURRENT_TIMESTAMP)
                WHERE uploaded_at IS NULL
                """
            ).run()

            try await sql.raw(
                """
                UPDATE file_metadata
                SET created_at = last_modified
                WHERE created_at > last_modified AND last_modified IS NOT NULL
                """
            ).run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema("file_metadata")
            .deleteField("uploaded_at")
            .update()
    }
}
