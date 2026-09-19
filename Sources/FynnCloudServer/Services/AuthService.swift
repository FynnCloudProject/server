import Crypto
import Fluent
import Foundation
import JWT
import Redis
import Vapor

/// Manages authentication credentials, JWT token minting/rotation, OAuth grants,
/// session lifecycles, and OIDC state persistence.
struct AuthService: @unchecked Sendable {
    /// Allowed official OAuth client IDs for authentication across web, desktop, and mobile clients.
    public static let allowedClientIDs: Set<String> = [
        "fynncloud-web",
        "fynncloud-desktop",
        "fynncloud-ios",
        "fynncloud-android",
    ]

    /// Redis-persisted state for an in-flight OIDC login, keyed by the opaque `state` value.
    public struct OIDCFlowState: Codable, Sendable {
        public let nonce: String
        public let verifier: String
        /// The client's PKCE challenge, carried through so the final `/exchange` works unchanged.
        public let clientChallenge: String
        public let clientID: String
        public let clientState: String?
        public let redirectURI: String

        public init(
            nonce: String,
            verifier: String,
            clientChallenge: String,
            clientID: String,
            clientState: String?,
            redirectURI: String
        ) {
            self.nonce = nonce
            self.verifier = verifier
            self.clientChallenge = clientChallenge
            self.clientID = clientID
            self.clientState = clientState
            self.redirectURI = redirectURI
        }
    }

    let req: Request

    init(req: Request) {
        self.req = req
    }

    var db: any Database { req.db }
    var redis: any RedisClient { req.redis }
    var jwt: Request.JWT { req.jwt }
    var secretBox: SecretBox { req.secretBox }
    var ssoProviders: SSOProviderRegistry { req.ssoProviders }
    var ssoService: SSOService { req.ssoService }
    var logger: Logger { req.logger(subsystem: .auth) }
    var clientIP: String { req.clientIP }

    // MARK: - Credential & MFA Verification

    /// Resolves the login `User` from credentials: first the local bcrypt password, then any
    /// configured credentials-based SSO provider (LDAP), which provisions/links via `SSOService`.
    func authenticate(
        usernameOrEmail: String, password: String
    ) async throws -> User {
        let loginStr = usernameOrEmail.lowercased()
        if let user = try await User.query(on: db)
            .group(
                .or,
                { query in
                    query.filter(\.$username == loginStr)
                    query.filter(\.$email == loginStr)
                }
            )
            .first(),
            (try? user.verify(password: password)) == true
        {
            return user
        }

        if let ldap = ssoProviders.credentialsProvider(id: "ldap") {
            if let identity = try? await ldap.authenticate(
                username: loginStr, password: password, on: req)
            {
                return try await ssoService.resolveUser(identity)
            }
        }

        logger.warning(
            "Failed login attempt: invalid credentials",
            metadata: [
                "username": .string(usernameOrEmail),
                "ip": .string(clientIP),
            ]
        )

        throw Abort(.unauthorized, reason: "Invalid credentials").localized(
            LocalizationKeys.Error.Auth.Credentials)
    }

    /// Verifies a login-time TOTP submission: first as a live time-based code, then as a
    /// one-time recovery code (which is consumed on a match).
    func verifyTOTP(_ submitted: String, for totp: UserTOTP) async throws -> Bool {
        let secret = try secretBox.decrypt(totp.secret)
        if TOTP.verify(code: submitted, secret: secret) { return true }
        return try await totp.consumeRecoveryCode(submitted, on: db)
    }

    // MARK: - Token Generation & Rotation

    /// Generates access and refresh tokens for the given grant, updating the grant's
    /// token rotation tracking in the database.
    func generateTokens(for grant: OAuthGrant, user: User) async throws -> LoginResponse {
        let grantID = try grant.requireID()
        let userID = try user.requireID()
        let newRefreshTokenID = UUID()

        let accessPayload = UserPayload(
            subject: .init(value: userID.uuidString),
            expiration: .init(value: Date().addingTimeInterval(60 * 15)),
            grantID: grantID,
            jti: .init(value: UUID().uuidString)
        )

        let refreshDuration: TimeInterval = (grant.clientID != "fynncloud-web") ? 2_592_000 : 604800
        let refreshPayload = UserPayload(
            subject: .init(value: userID.uuidString),
            expiration: .init(value: Date().addingTimeInterval(refreshDuration)),
            grantID: grantID,
            jti: .init(value: newRefreshTokenID.uuidString)
        )

        grant.previousRefreshTokenID = grant.currentRefreshTokenID
        grant.lastRotatedAt = Date()
        grant.currentRefreshTokenID = newRefreshTokenID
        try await grant.save(on: db)

        return try await LoginResponse(
            accessToken: jwt.sign(accessPayload),
            refreshToken: jwt.sign(refreshPayload),
            user: user.toPublic()
        )
    }

