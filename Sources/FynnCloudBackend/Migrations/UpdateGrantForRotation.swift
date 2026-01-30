import Fluent

struct UpdateGrantForRotation: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("oauth_grants")
            .field("current_refresh_token_id", .uuid)  // Matches your @Field
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("oauth_grants")
            .deleteField("current_refresh_token_id")
            .update()
    }
}
