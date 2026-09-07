import Fluent

struct AddContentHashToFileMetadata: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("file_metadata")
            .field("hash", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("file_metadata")
            .deleteField("hash")
            .update()
    }
}