    /// Validates an incoming refresh token, verifies the grant and rotation state (permitting a 30s
    /// grace period for concurrent requests), revokes on reuse outside grace period, and mints new tokens.
    func rotateRefreshToken(rawToken: String) async throws -> (
        loginResponse: LoginResponse, user: User, isWeb: Bool
    ) {
        let payload = try await jwt.verify(rawToken, as: UserPayload.self)

        guard let grant = try await OAuthGrant.find(payload.grantID, on: db) else {
            throw Abort(.unauthorized, reason: "Session revoked").localized(
                LocalizationKeys.Error.Http.Unauthorized)
        }

        // Check if the token is the current refresh token, previous refresh token, or within the grace period
        let tokenID = UUID(uuidString: payload.jti.value)
        let isCurrentToken = tokenID == grant.currentRefreshTokenID
        let isPreviousToken = tokenID == grant.previousRefreshTokenID
        let isWithinGracePeriod: Bool = {
            guard let lastRotatedAt = grant.lastRotatedAt else { return false }
            // Allow a 30-second grace period for concurrent multi-tab or SSR token refresh race conditions
            return Date().timeIntervalSince(lastRotatedAt) < 30
        }()

        if !isCurrentToken && !isPreviousToken {
            if !isWithinGracePeriod {
                // Revoke the whole session (grant) ONLY on reuse of a refresh token outside the 30s grace period
                let revokedGrantID = try grant.requireID()
                try await grant.delete(on: db)
                await GrantValidityCache.invalidate(grantID: revokedGrantID, on: redis)
                await SessionActivityService.remove(grantID: revokedGrantID, on: redis)
                throw Abort(.unauthorized, reason: "Token reuse detected. Session terminated.")
                    .localized(
                        LocalizationKeys.Error.Http.Unauthorized)
            }
        }

        guard let user = try await User.find(grant.$user.id, on: db) else {
            throw Abort(.unauthorized).localized(LocalizationKeys.Error.Http.Unauthorized)
        }

        try await user.$groups.load(on: db)
        try await user.$tier.load(on: db)

        let loginResponse = try await generateTokens(for: grant, user: user)
        let isWeb = grant.clientID == "fynncloud-web"

        return (loginResponse, user, isWeb)
    }

    // MARK: - OAuth PKCE Exchange

    /// Validates an OAuth authorization code against Redis, validates the PKCE verifier challenge,
    /// creates an `OAuthGrant`, and issues new JWT tokens.
    func exchangeCode(dto: ExchangeDTO) async throws -> (
        loginResponse: LoginResponse, user: User, isWeb: Bool
    ) {
        let codeKey = RedisKey("oauth:code:\(dto.code)")
        guard let payloadJSON = try await redis.get(codeKey, as: String.self).get(),
            let oauthPayload = try? JSONDecoder().decode(
                OAuthCodePayload.self, from: Data(payloadJSON.utf8))
        else {
            throw Abort(.unauthorized, reason: "Code expired or invalid").localized(
                LocalizationKeys.Error.Auth.ExchangeFailed)
        }

        // Delete code immediately to prevent replay attacks (single-use guarantee)
        _ = try? await redis.delete(codeKey).get()

        let hashedVerifier = SHA256.hash(data: Data(dto.code_verifier.utf8)).base64URLEncoded()
        guard hashedVerifier == oauthPayload.codeChallenge else {
            throw Abort(.unauthorized, reason: "Invalid verifier").localized(
                LocalizationKeys.Error.Auth.ExchangeFailed)
        }

        guard Self.allowedClientIDs.contains(dto.clientId) else {
            throw Abort(.unauthorized, reason: "Invalid client ID").localized(
                LocalizationKeys.Error.Auth.InvalidClientId)
        }

        guard dto.clientId == oauthPayload.clientID else {
            throw Abort(.unauthorized, reason: "Client ID mismatch").localized(
                LocalizationKeys.Error.Auth.InvalidClientId)
        }

        guard let user = try await User.find(oauthPayload.userID, on: db) else {
            throw Abort(.unauthorized, reason: "User not found").localized(
                LocalizationKeys.Error.Http.Unauthorized)
        }
        let userID = try user.requireID()

        try await user.$groups.load(on: db)
        try await user.$tier.load(on: db)

        let grant = OAuthGrant(
            userID: userID,
            clientID: oauthPayload.clientID,
            userAgent: req.headers["User-Agent"].first ?? "",
            ipAddress: clientIP
        )
        try await grant.save(on: db)
        let grantID = try grant.requireID()

        logger.info(
            "OAuth code exchanged for grant",
            metadata: [
                "user_id": .stringConvertible(userID),
                "username": .string(user.username),
                "grant_id": .stringConvertible(grantID),
                "client_id": .string(oauthPayload.clientID),
                "ip": .string(clientIP),
            ]
        )

        let loginResponse = try await generateTokens(for: grant, user: user)
        let isWeb = oauthPayload.clientID == "fynncloud-web"

        return (loginResponse, user, isWeb)
    }

