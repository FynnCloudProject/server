import Fluent

/// Recovery codes moved from a newline-delimited column on `user_totp` to their own table.
struct DropRecoveryCodesFromUserTOTP: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("user_totp")
            .deleteField("recovery_codes")
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("user_totp")
            .field("recovery_codes", .string)
            .update()
    }
}
