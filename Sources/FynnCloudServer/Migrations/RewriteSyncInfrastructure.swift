import Fluent
import FluentSQL
import SQLKit

struct RewriteSyncInfrastructure: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" else {
            database.logger.warning("Sync trigger migration requires PostgreSQL – skipping")
            return
        }

        try await sql.raw("CREATE SEQUENCE IF NOT EXISTS sync_seq").run()

        try await database.schema("sync_logs").delete()

        try await database.schema("sync_logs")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("file_id", .uuid, .required)
            .field("seq", .int64, .required)
            .field("event_type", .string, .required)
            .field("content_updated", .bool, .required, .custom("DEFAULT FALSE"))
            .field("created_at", .datetime, .custom("DEFAULT NOW()"))
            .unique(on: "user_id", "seq")
            .create()

        // Index for the polling query: WHERE user_id = ? AND seq > ? ORDER BY seq
        try await sql.raw("""
            CREATE INDEX idx_sync_logs_user_seq ON sync_logs (user_id, seq)
            """).run()

        try await database.schema("sync_cursors")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("device_id", .string, .required)
            .field("device_name", .string)
            .field("last_seq", .int64, .required, .custom("DEFAULT 0"))
            .field("last_synced_at", .datetime, .required, .custom("DEFAULT NOW()"))
            .field("created_at", .datetime, .custom("DEFAULT NOW()"))
            .unique(on: "user_id", "device_id")
            .create()

        try await sql.raw("""
            CREATE OR REPLACE FUNCTION fn_sync_log_trigger()
            RETURNS TRIGGER AS $$
            DECLARE
                v_file_id UUID;
                v_user_id UUID;
                v_event_type TEXT;
                v_content_updated BOOLEAN := FALSE;
            BEGIN
                IF TG_OP = 'DELETE' THEN
                    v_file_id := OLD.id;
                    v_user_id := OLD.owner_id;
                    -- If deleted_at was already set, this is a hard delete from trash
                    v_event_type := 'delete';
                ELSIF TG_OP = 'INSERT' THEN
                    v_file_id := NEW.id;
                    v_user_id := NEW.owner_id;
                    v_event_type := 'upsert';
                    v_content_updated := TRUE;
                ELSE
                    -- UPDATE
                    v_file_id := NEW.id;
                    v_user_id := NEW.owner_id;

                    -- Detect soft-delete (trash)
                    IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
                        v_event_type := 'trash';
                    -- Detect restore from trash
                    ELSIF OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS NULL THEN
                        v_event_type := 'upsert';
                    ELSE
                        v_event_type := 'upsert';
                    END IF;

                    -- Content changed if size or last_modified changed
                    IF OLD.size IS DISTINCT FROM NEW.size
                       OR OLD.last_modified IS DISTINCT FROM NEW.last_modified THEN
                        v_content_updated := TRUE;
                    END IF;
                END IF;

                INSERT INTO sync_logs (id, user_id, file_id, seq, event_type, content_updated, created_at)
                VALUES (
                    gen_random_uuid(),
                    v_user_id,
                    v_file_id,
                    nextval('sync_seq'),
                    v_event_type,
                    v_content_updated,
                    NOW()
                );

                RETURN COALESCE(NEW, OLD);
            END;
            $$ LANGUAGE plpgsql
            """).run()

        try await sql.raw("""
            CREATE TRIGGER trg_file_metadata_sync
            AFTER INSERT OR UPDATE OR DELETE ON file_metadata
            FOR EACH ROW EXECUTE FUNCTION fn_sync_log_trigger()
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" else { return }

        try await sql.raw("DROP TRIGGER IF EXISTS trg_file_metadata_sync ON file_metadata").run()
        try await sql.raw("DROP FUNCTION IF EXISTS fn_sync_log_trigger()").run()
        try await database.schema("sync_cursors").delete()
        try await database.schema("sync_logs").delete()
        try await sql.raw("DROP SEQUENCE IF EXISTS sync_seq").run()

        try await database.schema("sync_logs")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("file_id", .uuid, .required)
            .field("seq", .int64, .required)
            .field("event_type", .string, .required)
            .field("content_updated", .bool, .required, .custom("DEFAULT FALSE"))
            .field("created_at", .datetime)
            .unique(on: "user_id", "seq")
            .create()
    }
}
