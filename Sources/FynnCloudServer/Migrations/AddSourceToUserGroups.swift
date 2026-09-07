import Fluent

struct AddSourceToUserGroups: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("user_groups")
            .field("source", .string, .required, .sql(.default("manual")))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("user_groups")
            .deleteField("source")
            .update()
    }
}
