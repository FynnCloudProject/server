import Fluent
import FluentSQL

struct UpdateEmbeddingDimension: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" else {
            return
        }

        try await sql.raw("CREATE EXTENSION IF NOT EXISTS vector").run()

        try await sql.raw("DROP INDEX IF EXISTS file_embeddings_vector_idx").run()

        try await sql.raw("ALTER TABLE file_embeddings DROP COLUMN IF EXISTS embedding").run()
        try await sql.raw("ALTER TABLE file_embeddings ADD COLUMN embedding vector(1024)").run()

        try await sql.raw("""
            CREATE INDEX file_embeddings_vector_idx
            ON file_embeddings USING hnsw (embedding vector_cosine_ops)
        """).run()

        database.logger.info("✅ Updated embedding column to vector(1024) for jina-clip-v2.")
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" else {
            return
        }

        try await sql.raw("DROP INDEX IF EXISTS file_embeddings_vector_idx").run()
        try await sql.raw("ALTER TABLE file_embeddings DROP COLUMN IF EXISTS embedding").run()
        try await sql.raw("ALTER TABLE file_embeddings ADD COLUMN embedding vector(384)").run()
        try await sql.raw("""
            CREATE INDEX file_embeddings_vector_idx
            ON file_embeddings USING hnsw (embedding vector_cosine_ops)
        """).run()
    }
}
