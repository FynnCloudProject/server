import Foundation
@preconcurrency import Redis
import Vapor

enum SessionActivityService: Sendable {
    static let key = RedisKey("session_activity")

    /// Non-blocking: Buffers the grant's latest activity timestamp and IP in Redis.
    static func record(grantID: UUID, on req: Request) {
        let nowTimestamp = Int64(Date().timeIntervalSince1970)
        let buffer = SessionActivityBuffer(
            grantID: grantID,
            timestamp: nowTimestamp,
            ipAddress: req.clientIP
        )

        if let jsonData = try? JSONEncoder().encode(buffer),
            let jsonString = String(data: jsonData, encoding: .utf8)
        {
            _ = req.redis.hset(grantID.uuidString, to: jsonString, in: key)
        }
    }

    /// Removes buffered activity for grants that no longer exist (revoked/expired/deleted), so the
    /// hash doesn't grow unbounded - call this alongside every `OAuthGrant` delete.
    static func remove(grantIDs: [UUID], on redis: any RedisClient) async {
        guard !grantIDs.isEmpty else { return }
        _ = try? await redis.hdel(grantIDs.map(\.uuidString), from: key).get()
    }

    static func remove(grantID: UUID, on redis: any RedisClient) async {
        await remove(grantIDs: [grantID], on: redis)
    }

    /// Fetches buffered session activities for specific grant IDs only via HMGET.
    static func get(for grantIDs: [UUID], on redis: any RedisClient) async -> [UUID:
        SessionActivityBuffer]
    {
        guard !grantIDs.isEmpty else { return [:] }

        let fields = grantIDs.map(\.uuidString)
        guard
            let values = try? await redis.hmget(fields, from: key, as: String.self)
                .get()
        else {
            return [:]
        }

        let decoder = JSONDecoder()
        var result: [UUID: SessionActivityBuffer] = [:]
        for (index, jsonString) in values.enumerated() {
            guard let jsonString,
                let data = jsonString.data(using: .utf8),
                let buffer = try? decoder.decode(SessionActivityBuffer.self, from: data)
            else { continue }
            result[grantIDs[index]] = buffer
        }
        return result
    }

    /// Fetches all buffered session activities from the Redis hash.
    static func getAll(on redis: Request.Redis) async -> [String: SessionActivityBuffer] {
        let entries: [String: SessionActivityBuffer] =
            (try? await redis.hgetall(from: key).map { dict in
                var result: [String: SessionActivityBuffer] = [:]
                let decoder = JSONDecoder()
                for (grantID, respVal) in dict {
                    guard let str = respVal.string,
                        let data = str.data(using: .utf8),
                        let buffer = try? decoder.decode(SessionActivityBuffer.self, from: data)
                    else { continue }
                    result[grantID] = buffer
                }
                return result
            }.get()) ?? [:]

        return entries
    }
}
