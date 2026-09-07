import Fluent

struct CreateUserPasskeys: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("user_passkeys")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("credential_id", .string, .required)
            .field("public_key", .data, .required)
            .field("current_sign_count", .int64, .required, .sql(.default(0)))
            .field("nickname", .string, .required)
            .field("aaguid", .string)
            .field("transports", .string) // JSON encoded array of strings e.g. ["internal", "hybrid"]
            .field("created_at", .datetime)
            .field("last_used_at", .datetime)
            .unique(on: "credential_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("user_passkeys").delete()
    }
}