    // MARK: - Session Management

    /// Terminates a single session by deleting the OAuthGrant and logging the event.
    func logout(grantID: UUID, userID: String) async throws {
        try await OAuthGrant.query(on: db)
            .filter(\.$id == grantID)
            .delete()

        logger.info(
            "User logged out",
            metadata: [
                "user_id": .string(userID),
                "grant_id": .stringConvertible(grantID),
            ]
        )
    }

    /// Lists active sessions for a user, enriched with Redis session activity metrics.
    func listSessions(
        userID: UUID, currentGrantID: UUID? = nil
    ) async throws -> [SessionResponse] {
        let grants = try await OAuthGrant.query(on: db)
            .filter(\.$user.$id == userID)
            .all()

        guard !grants.isEmpty else { return [] }

        let grantIDs = grants.compactMap { $0.id }
        let redisActivity = await SessionActivityService.get(for: grantIDs, on: redis)

        return grants.map { grant in
            let activity = grant.id.flatMap { redisActivity[$0] }

            var effectiveLastUsed = grant.lastUsedAt
            if let ts = activity?.timestamp {
                let bufferedDate = Date(timeIntervalSince1970: Double(ts))
                if effectiveLastUsed == nil || bufferedDate > effectiveLastUsed! {
                    effectiveLastUsed = bufferedDate
                }
            }

            let effectiveIP = activity?.ipAddress ?? grant.ipAddress

            return SessionResponse(
                id: grant.id ?? UUID(),
                clientID: grant.clientID,
                userAgent: grant.userAgent,
                ipAddress: effectiveIP,
                createdAt: grant.createdAt,
                lastUsedAt: effectiveLastUsed ?? grant.createdAt,
                isCurrent: grant.id == currentGrantID
            )
        }
    }

    /// Revokes a specific session owned by the given user.
    func revokeSession(targetGrantID: UUID, userID: UUID) async throws {
        try await OAuthGrant.query(on: db)
            .filter(\.$id == targetGrantID)
            .filter(\.$user.$id == userID)
            .delete()

        await GrantValidityCache.invalidate(grantID: targetGrantID, on: redis)
        await SessionActivityService.remove(grantID: targetGrantID, on: redis)

        logger.info(
            "Session revoked",
            metadata: [
                "user_id": .stringConvertible(userID),
                "target_grant_id": .stringConvertible(targetGrantID),
            ]
        )
    }

    /// Revokes all other sessions for the user, preserving the current session grant.
    func revokeOtherSessions(currentGrantID: UUID, userID: UUID) async throws {
        let revokedGrantIDs = try await OAuthGrant.query(on: db)
            .filter(\.$user.$id == userID)
            .filter(\.$id != currentGrantID)
            .all(\.$id)

        guard !revokedGrantIDs.isEmpty else { return }

        try await OAuthGrant.query(on: db)
            .filter(\.$user.$id == userID)
            .filter(\.$id != currentGrantID)
            .delete()

        await GrantValidityCache.invalidate(grantIDs: revokedGrantIDs, on: redis)
        await SessionActivityService.remove(grantIDs: revokedGrantIDs, on: redis)

        logger.info(
            "Other sessions revoked",
            metadata: [
                "user_id": .stringConvertible(userID),
                "current_grant_id": .stringConvertible(currentGrantID),
            ]
        )
    }

    // MARK: - OIDC Flow State Persistence

    /// Persists OIDC flow state in Redis for 10 minutes.
    func storeOIDCFlow(state: String, flow: OIDCFlowState) async throws {
        let flowJSON = String(decoding: try JSONEncoder().encode(flow), as: UTF8.self)
        let flowKey = RedisKey("oidc:flow:\(state)")
        _ = try await redis.set(flowKey, to: flowJSON).get()
        _ = try await redis.expire(flowKey, after: .seconds(600)).get()
    }

    /// Retrieves and consumes the OIDC flow state from Redis (single-use).
    func consumeOIDCFlow(state: String) async throws -> OIDCFlowState {
        let flowKey = RedisKey("oidc:flow:\(state)")
        guard let flowJSON = try await redis.get(flowKey, as: String.self).get(),
            let flow = try? JSONDecoder().decode(
                OIDCFlowState.self, from: Data(flowJSON.utf8))
        else {
            throw Abort(.unauthorized, reason: "Invalid or expired SSO state")
        }
        _ = try? await redis.delete(flowKey).get()
        return flow
    }
}
