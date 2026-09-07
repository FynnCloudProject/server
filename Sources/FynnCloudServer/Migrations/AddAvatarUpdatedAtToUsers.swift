import Fluent

struct AddAvatarUpdatedAtToUsers: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("users")
            .field("avatar_updated_at", .datetime)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("users")
            .deleteField("avatar_updated_at")
            .update()
    }
}
