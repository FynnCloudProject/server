import Fluent
import SQLKit

struct CreateInternalShares: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("internal_shares")
            .id()
            .field("file_id", .uuid, .required, .references("file_metadata", "id", onDelete: .cascade))
            .field("grantee_type", .string, .required)
            .field("grantee_user_id", .uuid, .references("users", "id", onDelete: .cascade))
            .field("grantee_group_id", .int, .references("groups", "id", onDelete: .cascade))
            .field("role", .string, .required)
            .field("created_by", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()

        if let sql = database as? any SQLDatabase {
            try await sql.raw("CREATE UNIQUE INDEX IF NOT EXISTS uq_ishare_user ON internal_shares (file_id, grantee_user_id) WHERE grantee_user_id IS NOT NULL").run()
            try await sql.raw("CREATE UNIQUE INDEX IF NOT EXISTS uq_ishare_group ON internal_shares (file_id, grantee_group_id) WHERE grantee_group_id IS NOT NULL").run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema("internal_shares").delete()
    }
}
