import Fluent

struct CreateInitialMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // Create Storage Tiers
        try await database.schema("storage_tiers")
            .field(.id, .int, .identifier(auto: true))
            .field("name", .string, .required)
            .field("limit_bytes", .int64, .required)
            .unique(on: "name")
            .create()

        // Create Users
        try await database.schema("users")
            .id()
            .field("username", .string, .required)
            .field("email", .string, .required)
            .field("password_hash", .string, .required)
            .field("current_storage_usage", .int64, .required, .sql(.default(0)))
            .field("tier_id", .int, .references("storage_tiers", "id"))
            .unique(on: "username")
            .unique(on: "email")
            .create()

        // Create File Metadata
        try await database.schema("file_metadata")
            .id()
            .field("filename", .string, .required)
            .field("content_type", .string, .required)
            .field("size", .int64, .required)
            .field("is_directory", .bool, .required, .sql(.default(false)))
            .field("parent_id", .uuid, .references("file_metadata", "id"))
            .field("owner_id", .uuid, .required, .references("users", "id"))
            .field("created_at", .datetime)
            .field("deleted_at", .datetime)
            .field("last_modified", .datetime)
            .field("updated_at", .datetime)
            .field("is_favorite", .bool, .required, .sql(.default(false)))
            .field("is_shared", .bool, .required, .sql(.default(false)))
            .create()

        // Seed Default Storage Tiers
        // TODO: Reimplement since FynnCloud wasn't meant to be a self-hosted solution at first
        let freeTier = StorageTier(name: "Free", limitBytes: 5 * 1024 * 1024 * 1024)  // 5GB
        let proTier = StorageTier(name: "Pro", limitBytes: 50 * 1024 * 1024 * 1024)  // 50GB
        let businessTier = StorageTier(name: "Business", limitBytes: 1024 * 1024 * 1024 * 1024)  // 1TB

        try await freeTier.create(on: database)
        try await proTier.create(on: database)
        try await businessTier.create(on: database)

    }

    func revert(on database: any Database) async throws {
        try await database.schema("file_metadata").delete()
        try await database.schema("users").delete()
        try await database.schema("storage_tiers").delete()
    }
}
