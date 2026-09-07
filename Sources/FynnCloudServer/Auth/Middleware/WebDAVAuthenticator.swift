import Crypto
import Fluent
import Redis
import Vapor

// TODO: Move to app specific passwords or specific webdav creds something

/// HTTP Basic authentication for WebDAV clients (Finder, Windows Explorer, mobile apps),
/// which cannot use the app's JWT/cookie flow. Validates credentials against the local
/// bcrypt password hash and logs in the `User` for the request.
struct WebDAVAuthenticator: AsyncMiddleware {
    // Finder issues many requests per browse; caching the (expensive) bcrypt result briefly keeps it responsive.
    private static let verifyCacheTTL: Int64 = 300

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response
    {
        guard let basic = request.headers.basicAuthorization else {
            return Self.challenge()
        }

        let username = basic.username.lowercased()
        guard
            let user = try await User.query(on: request.db)
                .group(
                    .or,
                    { query in
                        query.filter(\.$username == username)
                        query.filter(\.$email == username)
                    }
                )
                .first()
        else {
            return Self.challenge()
        }

        guard try await verify(password: basic.password, for: user, on: request) else {
            return Self.challenge()
        }

        request.auth.login(user)
        return try await next.respond(to: request)
    }

    /// Verifies the password, using a short-lived Redis cache to skip repeated bcrypt hashing. TECHNICALLY INSECURE WE ARE MOVIGN AWAY FROM THIS LATER!
    private func verify(password: String, for user: User, on request: Request) async throws -> Bool
    {
        let cacheKey = Self.cacheKey(user: user, password: password)
        if let cached = try? await request.redis.get(cacheKey, as: String.self).get(), cached == "1"
        {
            return true
        }

        guard (try? user.verify(password: password)) == true else { return false }

        _ = try? await request.redis.set(cacheKey, to: "1").get()
        _ = try? await request.redis.expire(cacheKey, after: .seconds(Self.verifyCacheTTL)).get()
        return true
    }

    /// Keyed by password-hash + password digest so a password change invalidates cached entries.
    private static func cacheKey(user: User, password: String) -> RedisKey {
        let material = "\(user.passwordHash)|\(password)"
        let digest = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return RedisKey("webdav:auth:\(digest)")
    }

    private static func challenge() -> Response {
        let response = Response(status: .unauthorized)
        response.headers.replaceOrAdd(
            name: .wwwAuthenticate, value: "Basic realm=\"FynnCloud WebDAV\", charset=\"UTF-8\"")
        return response
    }
}
