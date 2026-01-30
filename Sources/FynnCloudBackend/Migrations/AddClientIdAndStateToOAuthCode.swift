import Fluent

struct AddClientIdAndStateToOAuthCode: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // Delete all existing codes as they are invalid without client_id and they are ephemeral anyway
        try await OAuthCode.query(on: database).delete()

        try await database.schema("oauth_codes")
            .field("client_id", .string, .required)
            .update()

        try await database.schema("oauth_codes")
            .field("state", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("oauth_codes")
            .deleteField("state")
            .update()

        try await database.schema("oauth_codes")
            .deleteField("client_id")
            .update()
    }
}
