import Fluent

struct AddDisplayNameToUsers: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("users")
            .field("display_name", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("users")
            .deleteField("display_name")
            .update()
    }
}
