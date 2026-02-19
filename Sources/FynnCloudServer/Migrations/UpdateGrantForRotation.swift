import Fluent

struct UpdateGrantForRotation: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("oauth_grants")
            .field("current_refresh_token_id", .uuid)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("oauth_grants")
            .deleteField("current_refresh_token_id")
            .update()
    }
}
