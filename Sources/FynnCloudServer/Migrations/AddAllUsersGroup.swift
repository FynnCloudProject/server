import Fluent
import SQLKit

struct AddAllUsersGroup: AsyncMigration {
    func prepare(on database: any Database) async throws {
        if database is any SQLDatabase {
            do {
                try await database.schema("groups")
                    .field("system_key", .string)
                    .update()
            } catch {
                // Column likely already exists from CreateGroups, ignore error
            }
        } else {
            try await database.schema("groups")
                .field("system_key", .string)
                .update()
        }

        // Seed "All Users" system group if it doesn't already exist
        if let sql = database as? any SQLDatabase {
            let existingAllUsers = try await sql.raw("SELECT id FROM groups WHERE system_key = 'all_users' LIMIT 1").first()
            if existingAllUsers == nil {
                var standardTier = try await StorageTier.query(on: database)
                    .filter(\.$limitBytes == 5 * 1024 * 1024 * 1024)
                    .first()
                if standardTier == nil {
                    standardTier = try await StorageTier.query(on: database)
                        .sort(\.$limitBytes)
                        .first()
                }
                let tierID = standardTier?.id
                try await sql.raw("INSERT INTO groups (name, is_admin, system_key, tier_id) VALUES ('All Users', false, 'all_users', \(bind: tierID))").run()
            }

            // Ensure admin group has systemKey = "admin"
            try await sql.raw("UPDATE groups SET system_key = 'admin' WHERE is_admin = true AND system_key IS NULL").run()
        }
    }

    func revert(on database: any Database) async throws {
        try await Group.query(on: database)
            .filter(\.$systemKey == "all_users")
            .delete()

        try await database.schema("groups")
            .deleteField("system_key")
            .update()
    }
}
