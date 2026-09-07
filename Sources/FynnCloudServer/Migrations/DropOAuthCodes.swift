import Fluent

struct DropOAuthCodes: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("oauth_codes").delete()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("oauth_codes")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("code_challenge", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("client_id", .string, .required)
            .field("state", .string)
            .create()
    }
}
