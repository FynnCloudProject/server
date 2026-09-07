import Fluent
import FluentSQL
import SQLKit

struct AddFavoritesAndSharesToSyncTriggers: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" else {
            database.logger.warning("Sync triggers for favorites and shares require PostgreSQL – skipping")
            return
        }

        // 1. Trigger for user_favorites
        try await sql.raw("""
            CREATE OR REPLACE FUNCTION fn_user_favorites_sync_trigger()
            RETURNS TRIGGER AS $$
            DECLARE
                v_file file_metadata%ROWTYPE;
            BEGIN
                IF TG_OP = 'INSERT' THEN
                    SELECT * INTO v_file FROM file_metadata WHERE id = NEW.file_id;
                    IF FOUND THEN
                        INSERT INTO sync_logs (
                            id, user_id, file_id, seq, event_type, content_updated,
                            filename, is_directory, size, hash, parent_id, last_modified,
                            created_at
                        ) VALUES (
                            gen_random_uuid(),
                            NEW.user_id,
                            NEW.file_id,
                            nextval('sync_seq'),
                            'favorite',
                            FALSE,
                            v_file.filename,
                            v_file.is_directory,
                            v_file.size,
                            v_file.hash,
                            v_file.parent_id,
                            v_file.last_modified,
                            NOW()
                        );
                    END IF;
                    RETURN NEW;
                ELSIF TG_OP = 'DELETE' THEN
                    SELECT * INTO v_file FROM file_metadata WHERE id = OLD.file_id;
                    IF FOUND THEN
                        INSERT INTO sync_logs (
                            id, user_id, file_id, seq, event_type, content_updated,
                            filename, is_directory, size, hash, parent_id, last_modified,
                            created_at
                        ) VALUES (
                            gen_random_uuid(),
                            OLD.user_id,
                            OLD.file_id,
                            nextval('sync_seq'),
                            'unfavorite',
                            FALSE,
                            v_file.filename,
                            v_file.is_directory,
                            v_file.size,
                            v_file.hash,
                            v_file.parent_id,
                            v_file.last_modified,
                            NOW()
                        );
                    END IF;
                    RETURN OLD;
                END IF;
                RETURN NULL;
            END;
            $$ LANGUAGE plpgsql;
            """).run()

        try await sql.raw("DROP TRIGGER IF EXISTS trg_user_favorites_sync ON user_favorites").run()
        try await sql.raw("""
            CREATE TRIGGER trg_user_favorites_sync
            AFTER INSERT OR DELETE ON user_favorites
            FOR EACH ROW EXECUTE FUNCTION fn_user_favorites_sync_trigger()
            """).run()

        // 2. Trigger for internal_shares
        try await sql.raw("""
            CREATE OR REPLACE FUNCTION fn_internal_shares_sync_trigger()
            RETURNS TRIGGER AS $$
            DECLARE
                v_file file_metadata%ROWTYPE;
            BEGIN
                IF TG_OP = 'INSERT' THEN
                    SELECT * INTO v_file FROM file_metadata WHERE id = NEW.file_id;
                    IF FOUND THEN
                        -- SyncLog for Owner/Sharer
                        INSERT INTO sync_logs (
                            id, user_id, file_id, seq, event_type, content_updated,
                            filename, is_directory, size, hash, parent_id, last_modified, created_at
                        ) VALUES (
                            gen_random_uuid(),
                            v_file.owner_id,
                            NEW.file_id,
                            nextval('sync_seq'),
                            'share',
                            FALSE,
                            v_file.filename,
                            v_file.is_directory,
                            v_file.size,
                            v_file.hash,
                            v_file.parent_id,
                            v_file.last_modified,
                            NOW()
                        );

                        -- SyncLog for Direct Recipient
                        IF NEW.grantee_user_id IS NOT NULL AND NEW.grantee_user_id != v_file.owner_id THEN
                            INSERT INTO sync_logs (
                                id, user_id, file_id, seq, event_type, content_updated,
                                filename, is_directory, size, hash, parent_id, last_modified, created_at
                            ) VALUES (
                                gen_random_uuid(),
                                NEW.grantee_user_id,
                                NEW.file_id,
                                nextval('sync_seq'),
                                'create',
                                FALSE,
                                v_file.filename,
                                v_file.is_directory,
                                v_file.size,
                                v_file.hash,
                                NULL,
                                v_file.last_modified,
                                NOW()
                            );
                        -- SyncLog Fan-out for Group Recipients
                        ELSIF NEW.grantee_group_id IS NOT NULL THEN
                            INSERT INTO sync_logs (
                                id, user_id, file_id, seq, event_type, content_updated,
                                filename, is_directory, size, hash, parent_id, last_modified, created_at
                            )
                            SELECT
                                gen_random_uuid(),
                                ug.user_id,
                                NEW.file_id,
                                nextval('sync_seq'),
                                'create',
                                FALSE,
                                v_file.filename,
                                v_file.is_directory,
                                v_file.size,
                                v_file.hash,
                                NULL,
                                v_file.last_modified,
                                NOW()
                            FROM user_groups ug
                            WHERE ug.group_id = NEW.grantee_group_id AND ug.user_id != v_file.owner_id;
                        END IF;
                    END IF;
                    RETURN NEW;

                ELSIF TG_OP = 'DELETE' THEN
                    SELECT * INTO v_file FROM file_metadata WHERE id = OLD.file_id;
                    IF FOUND THEN
                        -- SyncLog for Owner/Sharer
                        INSERT INTO sync_logs (
                            id, user_id, file_id, seq, event_type, content_updated,
                            filename, is_directory, size, hash, parent_id, last_modified, created_at
                        ) VALUES (
                            gen_random_uuid(),
                            v_file.owner_id,
                            OLD.file_id,
                            nextval('sync_seq'),
                            'unshare',
                            FALSE,
                            v_file.filename,
                            v_file.is_directory,
                            v_file.size,
                            v_file.hash,
                            v_file.parent_id,
                            v_file.last_modified,
                            NOW()
                        );

                        -- SyncLog for Direct Recipient (remove from working set)
                        IF OLD.grantee_user_id IS NOT NULL AND OLD.grantee_user_id != v_file.owner_id THEN
                            INSERT INTO sync_logs (
                                id, user_id, file_id, seq, event_type, content_updated,
                                filename, is_directory, size, hash, parent_id, last_modified, created_at
                            ) VALUES (
                                gen_random_uuid(),
                                OLD.grantee_user_id,
                                OLD.file_id,
                                nextval('sync_seq'),
                                'delete',
                                FALSE,
                                v_file.filename,
                                v_file.is_directory,
                                v_file.size,
                                v_file.hash,
                                NULL,
                                v_file.last_modified,
                                NOW()
                            );
                        -- SyncLog Fan-out for Group Recipients (remove from working set)
                        ELSIF OLD.grantee_group_id IS NOT NULL THEN
                            INSERT INTO sync_logs (
                                id, user_id, file_id, seq, event_type, content_updated,
                                filename, is_directory, size, hash, parent_id, last_modified, created_at
                            )
                            SELECT
                                gen_random_uuid(),
                                ug.user_id,
                                OLD.file_id,
                                nextval('sync_seq'),
                                'delete',
                                FALSE,
                                v_file.filename,
                                v_file.is_directory,
                                v_file.size,
                                v_file.hash,
                                NULL,
                                v_file.last_modified,
                                NOW()
                            FROM user_groups ug
                            WHERE ug.group_id = OLD.grantee_group_id AND ug.user_id != v_file.owner_id;
                        END IF;
                    END IF;
                    RETURN OLD;

                ELSIF TG_OP = 'UPDATE' THEN
                    SELECT * INTO v_file FROM file_metadata WHERE id = NEW.file_id;
                    IF FOUND THEN
                        IF NEW.grantee_user_id IS NOT NULL AND NEW.grantee_user_id != v_file.owner_id THEN
                            INSERT INTO sync_logs (
                                id, user_id, file_id, seq, event_type, content_updated,
                                filename, is_directory, size, hash, parent_id, last_modified, created_at
                            ) VALUES (
                                gen_random_uuid(),
                                NEW.grantee_user_id,
                                NEW.file_id,
                                nextval('sync_seq'),
                                'modify',
                                FALSE,
                                v_file.filename,
                                v_file.is_directory,
                                v_file.size,
                                v_file.hash,
                                NULL,
                                v_file.last_modified,
                                NOW()
                            );
                        ELSIF NEW.grantee_group_id IS NOT NULL THEN
                            INSERT INTO sync_logs (
                                id, user_id, file_id, seq, event_type, content_updated,
                                filename, is_directory, size, hash, parent_id, last_modified, created_at
                            )
                            SELECT
                                gen_random_uuid(),
                                ug.user_id,
                                NEW.file_id,
                                nextval('sync_seq'),
                                'modify',
                                FALSE,
                                v_file.filename,
                                v_file.is_directory,
                                v_file.size,
                                v_file.hash,
                                NULL,
                                v_file.last_modified,
                                NOW()
                            FROM user_groups ug
                            WHERE ug.group_id = NEW.grantee_group_id AND ug.user_id != v_file.owner_id;
                        END IF;
                    END IF;
                    RETURN NEW;
                END IF;
                RETURN NULL;
            END;
            $$ LANGUAGE plpgsql;
            """).run()

        try await sql.raw("DROP TRIGGER IF EXISTS trg_internal_shares_sync ON internal_shares").run()
        try await sql.raw("""
            CREATE TRIGGER trg_internal_shares_sync
            AFTER INSERT OR UPDATE OR DELETE ON internal_shares
            FOR EACH ROW EXECUTE FUNCTION fn_internal_shares_sync_trigger()
            """).run()

        // 3. Trigger for share_links (public link shares)
        try await sql.raw("""
            CREATE OR REPLACE FUNCTION fn_share_links_sync_trigger()
            RETURNS TRIGGER AS $$
            DECLARE
                v_file file_metadata%ROWTYPE;
            BEGIN
                IF TG_OP = 'INSERT' THEN
                    SELECT * INTO v_file FROM file_metadata WHERE id = NEW.file_id;
                    IF FOUND THEN
                        INSERT INTO sync_logs (
                            id, user_id, file_id, seq, event_type, content_updated,
                            filename, is_directory, size, hash, parent_id, last_modified, created_at
                        ) VALUES (
                            gen_random_uuid(),
                            NEW.created_by,
                            NEW.file_id,
                            nextval('sync_seq'),
                            'share',
                            FALSE,
                            v_file.filename,
                            v_file.is_directory,
                            v_file.size,
                            v_file.hash,
                            v_file.parent_id,
                            v_file.last_modified,
                            NOW()
                        );
                    END IF;
                    RETURN NEW;
                ELSIF TG_OP = 'DELETE' THEN
                    SELECT * INTO v_file FROM file_metadata WHERE id = OLD.file_id;
                    IF FOUND THEN
                        INSERT INTO sync_logs (
                            id, user_id, file_id, seq, event_type, content_updated,
                            filename, is_directory, size, hash, parent_id, last_modified, created_at
                        ) VALUES (
                            gen_random_uuid(),
                            OLD.created_by,
                            OLD.file_id,
                            nextval('sync_seq'),
                            'unshare',
                            FALSE,
                            v_file.filename,
                            v_file.is_directory,
                            v_file.size,
                            v_file.hash,
                            v_file.parent_id,
                            v_file.last_modified,
                            NOW()
                        );
                    END IF;
                    RETURN OLD;
                END IF;
                RETURN NULL;
            END;
            $$ LANGUAGE plpgsql;
            """).run()

        try await sql.raw("DROP TRIGGER IF EXISTS trg_share_links_sync ON share_links").run()
        try await sql.raw("""
            CREATE TRIGGER trg_share_links_sync
            AFTER INSERT OR DELETE ON share_links
            FOR EACH ROW EXECUTE FUNCTION fn_share_links_sync_trigger()
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" else { return }

        try await sql.raw("DROP TRIGGER IF EXISTS trg_share_links_sync ON share_links").run()
        try await sql.raw("DROP FUNCTION IF EXISTS fn_share_links_sync_trigger()").run()

        try await sql.raw("DROP TRIGGER IF EXISTS trg_internal_shares_sync ON internal_shares").run()
        try await sql.raw("DROP FUNCTION IF EXISTS fn_internal_shares_sync_trigger()").run()

        try await sql.raw("DROP TRIGGER IF EXISTS trg_user_favorites_sync ON user_favorites").run()
        try await sql.raw("DROP FUNCTION IF EXISTS fn_user_favorites_sync_trigger()").run()
    }
}
