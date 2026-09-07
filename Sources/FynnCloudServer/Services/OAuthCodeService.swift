import Foundation
import Redis
import Vapor

/// Mints the one-time OAuth authorization codes shared by every login ceremony (password, OIDC,
/// passkey, session re-authorize) that bridges into the PKCE `/api/auth/exchange` endpoint.
struct OAuthCodeService: Sendable {
    static let codeTTLSeconds: Int64 = 300

    /// Validates `redirectURI` (or `defaultRedirectURI`) against the allowed callback URIs, stores a
    /// one-time code in Redis bound to the given PKCE challenge/client, and builds the callback URL.
    static func issueCode(
        userID: UUID,
        codeChallenge: String,
        clientID: String,
        state: String?,
        redirectURI: String?,
        defaultRedirectURI: String,
        req: Request
    ) async throws -> AuthorizeResponse {
        let frontendURL = req.application.config.frontendURL
        let allowedURIs = [
            "fynncloud://auth",
            "\(frontendURL)/auth/callback",
        ]

        let targetURI = redirectURI ?? defaultRedirectURI
        guard allowedURIs.contains(targetURI) else {
            throw Abort(.badRequest, reason: "Unauthorized redirect URI").localized(
                LocalizationKeys.Error.Http.Generic)
        }

        let code = UUID().uuidString
        let payload = OAuthCodePayload(
            userID: userID,
            codeChallenge: codeChallenge,
            clientID: clientID,
            state: state
        )
        let payloadJSON = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        let codeKey = RedisKey("oauth:code:\(code)")
        _ = try await req.redis.set(codeKey, to: payloadJSON).get()
        _ = try await req.redis.expire(codeKey, after: .seconds(codeTTLSeconds)).get()

        var components = URLComponents(string: targetURI)
        var queryItems = components?.queryItems ?? []
        queryItems.append(URLQueryItem(name: "code", value: code))
        if let state {
            queryItems.append(URLQueryItem(name: "state", value: state))
        }
        components?.queryItems = queryItems

        guard let finalURL = components?.string else {
            throw Abort(.internalServerError).localized(LocalizationKeys.Error.Http.Generic)
        }

        return AuthorizeResponse(callbackURL: finalURL, code: code)
    }
}
