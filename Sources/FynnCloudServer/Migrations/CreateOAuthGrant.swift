import Fluent

struct CreateOAuthGrant: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("oauth_grants")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id"))
            .field("client_id", .string, .required)
            .field("created_at", .datetime)
            .field("user_agent", .string)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("oauth_grants").delete()
    }
}
