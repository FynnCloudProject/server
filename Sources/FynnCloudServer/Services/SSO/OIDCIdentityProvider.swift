import Foundation
import JWT
import Redis
import Vapor

/// OpenID Connect provider using the Authorization Code flow with PKCE.
///
/// Discovery and JWKS are fetched via `req.client` and cached in Redis. ID tokens are
/// verified against the provider JWKS with signature + `iss`/`aud`/`exp`/`nonce` checks.
struct OIDCIdentityProvider: RedirectIdentityProvider {
    let id: String
    let config: OIDCProviderConfig

    var displayName: String { config.displayName }

    // MARK: - Authorization

    func authorizationURL(state: String, nonce: String, pkce: PKCE, on req: Request) async throws
        -> String
    {
        let discovery = try await discovery(on: req)
        var components = URLComponents(string: discovery.authorizationEndpoint)
        var items = components?.queryItems ?? []
        items.append(contentsOf: [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "scope", value: config.scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "login"),
        ])
        components?.queryItems = items
        guard let url = components?.string else {
            throw Abort(.internalServerError, reason: "Failed to build OIDC authorization URL")
        }
        return url
    }

    // MARK: - Callback / token exchange

    func exchange(code: String, pkce: PKCE, expectedNonce: String, on req: Request) async throws
        -> ExternalIdentity
    {
        let discovery = try await discovery(on: req)
        let idToken = try await requestIDToken(
            code: code, verifier: pkce.verifier, discovery: discovery, on: req)

        // Verify signature against the provider JWKS.
        let claims = try await verifyIDToken(idToken, discovery: discovery, on: req)

        // Verify issuer, audience and nonce (exp is verified in the payload).
        // Normalize trailing slashes so providers like Auth0 (which append a trailing slash to `iss`) match seamlessly.
        let normalizedClaimsIss = claims.iss.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedConfigIss = config.issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedDiscoveryIss = discovery.issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard normalizedClaimsIss == normalizedConfigIss || normalizedClaimsIss == normalizedDiscoveryIss else {
            throw Abort(.unauthorized, reason: "OIDC issuer mismatch")
        }
        try claims.aud.verifyIntendedAudience(includes: config.clientID)
        guard let nonce = claims.nonce, nonce == expectedNonce else {
            throw Abort(.unauthorized, reason: "OIDC nonce mismatch")
        }

        let email = claims.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups = Self.claimStringArray(inJWT: idToken, claim: config.groupsClaim)
        let username =
            claims.preferredUsername
            ?? email.map { String($0.prefix(while: { $0 != "@" })) }
            ?? claims.sub

        return ExternalIdentity(
            provider: id,
            subject: claims.sub,
            username: username,
            email: (email?.isEmpty == true) ? nil : email,
            emailVerified: claims.emailVerified ?? false,
            displayName: claims.name ?? claims.preferredUsername,
            groups: groups
        )
    }

    private func requestIDToken(
        code: String, verifier: String, discovery: OIDCDiscovery, on req: Request
    ) async throws -> String {
        var headers = HTTPHeaders()
        headers.contentType = .urlEncodedForm
        // Confidential clients authenticate with client_secret_basic; PKCE is always sent.
        if !config.clientSecret.isEmpty {
            let credentials = Data("\(config.clientID):\(config.clientSecret)".utf8)
                .base64EncodedString()
            headers.add(name: .authorization, value: "Basic \(credentials)")
        }

        let form = TokenRequest(
            grant_type: "authorization_code",
            code: code,
            redirect_uri: config.redirectURI,
            client_id: config.clientID,
            code_verifier: verifier
        )

        let response = try await req.client.post(URI(string: discovery.tokenEndpoint), headers: headers)
        {
            try $0.content.encode(form, as: .urlEncodedForm)
        }

        guard response.status == .ok else {
            throw Abort(.unauthorized, reason: "OIDC token exchange failed (\(response.status.code))")
        }
        let tokens = try response.content.decode(TokenResponse.self)
        return tokens.id_token
    }

    // MARK: - Discovery & JWKS (Redis-cached)

    private func discovery(on req: Request) async throws -> OIDCDiscovery {
        let raw = try await cachedOrFetch(
            key: RedisKey("oidc:discovery:\(id)"), ttlSeconds: 3600, on: req
        ) {
            let url = "\(config.issuer)/.well-known/openid-configuration"
            let response = try await req.client.get(URI(string: url))
            guard response.status == .ok, let body = response.body else {
                throw Abort(.internalServerError, reason: "OIDC discovery failed")
            }
            return String(buffer: body)
        }
        guard let data = raw.json.data(using: .utf8),
            let discovery = try? JSONDecoder().decode(OIDCDiscovery.self, from: data)
        else {
            throw Abort(.internalServerError, reason: "Invalid OIDC discovery document")
        }
        return discovery
    }

    private func jwks(discovery: OIDCDiscovery, forceRefresh: Bool = false, on req: Request) async throws
        -> (json: String, wasCached: Bool)
    {
        try await cachedOrFetch(
            key: RedisKey("oidc:jwks:\(id)"), ttlSeconds: 3600, forceRefresh: forceRefresh, on: req
        ) {
            let response = try await req.client.get(URI(string: discovery.jwksURI))
            guard response.status == .ok, let body = response.body else {
                throw Abort(.internalServerError, reason: "OIDC JWKS fetch failed")
            }
            return String(buffer: body)
        }
    }

    /// Verifies the ID token against the provider JWKS, retrying once with a freshly fetched key set
    /// when the cached one was used - otherwise a provider key rotation breaks logins until the
    /// cache expires.
    private func verifyIDToken(_ idToken: String, discovery: OIDCDiscovery, on req: Request)
        async throws -> OIDCIDToken
    {
        let cached = try await jwks(discovery: discovery, on: req)
        do {
            return try await verify(idToken, jwksJSON: cached.json)
        } catch {
            guard cached.wasCached else { throw error }
            let refreshed = try await jwks(discovery: discovery, forceRefresh: true, on: req)
            return try await verify(idToken, jwksJSON: refreshed.json)
        }
    }

    private func verify(_ idToken: String, jwksJSON: String) async throws -> OIDCIDToken {
        let keys = JWTKeyCollection()
        try await keys.add(jwksJSON: jwksJSON)
        return try await keys.verify(idToken, as: OIDCIDToken.self)
    }

    private func cachedOrFetch(
        key: RedisKey, ttlSeconds: Int, forceRefresh: Bool = false, on req: Request,
        fetch: () async throws -> String
    ) async throws -> (json: String, wasCached: Bool) {
        if !forceRefresh, let cached = try? await req.redis.get(key, as: String.self).get() {
            return (cached, true)
        }
        let value = try await fetch()
        // Best-effort cache: a failure here only costs an extra discovery/JWKS fetch next time.
        _ = try? await req.redis.set(key, to: value).get()
        _ = try? await req.redis.expire(key, after: .seconds(Int64(ttlSeconds))).get()
        return (value, false)
    }

    /// Reads a string-array claim from the (already signature-verified) ID token payload.
    /// Supports array-of-strings and space/comma-delimited string forms; unknown claim -> `[]`.
    static func claimStringArray(inJWT token: String, claim: String) -> [String] {
        let segments = token.split(separator: ".")
        guard segments.count >= 2,
            let data = base64URLDecode(String(segments[1])),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let value = object[claim]
        else { return [] }

        if let array = value as? [Any] { return array.compactMap { $0 as? String } }
        if let string = value as? String {
            return string.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        }
        return []
    }

    private static func base64URLDecode(_ input: String) -> Data? {
        var base64 =
            input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }
}

