import Fluent
import FluentSQL

struct FixUniqueIndexPartialSoftDelete: AsyncMigration {
    func prepare(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS file_metadata_parent_id_filename_unique").run()

            if sql.dialect.name == "postgresql" {
                try await sql.raw(
                    "CREATE UNIQUE INDEX IF NOT EXISTS file_metadata_parent_id_filename_unique ON file_metadata (parent_id, filename) WHERE deleted_at IS NULL"
                ).run()
            } else {
                try await sql.raw(
                    "CREATE UNIQUE INDEX IF NOT EXISTS file_metadata_parent_id_filename_unique ON file_metadata (parent_id, filename)"
                ).run()
            }
        }
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS file_metadata_parent_id_filename_unique").run()
            try await sql.raw(
                "CREATE UNIQUE INDEX IF NOT EXISTS file_metadata_parent_id_filename_unique ON file_metadata (parent_id, filename)"
            ).run()
        }
    }
}
