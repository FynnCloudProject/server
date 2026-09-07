import Fluent
import FluentSQL
import SQLKit

struct DropSyncTriggersMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" else {
            return
        }

        // Drop all triggers on user_favorites, internal_shares, share_links, and file_metadata
        try await sql.raw("DROP TRIGGER IF EXISTS trg_user_favorites_sync ON user_favorites").run()
        try await sql.raw("DROP FUNCTION IF EXISTS fn_user_favorites_sync_trigger()").run()

        try await sql.raw("DROP TRIGGER IF EXISTS trg_internal_shares_sync ON internal_shares").run()
        try await sql.raw("DROP FUNCTION IF EXISTS fn_internal_shares_sync_trigger()").run()

        try await sql.raw("DROP TRIGGER IF EXISTS trg_share_links_sync ON share_links").run()
        try await sql.raw("DROP FUNCTION IF EXISTS fn_share_links_sync_trigger()").run()

        try await sql.raw("DROP TRIGGER IF EXISTS trg_file_metadata_sync ON file_metadata").run()
        try await sql.raw("DROP FUNCTION IF EXISTS fn_sync_log_trigger()").run()
    }

    func revert(on database: any Database) async throws {
        // No-op revert since sync tracking has moved to SyncLogService
    }
}
