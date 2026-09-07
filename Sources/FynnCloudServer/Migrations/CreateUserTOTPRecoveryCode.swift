import Fluent

struct CreateUserTOTPRecoveryCode: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("user_totp_recovery_code")
            .id()
            .field(
                "totp_id", .uuid, .required,
                .references("user_totp", "id", onDelete: .cascade)
            )
            .field("code_hash", .string, .required)
            .field("used_at", .datetime)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("user_totp_recovery_code").delete()
    }
}
