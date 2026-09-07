import Fluent
import FluentSQL
@preconcurrency import Redis
import SQLKit
import Vapor

/// What a reservation is being held for. It is encoded into the Redis field name, so an orphaned
/// hold in `quota:pending:{userID}` can be traced back to the write that leaked it.
enum QuotaHold: Sendable {
    case upload(fileID: UUID)
    case update(fileID: UUID)
    case create(fileID: UUID)
    case copy(fileID: UUID)
    case multipart(sessionID: UUID)

    var label: String {
        switch self {
        case .upload(let id): return "upload:\(id.uuidString)"
        case .update(let id): return "update:\(id.uuidString)"
        case .create(let id): return "create:\(id.uuidString)"
        case .copy(let id): return "copy:\(id.uuidString)"
        case .multipart(let id): return "multipart:\(id.uuidString)"
        }
    }
}

/// A block of bytes admitted against a user's quota but not yet written to the durable counter.
struct Reservation: Sendable, Codable {
    /// The Redis hash field, `<purpose>:<subject id>:<nonce>`. The nonce is what makes it unique:
    /// two concurrent writes to the same file would otherwise share a field, and the second
    /// would silently replace the first's hold instead of adding to it.
    let id: String
    let userID: UUID
    let bytes: Int64

    init(_ hold: QuotaHold, userID: UUID, bytes: Int64) {
        self.id = "\(hold.label):\(UUID().uuidString)"
        self.userID = userID
        self.bytes = bytes
    }

    /// Rebuilds a reservation from an id carried across a request boundary (an upload token or a
    /// stored multipart session).
    init(id: String, userID: UUID, bytes: Int64) {
        self.id = id
        self.userID = userID
        self.bytes = bytes
    }
}

/// A user's storage picture: what is on disk (`committed`) plus what in-flight writes have
/// already been admitted for (`pending`). Only `committed` is ever reported to the user.
struct QuotaUsage: Sendable {
    let committed: Int64
    let pending: Int64
    let limit: Int64
}

/// Storage accounting in two tiers.
///
/// - Committed usage (`users.current_storage_usage`) is durable and authoritative. It is written
///   exactly once per write, at commit, with the real byte count.
/// - Pending usage lives only in Redis. Every in-flight write reserves its bytes *before* the
///   first byte is stored and drops the reservation when it commits or fails. Each hold carries
///   its own expiry, so a reservation leaked by a crashed server stops counting on its own.
///
/// There are deliberately no compensating decrements: nothing is added to the durable counter
/// that later has to be taken back.
struct QuotaService: Sendable {
    let context: FileServiceContext

    init(_ context: FileServiceContext) { self.context = context }

    private var logger: Logger { context.logger }
    private var redis: any RedisClient { context.redis }

    /// Outstanding reservations for a user.
    /// Field = `<purpose>:<subject id>:<nonce>`, value = `<bytes>:<expiresAt epoch seconds>`.
    /// Flat scalars rather than session records, because the admission script has to sum them.
    static func pendingKey(userID: UUID) -> RedisKey {
        RedisKey("quota:pending:\(userID.uuidString)")
    }

    /// Redis only gained per-field hash TTLs in 7.4, so each hold's expiry rides in its value.
    /// The reader skips expired holds and the admission script prunes them.
    private static func decodeHold(_ raw: String) -> (bytes: Int64, expiresAt: Int64)? {
        let parts = raw.split(separator: ":")
        guard parts.count == 2, let bytes = Int64(parts[0]), let expiresAt = Int64(parts[1])
        else { return nil }
        return (bytes, expiresAt)
    }

    // MARK: - Limits and usage

