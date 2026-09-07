import Fluent

/// Replaces the coarse `is_sso_managed` bool on `groups` with `sso_source`, the provider id
/// (e.g. `oidc:keycloak`, `ldap`) that manages the group - mirroring `user_groups.source`.
/// `nil` means the group is manual. SQLite requires separate ALTER TABLE ops per column.
struct AddSSOSourceToGroups: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("groups")
            .field("sso_source", .string)
            .update()
        try await database.schema("groups")
            .deleteField("is_sso_managed")
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("groups")
            .field("is_sso_managed", .bool, .required, .sql(.default(false)))
            .update()
        try await database.schema("groups")
            .deleteField("sso_source")
            .update()
    }
}
