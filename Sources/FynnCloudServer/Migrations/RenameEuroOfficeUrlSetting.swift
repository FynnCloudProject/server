import Fluent
import FluentSQL

/// Renames the legacy `euroOfficeUrl` app setting key to the generic `documentServerUrl`.
struct RenameEuroOfficeUrlSetting: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("UPDATE app_settings SET key = 'documentServerUrl' WHERE key = 'euroOfficeUrl'").run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("UPDATE app_settings SET key = 'euroOfficeUrl' WHERE key = 'documentServerUrl'").run()
    }
}
