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
        let standardTier = StorageTier(name: "Standard", limitBytes: 5 * 1024 * 1024 * 1024)  // 5GB
        let extraTier = StorageTier(name: "Extra", limitBytes: 50 * 1024 * 1024 * 1024)  // 50GB
        let unlimitedTier = StorageTier(name: "Unlimited", limitBytes: 1_125_899_906_842_624)  // 1 PB = unlimited

        try await standardTier.create(on: database)
        try await extraTier.create(on: database)
        try await unlimitedTier.create(on: database)

    }

    func revert(on database: any Database) async throws {
        try await database.schema("file_metadata").delete()
        try await database.schema("users").delete()
        try await database.schema("storage_tiers").delete()
    }
}
