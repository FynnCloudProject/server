import Fluent

struct AddGracePeriodToOAuthGrant: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("oauth_grants")
            .field("previous_refresh_token_id", .uuid)
            .update()

        try await database.schema("oauth_grants")
            .field("last_rotated_at", .datetime)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("oauth_grants")
            .deleteField("previous_refresh_token_id")
            .deleteField("last_rotated_at")
            .update()
    }
}
