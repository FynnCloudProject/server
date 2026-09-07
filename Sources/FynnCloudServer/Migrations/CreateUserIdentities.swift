import Fluent

struct CreateUserIdentities: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("user_identities")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("provider", .string, .required)
            .field("subject", .string, .required)
            .field("created_at", .datetime)
            .unique(on: "provider", "subject")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("user_identities").delete()
    }
}