    /// The durable half, in one round trip. This is on the admission hot path and `copyNode` calls
    /// it per file, so it must not fan out into several queries.
    private func durable(for userID: UUID) async throws -> (committed: Int64, limit: Int64) {
        let sql = try context.requireSQL()

        let row = try await sql.raw(
            """
                SELECT
                    u.current_storage_usage AS committed,
                    ut.limit_bytes AS user_tier_limit,
                    COALESCE((
                        SELECT MAX(t.limit_bytes)
                        FROM user_groups ug
                        JOIN groups g ON ug.group_id = g.id
                        JOIN storage_tiers t ON g.tier_id = t.id
                        WHERE ug.user_id = u.id
                    ), 0) AS group_limit,
                    COALESCE((
                        SELECT MAX(t.limit_bytes)
                        FROM groups g
                        JOIN storage_tiers t ON g.tier_id = t.id
                        WHERE g.system_key = 'all_users'
                    ), 0) AS system_limit
                FROM users u
                LEFT JOIN storage_tiers ut ON u.tier_id = ut.id
                WHERE u.id = \(bind: userID)
            """
        ).first()

        guard let row else {
            throw Abort(.notFound).localized(LocalizationKeys.Error.Upload.QuotaExceeded)
        }

        let committed = try row.decode(column: "committed", as: Int64.self)
        // A tier assigned directly to the user wins outright, even when its limit is lower.
        let limit: Int64
        if let userTierLimit = try row.decode(column: "user_tier_limit", as: Int64?.self) {
            limit = userTierLimit
        } else {
            limit = Swift.max(
                try row.decode(column: "group_limit", as: Int64?.self) ?? 0,
                try row.decode(column: "system_limit", as: Int64?.self) ?? 0)
        }

        return (committed: committed, limit: limit)
    }

    func usage(for userID: UUID) async throws -> QuotaUsage {
        let durable = try await durable(for: userID)
        return QuotaUsage(
            committed: durable.committed,
            pending: try await pending(for: userID),
            limit: durable.limit)
    }

    private func pending(for userID: UUID) async throws -> Int64 {
        let now = Int64(Date().timeIntervalSince1970)
        let fields = try await redis.hgetall(from: Self.pendingKey(userID: userID)).get()
        return fields.values.reduce(0) { total, value in
            guard let hold = value.string.flatMap(Self.decodeHold), hold.expiresAt > now
            else { return total }
            return total + hold.bytes
        }
    }

    // MARK: - Reservations

    /// Sums the live reservations and admits the request only if the total still fits, in a single
    /// round trip. Splitting the read from the write reintroduces the TOCTOU that lets concurrent
    /// uploads both pass a check they should not.
    ///
    /// `now` is passed in rather than read from Redis so the script stays deterministic. Pruning is
    /// capped per call: `unpack` overflows the Lua stack past ~8000 arguments, which would make
    /// every further admission for that user fail. Expired holds are excluded from the sum whether
    /// or not they have been deleted yet, so draining them over several calls costs nothing.
    private static let admitScript = """
        local now = tonumber(ARGV[6])
        local ttl = tonumber(ARGV[5])
        local maxPrune = 100
        local pending = 0
        local expired = {}
        local entries = redis.call('HGETALL', KEYS[1])
        for i = 1, #entries, 2 do
            local separator = string.find(entries[i + 1], ':')
            local expiresAt = separator and tonumber(string.sub(entries[i + 1], separator + 1))
            if expiresAt and expiresAt > now then
                pending = pending + tonumber(string.sub(entries[i + 1], 1, separator - 1))
            elseif #expired < maxPrune then
                expired[#expired + 1] = entries[i]
            end
        end
        if #expired > 0 then redis.call('HDEL', KEYS[1], unpack(expired)) end
        if pending + tonumber(ARGV[3]) + tonumber(ARGV[2]) > tonumber(ARGV[4]) then return 0 end
        redis.call('HSET', KEYS[1], ARGV[1], ARGV[2] .. ':' .. (now + ttl))
        -- Key TTL is only a backstop for the whole hash; a shorter hold must not shorten it.
        if redis.call('TTL', KEYS[1]) < ttl then redis.call('EXPIRE', KEYS[1], ttl) end
        return 1
        """

    /// Admits `bytes` atomically and holds them in Redis. Throws 413 when they do not fit.
    func reserve(
        bytes: Int64, for hold: QuotaHold, userID: UUID, ttl: TimeInterval = UploadRules.sessionTTL
    ) async throws -> Reservation {
        let reservation = Reservation(hold, userID: userID, bytes: Swift.max(0, bytes))
        guard reservation.bytes > 0 else { return reservation }

        // Committed usage is read from the database rather than mirrored in Redis, so the database
        // stays the single source of truth for durable usage. If a commit lands between this read
        // and the script, that write's bytes are counted by neither side and this one admission
        // can be marginally lenient; the next one re-reads and corrects.
        let durable = try await durable(for: userID)

        guard
            try await admit(
                reservationID: reservation.id, bytes: reservation.bytes, userID: userID,
                committed: durable.committed, limit: durable.limit, ttl: ttl)
        else {
            throw Abort(.payloadTooLarge, reason: "Quota exceeded.").localized(
                LocalizationKeys.Error.Upload.QuotaExceeded)
        }
        return reservation
    }

