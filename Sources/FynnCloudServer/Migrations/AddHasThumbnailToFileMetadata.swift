import Fluent

struct AddHasThumbnailToFileMetadata: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("file_metadata")
            .field("has_thumbnail", .bool, .required, .sql(.default(false)))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("file_metadata")
            .deleteField("has_thumbnail")
            .update()
    }
}
