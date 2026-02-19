import Fluent

struct CreateOAuthCode: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("oauth_codes")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id"))
            .field("code_challenge", .string, .required)
            .field("expires_at", .datetime, .required)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("oauth_codes").delete()
    }
}
