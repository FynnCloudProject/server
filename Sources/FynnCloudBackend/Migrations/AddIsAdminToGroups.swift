import Fluent
import SQLKit

struct AddIsAdminToGroups: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // Attempt to add the column if it doesn't exist.
        // We use a try-catch block for SQL databases to handle the case where CreateGroups already added it (new installs).
        if database is SQLDatabase {
            do {
                try await database.schema("groups")
                    .field("is_admin", .bool, .required, .sql(.default(false)))
                    .update()
            } catch {
                // Column likely already exists, ignore error
            }
        } else {
            try await database.schema("groups")
                .field("is_admin", .bool, .required, .sql(.default(false)))
                .update()
        }

        // Set existing "admin" group to be admin
        if let adminGroup = try await Group.query(on: database)
            .filter(\.$name == "admin")
            .first()
        {
            adminGroup.isAdmin = true
            try await adminGroup.save(on: database)
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema("groups")
            .deleteField("is_admin")
            .update()
    }
}