    private func admit(
        reservationID: String, bytes: Int64, userID: UUID,
        committed: Int64, limit: Int64, ttl: TimeInterval
    ) async throws -> Bool {
        let arguments = [
            Self.admitScript,
            "1",
            Self.pendingKey(userID: userID).rawValue,
            reservationID,
            String(bytes),
            String(committed),
            String(limit),
            String(Swift.max(1, Int64(ttl))),
            String(Int64(Date().timeIntervalSince1970)),
        ]
        let result = try await redis.send(
            command: "EVAL", with: arguments.map { $0.convertedToRESPValue() }
        ).get()
        return (Int64(fromRESP: result) ?? 0) == 1
    }

    /// Folds the reservation into the durable counter using the real byte count.
    ///
    /// The database is written first: if the release then fails the TTL reclaims the reservation
    /// and the user is briefly over-reserved, which is the conservative direction. The reverse
    /// order would leave a window where the bytes are counted by neither tier.
    func commit(
        _ reservation: Reservation, actualBytes: Int64, on connection: (any Database)? = nil
    ) async throws {
        if actualBytes != 0 {
            try await adjust(amount: actualBytes, userID: reservation.userID, on: connection)
        }
        await release(reservation)
    }

    /// Drops the reservation. Never touches the durable counter.
    func release(_ reservation: Reservation) async {
        // A zero-byte hold was never written to Redis (empty files, no-op updates).
        guard reservation.bytes > 0 else { return }
        await release(reservationID: reservation.id, userID: reservation.userID)
    }

    func release(reservationID: String, userID: UUID) async {
        do {
            _ = try await redis.hdel(reservationID, from: Self.pendingKey(userID: userID)).get()
        } catch {
            // The reservation's TTL reclaims it; over-reserving until then is the safe direction.
            logger.warning(
                "Failed to release quota reservation",
                metadata: [
                    "user_id": .stringConvertible(userID),
                    "reservation_id": .string(reservationID),
                    "error": .string("\(error)"),
                ])
        }
    }

    /// Drops every reservation held by a user, used when their account is deleted.
    func releaseAll(userID: UUID) async {
        _ = try? await redis.delete(Self.pendingKey(userID: userID)).get()
    }

    /// Runs `body` while holding a reservation, releasing it if anything throws. The body commits
    /// on success.
    func withReservation<T>(
        bytes: Int64,
        for hold: QuotaHold,
        userID: UUID,
        ttl: TimeInterval = UploadRules.sessionTTL,
        _ body: (Reservation) async throws -> T
    ) async throws -> T {
        let reservation = try await reserve(bytes: bytes, for: hold, userID: userID, ttl: ttl)
        do {
            return try await body(reservation)
        } catch {
            await release(reservation)
            throw error
        }
    }

    // MARK: - Durable counter

    /// Durable counter only, for deletes - they have no in-flight phase.
    func releaseCommitted(
        bytes: Int64, userID: UUID, on connection: (any Database)? = nil
    ) async throws {
        guard bytes != 0 else { return }
        try await adjust(amount: -bytes, userID: userID, on: connection)
    }

    /// Signed adjustment of the durable counter, clamped at zero so a stray release cannot drive
    /// usage negative. `CASE` rather than `GREATEST` because SQLite has no `GREATEST`.
    private func adjust(
        amount: Int64, userID: UUID, on connection: (any Database)? = nil
    ) async throws {
        let sql = try context.requireSQL(connection)
        try await sql.raw(
            """
            UPDATE users
            SET current_storage_usage = CASE
                WHEN current_storage_usage + \(bind: amount) < 0 THEN 0
                ELSE current_storage_usage + \(bind: amount)
            END
            WHERE id = \(bind: userID)
            """
        ).run()
    }
}
