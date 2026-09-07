import Fluent

struct CreateUserTOTP: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("user_totp")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("secret", .string, .required)
            .field("is_enabled", .bool, .required, .sql(.default(false)))
            .field("recovery_codes", .string)
            .field("created_at", .datetime)
            .field("confirmed_at", .datetime)
            .unique(on: "user_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("user_totp").delete()
    }
}
