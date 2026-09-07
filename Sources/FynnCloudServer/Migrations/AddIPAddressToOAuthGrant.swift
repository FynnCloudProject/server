import Fluent

struct AddIPAddressToOAuthGrant: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("oauth_grants")
            .field("ip_address", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("oauth_grants")
            .deleteField("ip_address")
            .update()
    }
}
