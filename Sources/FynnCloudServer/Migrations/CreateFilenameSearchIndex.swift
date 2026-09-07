import Fluent
import FluentSQL

struct CreateFilenameSearchIndex: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" else { return }

        // Enable the trigram extension (idempotent)
        try await sql.raw("CREATE EXTENSION IF NOT EXISTS pg_trgm").run()

        // GIN trigram index on filename for ILIKE and similarity() queries
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS
            file_metadata_filename_trgm_idx
            ON file_metadata USING gin (filename gin_trgm_ops)
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" else { return }
        try await sql.raw("DROP INDEX IF EXISTS file_metadata_filename_trgm_idx").run()
    }
}
