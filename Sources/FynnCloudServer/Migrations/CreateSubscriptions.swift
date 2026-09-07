import Fluent

struct CreateSubscriptions: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("subscriptions")
            .id()
            .field("token", .string, .required)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("subscriptions").delete()
    }
}
