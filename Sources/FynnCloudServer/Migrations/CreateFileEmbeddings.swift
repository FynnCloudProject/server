import Fluent
import FluentSQL

struct CreateFileEmbeddings: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // Drop any leftover table from prior crashed migration runs to heal the schema state
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP TABLE IF EXISTS file_embeddings").run()
        }

        try await database.schema("file_embeddings")
            .id()
            .field("file_id", .uuid, .required, .references("file_metadata", "id", onDelete: .cascade))
            .field("extracted_text", .string, .required)
            .field("vector_data", .string, .required) // Serialized [Float] JSON array
            .create()

        if let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" {
            do {
                try await sql.raw("CREATE EXTENSION IF NOT EXISTS vector").run()
                try await sql.raw("ALTER TABLE file_embeddings ADD COLUMN embedding vector(384)").run()
                try await sql.raw("""
                    CREATE INDEX IF NOT EXISTS file_embeddings_vector_idx 
                    ON file_embeddings USING hnsw (embedding vector_cosine_ops)
                """).run()
                database.logger.info("✅ PostgreSQL vector extension and HNSW index successfully configured.")
            } catch {
                database.logger.warning("⚠️ PostgreSQL vector extension is not installed/available (\(error.localizedDescription)). Falling back to SQLite-style in-memory similarity matching for Postgres.")
            }
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema("file_embeddings").delete()
    }
}
