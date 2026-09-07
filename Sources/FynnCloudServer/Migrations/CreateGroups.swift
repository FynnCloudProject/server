import Fluent
import SQLKit

struct CreateGroups: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("groups")
            .field(.id, .int, .identifier(auto: true))
            .field("name", .string, .required)
            .field("tier_id", .int, .references("storage_tiers", "id"))
            .field("is_admin", .bool, .required, .sql(.default(false)))
            .field("created_at", .datetime)
            .unique(on: "name")
            .create()

        try await database.schema("user_groups")
            .field(.id, .int, .identifier(auto: true))
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("group_id", .int, .required, .references("groups", "id", onDelete: .cascade))
            .unique(on: "user_id", "group_id")
            .create()

        if let sql = database as? any SQLDatabase {
            try await sql.raw("INSERT INTO groups (name, is_admin) VALUES ('admin', \(bind: true))").run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema("user_groups").delete()
        try await database.schema("groups").delete()
    }
}
