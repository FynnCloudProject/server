import Fluent

struct AddLinkTypeAndRequiresAuthToShareLink: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("share_links")
            .field("link_type", .string, .required, .sql(.default("view_only")))
            .update()

        try await database.schema("share_links")
            .field("requires_auth", .bool, .required, .sql(.default(false)))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("share_links")
            .deleteField("requires_auth")
            .update()

        try await database.schema("share_links")
            .deleteField("link_type")
            .update()
    }
}
