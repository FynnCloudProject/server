import Fluent
import FluentSQL
import Queues
import Redis
import SQLKit
import Vapor

/// Recalculates each user's `current_storage_usage` from actual file sizes in the database.
/// Fixes drift caused by partial failures in upload/delete operations.
struct QuotaRecalculationJob: AsyncScheduledJob {
    func run(context: QueueContext) async throws {
        let app = context.application
        let db = app.db

        guard let sql = db as? any SQLDatabase else {
            app.logger.warning("QuotaRecalculationJob: Database does not support raw SQL")
            return
        }

        try await sql.raw("""
            UPDATE users SET current_storage_usage = COALESCE((
                SELECT SUM(size) FROM file_metadata
                WHERE file_metadata.owner_id = users.id
                AND file_metadata.is_directory = false
                AND file_metadata.deleted_at IS NULL
            ), 0)
            """).run()

        app.logger.scoped(to: .scheduler).info("Quota recalculation completed")

        await app.recordJobLastRun(id: "quota_recalculation")
    }
}

extension Application {
    func recordJobLastRun(id: String) async {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        do {
            _ = try await self.redis.set(RedisKey("scheduled_job:\(id):last_run"), to: timestamp).get()
        } catch {
            // Best-effort marker: only the admin "last run" display depends on it.
            self.logger.scoped(to: .scheduler).warning(
                "Failed to record scheduled job last-run marker",
                metadata: ["job": .string(id), "error": .string("\(error)")])
        }
    }
}

/// Flushes session access timestamps and IPs buffered in Redis to the PostgreSQL database.
struct SessionLastAccessFlushJob: AsyncScheduledJob {
    func run(context: QueueContext) async throws {
        let app = context.application

        let activeKey = RedisKey("session_activity")

        let entries: [String: String] = (try? await app.redis.hgetall(from: activeKey).map { dict in
            var result: [String: String] = [:]
            for (k, v) in dict {
                if let str = v.string {
                    result[k] = str
                }
            }
            return result
        }.get()) ?? [:]

        guard !entries.isEmpty else { return }

        let decoder = JSONDecoder()
        var updateCount = 0
        for (_, jsonString) in entries {
            guard let data = jsonString.data(using: .utf8),
                  let buffer = try? decoder.decode(SessionActivityBuffer.self, from: data) else { continue }

            let accessDate = Date(timeIntervalSince1970: Double(buffer.timestamp))

            let query = OAuthGrant.query(on: app.db)
                .filter(\.$id == buffer.grantID)
                .group(.or) { group in
                    group.filter(\.$lastUsedAt == nil)
                    group.filter(\.$lastUsedAt < accessDate)
                }
                .set(\.$lastUsedAt, to: accessDate)

            if let latestIP = buffer.ipAddress {
                query.set(\.$ipAddress, to: latestIP)
            }

            try await query.update()
            updateCount += 1
        }

        if updateCount > 0 {
            app.logger.scoped(to: .scheduler).debug("Flushed session activity records", metadata: ["count": .stringConvertible(updateCount)])
        }
    }
}

/// Cleans up expired OAuth grants and stale sessions.
/// Deletes grants where lastRotatedAt (or createdAt if never rotated) is older than 30 days.
struct ExpiredTokenCleanupJob: AsyncScheduledJob {
    func run(context: QueueContext) async throws {
        let app = context.application
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()

        func filtered(_ query: QueryBuilder<OAuthGrant>) -> QueryBuilder<OAuthGrant> {
            query.group(.or) { group in
                group.filter(\.$lastRotatedAt < cutoff)
                group.group(.and) { sub in
                    sub.filter(\.$lastRotatedAt == nil)
                    sub.filter(\.$createdAt < cutoff)
                }
            }
        }

        let expiredGrantIDs = try await filtered(OAuthGrant.query(on: app.db)).all(\.$id)
        try await filtered(OAuthGrant.query(on: app.db)).delete()

        await GrantValidityCache.invalidate(grantIDs: expiredGrantIDs, on: app.redis)
        await SessionActivityService.remove(grantIDs: expiredGrantIDs, on: app.redis)

        app.logger.scoped(to: .scheduler).info("Expired token cleanup completed")

        await app.recordJobLastRun(id: "expired_token_cleanup")
    }
}

