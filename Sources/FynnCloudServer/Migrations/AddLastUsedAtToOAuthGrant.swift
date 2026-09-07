import Fluent

struct AddLastUsedAtToOAuthGrant: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("oauth_grants")
            .field("last_used_at", .datetime)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("oauth_grants")
            .deleteField("last_used_at")
            .update()
    }
}
