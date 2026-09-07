import Vapor
import Redis

public enum RateLimitCategory: Sendable {
    case auth
    case share
    case api
    case ai

    func limit(config: ServerConfig) -> Int {
        switch self {
        case .auth: return config.rateLimitAuth
        case .share: return config.rateLimitShare
        case .api: return config.rateLimitAPI
        case .ai: return AppSettings.RateLimitAi.defaultValue
        }
    }

    var windowSeconds: Int {
        return 60
    }

    var prefix: String {
        switch self {
        case .auth: return "auth"
        case .share: return "share"
        case .api: return "api"
        case .ai: return "ai"
        }
    }
}

/// Thread-safe in-memory fallback rate limiter used if Redis is disconnected or unavailable.
private actor InMemoryRateLimiter {
    static let shared = InMemoryRateLimiter()

    private var storage: [String: (count: Int, resetAt: Date)] = [:]

    func increment(key: String, windowSeconds: Int) -> (count: Int, resetTime: Int) {
        let now = Date()
        let windowTimestamp = (Int(now.timeIntervalSince1970) / windowSeconds) * windowSeconds
        let resetTime = windowTimestamp + windowSeconds

        if storage.count > 10_000 {
            storage = storage.filter { $0.value.resetAt > now }
        }

        if let existing = storage[key], existing.resetAt > now {
            let newCount = existing.count + 1
            storage[key] = (newCount, existing.resetAt)
            return (newCount, resetTime)
        } else {
            let resetAt = Date(timeIntervalSince1970: TimeInterval(resetTime))
            storage[key] = (1, resetAt)
            return (1, resetTime)
        }
    }
}

public struct RateLimitMiddleware: AsyncMiddleware {
    public let category: RateLimitCategory

    public init(category: RateLimitCategory) {
        self.category = category
    }

    public func respond(to req: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let config = req.application.config

        guard config.rateLimitEnabled else {
            return try await next.respond(to: req)
        }

        let limit: Int
        if category == .ai {
            if let settings = req.application.optionalSettings {
                limit = (try? await settings.get(AppSettings.RateLimitAi.self)) ?? AppSettings.RateLimitAi.defaultValue
            } else {
                limit = AppSettings.RateLimitAi.defaultValue
            }
        } else {
            limit = category.limit(config: config)
        }
        let windowSeconds = category.windowSeconds

        // Identify requester (Authenticated User ID > X-Forwarded-For > Peer Address)
        let clientIdentifier = getClientIdentifier(req: req)
        let nowTimestamp = Int(Date().timeIntervalSince1970)
        let currentWindow = nowTimestamp / windowSeconds
        let resetTime = (currentWindow + 1) * windowSeconds
        let redisKey = "ratelimit:\(category.prefix):\(clientIdentifier):\(currentWindow)"

        var currentCount = 0

        do {
            let key = RedisKey(redisKey)
            let count = try await req.redis.increment(key).get()
            if count == 1 {
                _ = try? await req.redis.expire(key, after: .seconds(Int64(windowSeconds + 5))).get()
            }
            currentCount = count
        } catch {
            // Best-effort: an unreachable Redis degrades to per-process limiting rather than
            // dropping rate limiting entirely.
            let result = await InMemoryRateLimiter.shared.increment(key: redisKey, windowSeconds: windowSeconds)
            currentCount = result.count
        }

        let remaining = max(0, limit - currentCount)

        if currentCount > limit {
            let retryAfter = max(1, resetTime - nowTimestamp)
            var headers: HTTPHeaders = [:]
            headers.add(name: "X-RateLimit-Limit", value: "\(limit)")
            headers.add(name: "X-RateLimit-Remaining", value: "0")
            headers.add(name: "X-RateLimit-Reset", value: "\(resetTime)")
            headers.add(name: "Retry-After", value: "\(retryAfter)")

            req.logger(subsystem: .auth).warning(
                "Rate limit exceeded",
                metadata: [
                    "category": .string(category.prefix),
                    "client": .string(clientIdentifier),
                    "limit": .stringConvertible(limit),
                ]
            )

            throw Abort(
                .tooManyRequests,
                headers: headers,
                reason: "Too many requests. Please try again later."
            ).localized(LocalizationKeys.Error.Http.TooManyRequests)
        }

        let response = try await next.respond(to: req)

        response.headers.replaceOrAdd(name: "X-RateLimit-Limit", value: "\(limit)")
        response.headers.replaceOrAdd(name: "X-RateLimit-Remaining", value: "\(remaining)")
        response.headers.replaceOrAdd(name: "X-RateLimit-Reset", value: "\(resetTime)")

        return response
    }

    private func getClientIdentifier(req: Request) -> String {
        if (category == .api || category == .ai), let payload = req.auth.get(UserPayload.self) {
            return "user:\(payload.subject.value)"
        }
        return req.clientIP
    }
}
