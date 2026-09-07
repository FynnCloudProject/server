import Fluent
import SQLKit

/// Renames `groups.sso_source` to `groups.source` with a non-null `"manual"` default,
/// bringing parity with `user_groups.source`.
struct RenameSSOSourceToSourceOnGroups: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("groups")
            .field("source", .string, .required, .sql(.default("manual")))
            .update()

        if let sql = database as? any SQLDatabase {
            try await sql.raw("UPDATE groups SET source = sso_source WHERE sso_source IS NOT NULL AND sso_source != ''").run()
        }

        try await database.schema("groups")
            .deleteField("sso_source")
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("groups")
            .field("sso_source", .string)
            .update()

        if let sql = database as? any SQLDatabase {
            try await sql.raw("UPDATE groups SET sso_source = source WHERE source != 'manual'").run()
        }

        try await database.schema("groups")
            .deleteField("source")
            .update()
    }
}
