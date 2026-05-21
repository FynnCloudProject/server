import Fluent
import FluentSQL
import Foundation

struct AddTrashGroupToFileMetadata: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("file_metadata")
            .field("trash_group_id", .uuid)
            .update()

        try await database.schema("file_metadata")
            .field("original_parent_id", .uuid)
            .update()

        // Backfill: assign a trash_group_id to already-trashed items based on their deleted_at.
        // Items sharing the same (owner_id, deleted_at) timestamp get the same group UUID.
        // This preserves existing grouping semantics during migration.
        if let sql = database as? any SQLDatabase {
            struct TrashedGroup: Decodable {
                let owner_id: UUID
                let deleted_at: String
            }

            let rows = try await sql.raw(
                """
                SELECT DISTINCT owner_id, CAST(deleted_at AS TEXT) as deleted_at
                FROM file_metadata
                WHERE deleted_at IS NOT NULL
                """
            ).all(decoding: TrashedGroup.self)

            for row in rows {
                let groupID = UUID()
                try await sql.raw(
                    """
                    UPDATE file_metadata
                    SET trash_group_id = \(bind: groupID)
                    WHERE owner_id = \(bind: row.owner_id)
                    AND CAST(deleted_at AS TEXT) = \(bind: row.deleted_at)
                    """
                ).run()
            }

            // Also backfill original_parent_id from current parent_id for trashed items
            try await sql.raw(
                """
                UPDATE file_metadata
                SET original_parent_id = parent_id
                WHERE deleted_at IS NOT NULL AND parent_id IS NOT NULL
                """
            ).run()

            // Index on trash_group_id for efficient trash queries
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS file_metadata_trash_group_id_idx ON file_metadata (trash_group_id)"
            ).run()
        }
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS file_metadata_trash_group_id_idx").run()
        }

        // SQLite doesn't support DROP COLUMN, so for SQLite this is a no-op revert.
        // For Postgres:
        try await database.schema("file_metadata")
            .deleteField("trash_group_id")
            .deleteField("original_parent_id")
            .update()
    }
}