/// Permanently deletes files and folders that have been in the trash for longer than the configured
/// retention period (`AppSettings.TrashRetentionDays`, default 30 days).
struct TrashCleanupJob: AsyncScheduledJob {
    func run(context: QueueContext) async throws {
        let app = context.application
        let eventLoop = app.eventLoopGroup.next()
        let storageService = StorageService(
            provider: app.fileStorage,
            eventLoop: eventLoop
        )
        let fileService = FileService(
            FileServiceContext(
                db: app.db,
                logger: app.logger,
                storage: storageService,
                redis: app.redis
            )
        )
        let retentionDays = try await app.settings.get(AppSettings.TrashRetentionDays.self)
        await fileService.cleanupExpiredTrash(days: retentionDays)

        await app.recordJobLastRun(id: "trash_cleanup")
    }
}

/// Proactively imports LDAP group catalog into local groups.
struct LDAPGroupSyncJob: AsyncScheduledJob {
    func run(context: QueueContext) async throws {
        let app = context.application
        let ssoConfig = app.ssoConfig

        guard ssoConfig.ldap.enabled else {
            app.logger.scoped(to: .scheduler).debug("LDAPGroupSyncJob skipped: LDAP is disabled")
            return
        }

        let groups = LDAPGroupCatalogSyncService(app: app, db: app.db, logger: app.logger)
        _ = try await groups.run()
        await app.recordJobLastRun(id: "ldap_group_sync")
    }
}

/// Proactively syncs LDAP user catalog into local users.
struct LDAPUserSyncJob: AsyncScheduledJob {
    func run(context: QueueContext) async throws {
        let app = context.application
        let ssoConfig = app.ssoConfig

        guard ssoConfig.ldap.enabled else {
            app.logger.scoped(to: .scheduler).debug("LDAPUserSyncJob skipped: LDAP is disabled")
            return
        }

        let users = LDAPUserCatalogSyncService(app: app, db: app.db, logger: app.logger)
        _ = try await users.run()
        await app.recordJobLastRun(id: "ldap_user_sync")
    }
}

/// Proactively syncs the LDAP directory on a schedule so groups and users exist locally before
/// their first login (Nextcloud-style pre-sync). Runs groups first (so user provisioning can
/// import/auto-match against fresh groups), then users. Each half is gated by its own setting:
/// groups by `SSO_GROUP_IMPORT`, users by `SSO_USER_SYNC`.
struct LDAPDirectorySyncJob: AsyncScheduledJob {
    func run(context: QueueContext) async throws {
        let app = context.application
        let ssoConfig = app.ssoConfig

        guard ssoConfig.ldap.enabled else { return }
        guard ssoConfig.groupImport || ssoConfig.userSync else { return }

        if ssoConfig.groupImport {
            try await LDAPGroupSyncJob().run(context: context)
        }

        if ssoConfig.userSync {
            try await LDAPUserSyncJob().run(context: context)
        }
    }
}

/// Prunes old sync log entries that all active devices have already processed.
/// First evicts stale device cursors (devices that haven't synced in 90 days),
/// then deletes logs older than 365 days whose `seq` is below the minimum
/// acknowledged cursor across the user's remaining active devices.
struct SyncLogPruneJob: AsyncScheduledJob {
    /// Logs older than this are eligible for pruning (if all devices have ack'd past them).
    private static let logRetentionDays = 365
    /// Cursors for devices that haven't synced in this many days are evicted,
    /// preventing abandoned devices from blocking log pruning indefinitely.
    private static let cursorStaleDays = 90

    func run(context: QueueContext) async throws {
        let app = context.application
        let db = app.db

        guard let sql = db as? any SQLDatabase else {
            app.logger.warning("SyncLogPruneJob: Database does not support raw SQL")
            return
        }

        // Step 1: Evict stale device cursors that haven't checked in
        let cursorCutoff = Calendar.current.date(
            byAdding: .day, value: -Self.cursorStaleDays, to: Date())!
        try await sql.raw("""
            DELETE FROM sync_cursors
            WHERE last_synced_at < \(bind: cursorCutoff)
        """).run()

        // Step 2: Prune old logs where all remaining active devices have ack'd past them
        let logCutoff = Calendar.current.date(
            byAdding: .day, value: -Self.logRetentionDays, to: Date())!
        try await sql.raw("""
            DELETE FROM sync_logs
            WHERE created_at < \(bind: logCutoff)
              AND seq <= COALESCE(
                (SELECT MIN(last_seq) FROM sync_cursors
                 WHERE sync_cursors.user_id = sync_logs.user_id),
                sync_logs.seq
              )
        """).run()

        app.logger.scoped(to: .scheduler).info(
            "Sync log prune completed",
            metadata: [
                "logRetentionDays": .stringConvertible(Self.logRetentionDays),
                "cursorStaleDays": .stringConvertible(Self.cursorStaleDays),
            ]
        )

        await app.recordJobLastRun(id: "sync_log_prune")
    }
}
