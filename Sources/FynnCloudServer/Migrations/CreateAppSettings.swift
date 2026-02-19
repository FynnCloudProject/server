import Fluent

struct CreateAppSettings: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("app_settings")
            .field("key", .string, .identifier(auto: false))
            .field("value", .string, .required)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("app_settings").delete()
    }
}
