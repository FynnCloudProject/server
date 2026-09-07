import Fluent
import FluentSQL
import SQLKit

struct OverhaulSyncInfrastructure: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("sync_logs").field("filename", .string).update()
        try await database.schema("sync_logs").field("is_directory", .bool).update()
        try await database.schema("sync_logs").field("size", .int64).update()
        try await database.schema("sync_logs").field("hash", .string).update()
        try await database.schema("sync_logs").field("parent_id", .uuid).update()
        try await database.schema("sync_logs").field("last_modified", .datetime).update()
        try await database.schema("sync_logs").field("old_filename", .string).update()
        try await database.schema("sync_logs").field("old_parent_id", .uuid).update()

        guard let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" else {
            return
        }

        try await sql.raw("""
            CREATE OR REPLACE FUNCTION fn_sync_log_trigger()
            RETURNS TRIGGER AS $$
            DECLARE
                v_file_id UUID;
                v_user_id UUID;
                v_event_type TEXT;
                v_content_updated BOOLEAN := FALSE;
                v_filename TEXT;
                v_is_dir BOOLEAN;
                v_size BIGINT;
                v_hash TEXT;
                v_parent_id UUID;
                v_last_modified TIMESTAMPTZ;
                v_old_filename TEXT := NULL;
                v_old_parent_id UUID := NULL;
            BEGIN
                IF TG_OP = 'DELETE' THEN
                    v_file_id := OLD.id;
                    v_user_id := OLD.owner_id;
                    v_event_type := 'delete';
                    v_filename := OLD.filename;
                    v_is_dir := OLD.is_directory;
                    v_size := OLD.size;
                    v_hash := OLD.hash;
                    v_parent_id := OLD.parent_id;
                    v_last_modified := OLD.last_modified;
                ELSIF TG_OP = 'INSERT' THEN
                    v_file_id := NEW.id;
                    v_user_id := NEW.owner_id;
                    v_event_type := 'create';
                    v_content_updated := TRUE;
                    v_filename := NEW.filename;
                    v_is_dir := NEW.is_directory;
                    v_size := NEW.size;
                    v_hash := NEW.hash;
                    v_parent_id := NEW.parent_id;
                    v_last_modified := NEW.last_modified;
                ELSE
                    -- UPDATE
                    v_file_id := NEW.id;
                    v_user_id := NEW.owner_id;
                    v_filename := NEW.filename;
                    v_is_dir := NEW.is_directory;
                    v_size := NEW.size;
                    v_hash := NEW.hash;
                    v_parent_id := NEW.parent_id;
                    v_last_modified := NEW.last_modified;

                    -- Detect soft-delete (trash)
                    IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
                        v_event_type := 'trash';
                    -- Detect restore from trash
                    ELSIF OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS NULL THEN
                        v_event_type := 'restore';
                    -- Detect Move and Rename simultaneously
                    ELSIF OLD.parent_id IS DISTINCT FROM NEW.parent_id AND OLD.filename IS DISTINCT FROM NEW.filename THEN
                        v_event_type := 'move';
                        v_old_parent_id := OLD.parent_id;
                        v_old_filename := OLD.filename;
                    -- Detect Move
                    ELSIF OLD.parent_id IS DISTINCT FROM NEW.parent_id THEN
                        v_event_type := 'move';
                        v_old_parent_id := OLD.parent_id;
                    -- Detect Rename
                    ELSIF OLD.filename IS DISTINCT FROM NEW.filename THEN
                        v_event_type := 'rename';
                        v_old_filename := OLD.filename;
                    -- Detect Content / Modification time change
                    ELSIF OLD.size IS DISTINCT FROM NEW.size
                       OR OLD.hash IS DISTINCT FROM NEW.hash
                       OR OLD.last_modified IS DISTINCT FROM NEW.last_modified THEN
                        v_event_type := 'modify';
                        v_content_updated := TRUE;
                    ELSE
                        -- Non-filesystem updates only (e.g. is_favorite, has_thumbnail, is_shared, ancestor_ids, updated_at)
                        -- Skip sync log entry creation!
                        RETURN NEW;
                    END IF;
                END IF;

                INSERT INTO sync_logs (
                    id, user_id, file_id, seq, event_type, content_updated,
                    filename, is_directory, size, hash, parent_id, last_modified,
                    old_filename, old_parent_id, created_at
                )
                VALUES (
                    gen_random_uuid(),
                    v_user_id,
                    v_file_id,
                    nextval('sync_seq'),
                    v_event_type,
                    v_content_updated,
                    v_filename,
                    v_is_dir,
                    v_size,
                    v_hash,
                    v_parent_id,
                    v_last_modified,
                    v_old_filename,
                    v_old_parent_id,
                    NOW()
                );

                RETURN COALESCE(NEW, OLD);
            END;
            $$ LANGUAGE plpgsql;
            """).run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("sync_logs").deleteField("filename").update()
        try await database.schema("sync_logs").deleteField("is_directory").update()
        try await database.schema("sync_logs").deleteField("size").update()
        try await database.schema("sync_logs").deleteField("hash").update()
        try await database.schema("sync_logs").deleteField("parent_id").update()
        try await database.schema("sync_logs").deleteField("last_modified").update()
        try await database.schema("sync_logs").deleteField("old_filename").update()
        try await database.schema("sync_logs").deleteField("old_parent_id").update()
    }
}
