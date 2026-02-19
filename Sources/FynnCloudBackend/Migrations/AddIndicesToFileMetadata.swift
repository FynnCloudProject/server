import Fluent
import FluentSQL

struct AddIndicesToFileMetadata: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // Compound index to ensure filenames are unique within a folder
        // SQLite doesn't support adding constraints via ALTER TABLE, so we use a unique index instead.
        if let sql = database as? any SQLDatabase {
            try await sql.raw(
                "CREATE UNIQUE INDEX IF NOT EXISTS file_metadata_parent_id_filename_unique ON file_metadata (parent_id, filename)"
            ).run()
        }

        // Use raw SQL for other indices if Fluent's createIndex is unavailable
        if let sql = database as? any SQLDatabase {
            // Index for parent_id
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS file_metadata_parent_id_idx ON file_metadata (parent_id)"
            ).run()

            // Index for owner_id
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS file_metadata_owner_id_idx ON file_metadata (owner_id)"
            ).run()
        }
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS file_metadata_parent_id_filename_unique").run()
        }

        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS file_metadata_parent_id_idx").run()
            try await sql.raw("DROP INDEX IF EXISTS file_metadata_owner_id_idx").run()
        }
    }
}