// MARK: - Wire types

private struct OIDCDiscovery: Codable {
    let issuer: String
    let authorizationEndpoint: String
    let tokenEndpoint: String
    let jwksURI: String

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case jwksURI = "jwks_uri"
    }
}

private struct TokenRequest: Content {
    let grant_type: String
    let code: String
    let redirect_uri: String
    let client_id: String
    let code_verifier: String
}

private struct TokenResponse: Content {
    let id_token: String
    let access_token: String?
}

/// Standard OIDC ID token claims. Signature/`exp` are enforced by JWTKit; the remaining
/// checks (`iss`, `aud`, `nonce`) are performed by the provider after verification.
private struct OIDCIDToken: JWTPayload {
    let iss: String
    let sub: String
    let aud: AudienceClaim
    let exp: ExpirationClaim
    let nonce: String?
    let email: String?
    let emailVerified: Bool?
    let name: String?
    let preferredUsername: String?

    enum CodingKeys: String, CodingKey {
        case iss, sub, aud, exp, nonce, email, name
        case emailVerified = "email_verified"
        case preferredUsername = "preferred_username"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        iss = try container.decode(String.self, forKey: .iss)
        sub = try container.decode(String.self, forKey: .sub)
        aud = try container.decode(AudienceClaim.self, forKey: .aud)
        exp = try container.decode(ExpirationClaim.self, forKey: .exp)
        nonce = try container.decodeIfPresent(String.self, forKey: .nonce)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        preferredUsername = try container.decodeIfPresent(String.self, forKey: .preferredUsername)

        // `email_verified` may arrive as a bool or a string ("true"); accept both.
        if let boolValue = try? container.decodeIfPresent(Bool.self, forKey: .emailVerified) {
            emailVerified = boolValue
        } else if let stringValue = try? container.decodeIfPresent(
            String.self, forKey: .emailVerified)
        {
            emailVerified = stringValue.lowercased() == "true"
        } else {
            emailVerified = nil
        }
    }

    func verify(using algorithm: some JWTAlgorithm) throws {
        try exp.verifyNotExpired()
    }
}
