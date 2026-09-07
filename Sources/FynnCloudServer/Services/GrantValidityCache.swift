import Foundation
@preconcurrency import Redis
import Vapor

/// Redis cache for the per-request `OAuthGrant.find` existence check in `UserPayloadAuthenticator`,
/// which otherwise runs a Postgres query on every authenticated request.
///
/// Security model: this cache can only ever make a revoked grant *appear valid* for a short
/// window, never the reverse (a cache miss/error always falls back to the real database check -
/// fail secure, not fail open). Every code path that deletes an `OAuthGrant` MUST call `invalidate`
/// for the affected grant id(s) so revocation is felt immediately; the TTL below is only a backstop
/// for a call site that misses that.
enum GrantValidityCache: Sendable {
    private static let ttlSeconds: Int64 = 30

    private static func key(_ grantID: UUID) -> RedisKey {
        RedisKey("grant:valid:\(grantID.uuidString)")
    }

    /// `true` = confirmed valid by a fresh cache hit. `nil` = unknown (miss or Redis error) - caller
    /// must check the database.
    static func cachedValid(grantID: UUID, on redis: any RedisClient) async -> Bool? {
        guard let value = try? await redis.get(key(grantID), as: String.self).get(), value == "1"
        else {
            return nil
        }
        return true
    }

    /// Call only after confirming the grant exists in the database.
    static func markValid(grantID: UUID, on redis: any RedisClient) {
        let redisKey = key(grantID)
        _ = redis.set(redisKey, to: "1").flatMap { _ in
            redis.expire(redisKey, after: .seconds(ttlSeconds))
        }
    }

    static func invalidate(grantID: UUID, on redis: any RedisClient) async {
        _ = try? await redis.delete(key(grantID)).get()
    }

    static func invalidate(grantIDs: [UUID], on redis: any RedisClient) async {
        guard !grantIDs.isEmpty else { return }
        _ = try? await redis.delete(grantIDs.map { key($0) }).get()
    }
}
