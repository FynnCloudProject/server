import Fluent

struct AddSSOManagedToGroups: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("groups")
            .field("is_sso_managed", .bool, .required, .sql(.default(false)))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("groups")
            .deleteField("is_sso_managed")
            .update()
    }
}
