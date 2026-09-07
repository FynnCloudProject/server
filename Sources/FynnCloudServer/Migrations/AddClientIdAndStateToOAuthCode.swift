import Fluent
import SQLKit

struct AddClientIdAndStateToOAuthCode: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // Delete all existing codes as they are invalid without client_id and they are ephemeral anyway
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DELETE FROM oauth_codes").run()
        }

        try await database.schema("oauth_codes")
            .field("client_id", .string, .required)
            .update()

        try await database.schema("oauth_codes")
            .field("state", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("oauth_codes")
            .deleteField("state")
            .update()

        try await database.schema("oauth_codes")
            .deleteField("client_id")
            .update()
    }
}
