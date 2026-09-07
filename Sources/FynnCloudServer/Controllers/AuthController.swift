import Crypto
import Fluent
import Foundation
import JWT
import Redis
import Vapor

struct AuthController: RouteCollection {
    /// Allowed official OAuth client IDs for authentication
    public static let allowedClientIDs: Set<String> = [
        "fynncloud-web",
        "fynncloud-desktop",
        "fynncloud-ios",
        "fynncloud-android",
    ]

    func boot(routes: any RoutesBuilder) throws {
        let api = routes.grouped("api", "auth")
        let publicAuth = api.grouped(RateLimitMiddleware(category: .auth))

        publicAuth.post("login", use: login)
        publicAuth.post("register", use: register)
        publicAuth.post("setup", use: setup)
        publicAuth.post("exchange", use: exchange)
        publicAuth.post("refresh", use: refresh)

        publicAuth.get("oidc", ":provider", "start", use: oidcStart)
        publicAuth.get("oidc", ":provider", "callback", use: oidcCallback)

        let protected = api.grouped(UserPayloadAuthenticator(), UserPayload.guardMiddleware())

        protected.post("logout", use: logout)

        protected.post("authorize", use: authorizePost)

        protected.get("sessions", use: listSessions)
        protected.delete("sessions", ":grantID", use: revokeSession)
        protected.delete("sessions", use: revokeOtherSessions)
    }

    func login(req: Request) async throws -> AuthorizeResponse {
        var loginData = try req.content.decode(LoginWithOAuthDTO.self)
        loginData.username = loginData.username.lowercased()

        guard Self.allowedClientIDs.contains(loginData.clientId) else {
            throw Abort(.badRequest, reason: "Invalid client ID").localized(
                LocalizationKeys.Error.Auth.InvalidClientId)
        }

        let user = try await authenticate(
            username: loginData.username, password: loginData.password, req: req)
        let userID = try user.requireID()

        // Enforce TOTP when the account has it enabled: without a code, signal the client to
        // collect one; with a code, verify it (accepting a one-time recovery code as fallback).
        if let totp = try await UserTOTP.query(on: req.db)
            .filter(\.$user.$id == userID)
            .filter(\.$isEnabled == true)
            .first()
        {
            guard let submitted = loginData.totpCode?.trimmingCharacters(in: .whitespaces),
                !submitted.isEmpty
            else {
                return AuthorizeResponse(callbackURL: "", code: nil, totpRequired: true)
            }
            guard try await verifyTOTP(submitted, for: totp, req: req) else {
                req.logger(subsystem: .auth).warning(
                    "Failed login attempt: invalid TOTP code",
                    metadata: [
                        "user_id": .stringConvertible(userID),
                        "username": .string(user.username),
                        "ip": .string(req.clientIP),
                    ]
                )
                throw Abort(.unauthorized, reason: "Invalid authentication code").localized(
                    LocalizationKeys.Error.Auth.TotpInvalid)
            }
        }

        let frontendURL = req.application.config.frontendURL
        let response = try await OAuthCodeService.issueCode(
            userID: userID,
            codeChallenge: loginData.codeChallenge,
            clientID: loginData.clientId,
            state: loginData.state,
            redirectURI: loginData.redirectURI,
            defaultRedirectURI: "\(frontendURL)/auth/callback",
            req: req
        )

        req.logger(subsystem: .auth).info(
            "User logged in successfully",
            metadata: [
                "user_id": .stringConvertible(userID),
                "username": .string(user.username),
                "client_id": .string(loginData.clientId),
                "ip": .string(req.clientIP),
            ]
        )

        // Return both for flexibility (Web can use code directly, Apps might use callbackURL if needed)
        return response
    }

    /// Resolves the login `User` from credentials: first the local bcrypt password, then any
    /// configured credentials-based SSO provider (LDAP), which provisions/links via `SSOService`.
    private func authenticate(username: String, password: String, req: Request) async throws -> User
    {
        if let user = try await User.query(on: req.db)
            .group(
                .or,
                { query in
                    query.filter(\.$username == username)
                    query.filter(\.$email == username)
                }
            )
            .first(),
            (try? user.verify(password: password)) == true
        {
            return user
        }

        if let ldap = req.ssoProviders.credentialsProvider(id: "ldap") {
            if let identity = try? await ldap.authenticate(
                username: username, password: password, on: req)
            {
                return try await req.ssoService.resolveUser(identity)
            }
        }

        req.logger(subsystem: .auth).warning(
            "Failed login attempt: invalid credentials",
            metadata: [
                "username": .string(username),
                "ip": .string(req.clientIP),
            ]
        )

        throw Abort(.unauthorized, reason: "Invalid credentials").localized(
            LocalizationKeys.Error.Auth.Credentials)
    }

    /// Verifies a login-time TOTP submission: first as a live time-based code, then as a
    /// one-time recovery code (which is consumed on a match).
    private func verifyTOTP(_ submitted: String, for totp: UserTOTP, req: Request) async throws
        -> Bool
    {
        let secret = try req.secretBox.decrypt(totp.secret)
        if TOTP.verify(code: submitted, secret: secret) { return true }
        return try await totp.consumeRecoveryCode(submitted, on: req.db)
    }

    // MARK: - OIDC redirect flow

    /// Redis-persisted state for an in-flight OIDC login, keyed by the opaque `state` value.
    private struct OIDCFlowState: Codable {
        let nonce: String
        let verifier: String
        /// The client's PKCE challenge, carried through so the final `/exchange` works unchanged.
        let clientChallenge: String
        let clientID: String
        let clientState: String?
        let redirectURI: String
    }

    /// Begins an OIDC login: stores flow state and redirects the browser to the provider.
    func oidcStart(req: Request) async throws -> Response {
        let providerKey = req.parameters.get("provider") ?? ""
        guard let provider = req.ssoProviders.redirectProvider(id: "oidc:\(providerKey)") else {
            throw Abort(.notFound, reason: "Unknown SSO provider")
        }

        // Continuation parameters from the client that started the flow.
        let clientID = try req.query.get(String.self, at: "client_id")
        guard Self.allowedClientIDs.contains(clientID) else {
            throw Abort(.badRequest, reason: "Invalid client ID").localized(
                LocalizationKeys.Error.Auth.InvalidClientId)
        }
        let clientChallenge = try req.query.get(String.self, at: "code_challenge")
        let clientState: String? = req.query["state"]

        let frontendURL = req.application.config.frontendURL
        let allowedURIs = ["fynncloud://auth", "\(frontendURL)/auth/callback"]
        let redirectURI =
            (try? req.query.get(String.self, at: "redirect_uri"))
            ?? "\(frontendURL)/auth/callback"
        guard allowedURIs.contains(redirectURI) else {
            throw Abort(.badRequest, reason: "Unauthorized redirect URI")
        }

        let state = SSOToken.random()
        let nonce = SSOToken.random()
        let pkce = PKCE.generate()

        let flow = OIDCFlowState(
            nonce: nonce, verifier: pkce.verifier, clientChallenge: clientChallenge,
            clientID: clientID, clientState: clientState, redirectURI: redirectURI)
        let flowJSON = String(decoding: try JSONEncoder().encode(flow), as: UTF8.self)
        let flowKey = RedisKey("oidc:flow:\(state)")
        _ = try await req.redis.set(flowKey, to: flowJSON).get()
        _ = try await req.redis.expire(flowKey, after: .seconds(600)).get()

        let url = try await provider.authorizationURL(
            state: state, nonce: nonce, pkce: pkce, on: req)
        return req.redirect(to: url)
    }

    /// Handles the provider callback: verifies the flow, resolves the user, mints a one-time
    /// `OAuthCode`, and redirects back to the client so it can `/exchange` as usual.
    func oidcCallback(req: Request) async throws -> Response {
        let providerKey = req.parameters.get("provider") ?? ""
        guard let provider = req.ssoProviders.redirectProvider(id: "oidc:\(providerKey)") else {
            throw Abort(.notFound, reason: "Unknown SSO provider")
        }
        if let providerError: String = req.query["error"] {
            throw Abort(.unauthorized, reason: "SSO provider error: \(providerError)")
        }

        let code = try req.query.get(String.self, at: "code")
        let state = try req.query.get(String.self, at: "state")

        // Load and consume the one-time flow state.
        let flowKey = RedisKey("oidc:flow:\(state)")
        guard let flowJSON = try await req.redis.get(flowKey, as: String.self).get(),
            let flow = try? JSONDecoder().decode(
                OIDCFlowState.self, from: Data(flowJSON.utf8))
        else {
            throw Abort(.unauthorized, reason: "Invalid or expired SSO state")
        }
        _ = try? await req.redis.delete(flowKey).get()

        let identity = try await provider.exchange(
            code: code,
            pkce: PKCE(verifier: flow.verifier, challenge: ""),
            expectedNonce: flow.nonce,
            on: req)
        let user = try await req.ssoService.resolveUser(identity)

        // Mint a one-time code bound to the client's PKCE challenge (stored in Redis with 5m TTL).
        let response = try await OAuthCodeService.issueCode(
            userID: try user.requireID(),
            codeChallenge: flow.clientChallenge,
            clientID: flow.clientID,
            state: flow.clientState,
            redirectURI: flow.redirectURI,
            defaultRedirectURI: flow.redirectURI,
            req: req
        )
        return req.redirect(to: response.callbackURL)
    }

    // MARK: - OAuth Exchange (Desktop/Apps)

    func exchange(req: Request) async throws -> Response {
        let dto = try req.content.decode(ExchangeDTO.self)

        let codeKey = RedisKey("oauth:code:\(dto.code)")
        guard let payloadJSON = try await req.redis.get(codeKey, as: String.self).get(),
            let oauthPayload = try? JSONDecoder().decode(
                OAuthCodePayload.self, from: Data(payloadJSON.utf8))
        else {
            throw Abort(.unauthorized, reason: "Code expired or invalid").localized(
                LocalizationKeys.Error.Auth.ExchangeFailed)
        }

        // Delete code immediately to prevent replay attacks (single-use guarantee)
        _ = try? await req.redis.delete(codeKey).get()

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

        guard let user = try await User.find(oauthPayload.userID, on: req.db) else {
            throw Abort(.unauthorized, reason: "User not found").localized(
                LocalizationKeys.Error.Http.Unauthorized)
        }
        let userID = try user.requireID()

        try await user.$groups.load(on: req.db)
        try await user.$tier.load(on: req.db)

        let grant = OAuthGrant(
            userID: userID,
            clientID: oauthPayload.clientID,
            userAgent: req.headers["User-Agent"].first ?? "",
            ipAddress: req.clientIP
        )
        try await grant.save(on: req.db)
        let grantID = try grant.requireID()

        req.logger(subsystem: .auth).info(
            "OAuth code exchanged for grant",
            metadata: [
                "user_id": .stringConvertible(userID),
                "username": .string(user.username),
                "grant_id": .stringConvertible(grantID),
                "client_id": .string(oauthPayload.clientID),
                "ip": .string(req.clientIP),
            ]
        )

        let loginResponse = try await generateTokens(for: grant, req: req, user: user)
        let isWeb = oauthPayload.clientID == "fynncloud-web"

        // Same as in refresh, ensure SPA never sees an actual token
        let response =
            !isWeb
            ? try await loginResponse.encodeResponse(for: req)
            : try await user.toPublic().encodeResponse(for: req)

        if isWeb {
            setAuthCookies(
                response: response, accessToken: loginResponse.accessToken,
                refreshToken: loginResponse.refreshToken,
                isProduction: req.application.environment == .production)
        }

        return response
    }

    func refresh(req: Request) async throws -> Response {
        // Read refresh token from cookie OR request body (for backward compatibility)
        let refreshToken: String
        if let cookieToken = req.cookies["refreshToken"]?.string {
            refreshToken = cookieToken
        } else if let dto = try? req.content.decode(RefreshDTO.self) {
            refreshToken = dto.refreshToken
        } else {
            throw Abort(.unauthorized, reason: "No refresh token found").localized(
                LocalizationKeys.Error.Http.Unauthorized)
        }

        let payload = try await req.jwt.verify(refreshToken, as: UserPayload.self)

        guard let grant = try await OAuthGrant.find(payload.grantID, on: req.db) else {
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
                try await grant.delete(on: req.db)
                await GrantValidityCache.invalidate(grantID: revokedGrantID, on: req.redis)
                await SessionActivityService.remove(grantID: revokedGrantID, on: req.redis)
                throw Abort(.unauthorized, reason: "Token reuse detected. Session terminated.")
                    .localized(
                        LocalizationKeys.Error.Http.Unauthorized)
            }
        }

        guard let user = try await User.find(grant.$user.id, on: req.db) else {
            throw Abort(.unauthorized).localized(LocalizationKeys.Error.Http.Unauthorized)
        }

        try await user.$groups.load(on: req.db)
        try await user.$tier.load(on: req.db)

        let loginResponse = try await generateTokens(for: grant, req: req, user: user)

        let isWeb = grant.clientID == "fynncloud-web"

        // on web for security reasons do not return the tokens in json so the SPA never has access to them
        let response =
            !isWeb
            ? try await loginResponse.encodeResponse(for: req)
            : try await user.toPublic().encodeResponse(for: req)

        if isWeb {
            setAuthCookies(
                response: response, accessToken: loginResponse.accessToken,
                refreshToken: loginResponse.refreshToken,
                isProduction: req.application.environment == .production)
        }

        return response
    }
    // MARK: - Token Helpers

    private func generateTokens(for grant: OAuthGrant, req: Request, user: User) async throws
        -> LoginResponse
    {
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
        try await grant.save(on: req.db)

        return try await LoginResponse(
            accessToken: req.jwt.sign(accessPayload),
            refreshToken: req.jwt.sign(refreshPayload),
            user: user.toPublic()
        )
    }

    // MARK: - Cookie Helpers

    private func setAuthCookies(
        response: Response, accessToken: String, refreshToken: String, isProduction: Bool
    ) {
        let refreshDuration: TimeInterval = 604800

        response.cookies["accessToken"] = HTTPCookies.Value(
            string: accessToken,
            expires: Date().addingTimeInterval(60 * 15),
            maxAge: 60 * 15,
            domain: nil,
            path: "/",
            isSecure: isProduction,
            isHTTPOnly: true,
            sameSite: .lax
        )

        response.cookies["refreshToken"] = HTTPCookies.Value(
            string: refreshToken,
            expires: Date().addingTimeInterval(refreshDuration),
            maxAge: Int(refreshDuration),
            domain: nil,
            path: "/",
            isSecure: isProduction,
            isHTTPOnly: true,
            sameSite: .lax
        )

        response.cookies["fc_session"] = HTTPCookies.Value(
            string: "1",
            expires: Date().addingTimeInterval(refreshDuration),
            maxAge: Int(refreshDuration),
            domain: nil,
            path: "/",
            isSecure: isProduction,
            isHTTPOnly: false,
            sameSite: .lax
        )
    }

    private func clearAuthCookies(response: Response, isProduction: Bool) {
        response.cookies["accessToken"] = HTTPCookies.Value(
            string: "",
            expires: Date(timeIntervalSince1970: 0),
            maxAge: 0,
            domain: nil,
            path: "/",
            isSecure: isProduction,
            isHTTPOnly: true,
            sameSite: .lax
        )

        response.cookies["refreshToken"] = HTTPCookies.Value(
            string: "",
            expires: Date(timeIntervalSince1970: 0),
            maxAge: 0,
            domain: nil,
            path: "/",
            isSecure: isProduction,
            isHTTPOnly: true,
            sameSite: .lax
        )

        response.cookies["fc_session"] = HTTPCookies.Value(
            string: "",
            expires: Date(timeIntervalSince1970: 0),
            maxAge: 0,
            domain: nil,
            path: "/",
            isSecure: isProduction,
            isHTTPOnly: false,
            sameSite: .lax
        )
    }

    // MARK: - Session Management

    func logout(req: Request) async throws -> Response {
        let payload = try req.auth.require(UserPayload.self)

        try await OAuthGrant.query(on: req.db)
            .filter(\.$id == payload.grantID)
            .delete()

        req.logger(subsystem: .auth).info(
            "User logged out",
            metadata: [
                "user_id": .string(payload.subject.value),
                "grant_id": .stringConvertible(payload.grantID),
            ]
        )

        let response = Response(status: .ok)
        clearAuthCookies(
            response: response, isProduction: req.application.environment == .production)

        return response
    }

    func listSessions(req: Request) async throws -> [SessionResponse] {
        let payload = try req.auth.require(UserPayload.self)
        guard let userID = UUID(uuidString: payload.subject.value) else {
            throw Abort(.unauthorized).localized(LocalizationKeys.Error.Http.Unauthorized)
        }

        let grants = try await OAuthGrant.query(on: req.db)
            .filter(\.$user.$id == userID)
            .all()

        guard !grants.isEmpty else { return [] }

        let grantIDs = grants.compactMap { $0.id }
        let redisActivity = await SessionActivityService.get(for: grantIDs, on: req.redis)

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
                isCurrent: grant.id == payload.grantID
            )
        }
    }

    func revokeSession(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(UserPayload.self)
        guard let userID = UUID(uuidString: payload.subject.value) else {
            throw Abort(.unauthorized).localized(LocalizationKeys.Error.Http.Unauthorized)
        }
        guard let targetGrantID = req.parameters.get("grantID", as: UUID.self) else {
            throw Abort(.badRequest).localized(LocalizationKeys.Error.Auth.MissingParams)
        }

        // Ensure the user owns the grant they are trying to revoke
        try await OAuthGrant.query(on: req.db)
            .filter(\.$id == targetGrantID)
            .filter(\.$user.$id == userID)
            .delete()

        await GrantValidityCache.invalidate(grantID: targetGrantID, on: req.redis)
        await SessionActivityService.remove(grantID: targetGrantID, on: req.redis)

        req.logger(subsystem: .auth).info(
            "Session revoked",
            metadata: [
                "user_id": .stringConvertible(userID),
                "target_grant_id": .stringConvertible(targetGrantID),
            ]
        )

        return .noContent
    }

    func revokeOtherSessions(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(UserPayload.self)
        guard let userID = UUID(uuidString: payload.subject.value) else {
            throw Abort(.unauthorized).localized(LocalizationKeys.Error.Http.Unauthorized)
        }

        let revokedGrantIDs = try await OAuthGrant.query(on: req.db)
            .filter(\.$user.$id == userID)
            .filter(\.$id != payload.grantID)
            .all(\.$id)

        guard !revokedGrantIDs.isEmpty else { return .noContent }

        try await OAuthGrant.query(on: req.db)
            .filter(\.$user.$id == userID)
            .filter(\.$id != payload.grantID)
            .delete()

        await GrantValidityCache.invalidate(grantIDs: revokedGrantIDs, on: req.redis)
        await SessionActivityService.remove(grantIDs: revokedGrantIDs, on: req.redis)

        req.logger(subsystem: .auth).info(
            "Other sessions revoked",
            metadata: [
                "user_id": .stringConvertible(userID),
                "current_grant_id": .stringConvertible(payload.grantID),
            ]
        )

        return .noContent
    }

    // MARK: - Registration & Utilities

    func setup(req: Request) async throws -> User.Public {
        let setupData = try req.content.decode(SetupDTO.self)

        let count = try await User.query(on: req.db).count()
        guard count == 0 else {
            throw Abort(.forbidden, reason: "Setup has already been completed.")
        }

        guard
            !setupData.email.isEmpty && !setupData.username.isEmpty
                && !setupData.password.isEmpty && !setupData.confirmPassword.isEmpty
        else {
            throw Abort(.badRequest, reason: "Missing required fields").localized(
                LocalizationKeys.Error.Auth.MissingParams)
        }

        if setupData.password != setupData.confirmPassword {
            throw Abort(.badRequest, reason: "Passwords do not match").localized(
                LocalizationKeys.Error.Auth.PasswordMismatch)
        }

        let user = try await req.userService.createUser(
            input: .init(
                username: setupData.username,
                email: setupData.email,
                password: setupData.password,
                displayName: setupData.displayName,
                isFirstUserCheck: true
            )
        )

        if let appName = setupData.appName?.trimmingCharacters(in: .whitespacesAndNewlines),
            !appName.isEmpty
        {
            try? await req.application.settings.setGuarded(AppSettings.AppName.self, value: appName)
        }
        if let primaryColor = setupData.primaryColor?.trimmingCharacters(
            in: .whitespacesAndNewlines), !primaryColor.isEmpty
        {
            try? await req.application.settings.setGuarded(
                AppSettings.PrimaryColor.self, value: primaryColor)
        }
        if let registrationEnabled = setupData.registrationEnabled {
            try? await req.application.settings.setGuarded(
                AppSettings.RegistrationEnabled.self, value: registrationEnabled)
        }

        let adminID = try user.requireID()
        req.logger(subsystem: .auth).info(
            "Initial server setup completed",
            metadata: [
                "admin_user_id": .stringConvertible(adminID),
                "admin_username": .string(user.username),
            ]
        )

        return try user.toPublic()
    }

    func register(req: Request) async throws -> User.Public {
        let registerData = try req.content.decode(RegisterDTO.self)

        guard
            !registerData.email.isEmpty && !registerData.username.isEmpty
                && !registerData.password.isEmpty && !registerData.confirmPassword.isEmpty
        else {
            throw Abort(.badRequest, reason: "Missing required fields").localized(
                LocalizationKeys.Error.Auth.MissingParams)
        }

        // Block self-registration when disabled, but always allow the first-ever user (admin bootstrap).
        guard
            try await UserService.isRegistrationAllowed(
                on: req.db, settings: req.application.settings)
        else {
            throw Abort(.forbidden, reason: "Registration is currently disabled.")
        }

        if registerData.password != registerData.confirmPassword {
            throw Abort(.badRequest, reason: "Passwords do not match").localized(
                LocalizationKeys.Error.Auth.PasswordMismatch)
        }

        let user = try await req.userService.createUser(
            input: .init(
                username: registerData.username,
                email: registerData.email,
                password: registerData.password,
                displayName: registerData.displayName,
                isFirstUserCheck: true
            )
        )

        let registeredID = try user.requireID()
        req.logger(subsystem: .auth).info(
            "User self-registered",
            metadata: [
                "user_id": .stringConvertible(registeredID),
                "username": .string(user.username),
                "ip": .string(req.clientIP),
            ]
        )

        return try user.toPublic()
    }

    func authorizePost(req: Request) async throws -> AuthorizeResponse {
        let payload = try req.auth.require(UserPayload.self)
        guard let userID = UUID(uuidString: payload.subject.value) else {
            throw Abort(.unauthorized).localized(LocalizationKeys.Error.Http.Unauthorized)
        }
        let dto = try req.content.decode(AuthorizeDTO.self)

        guard Self.allowedClientIDs.contains(dto.clientId) else {
            throw Abort(.badRequest, reason: "Invalid client ID").localized(
                LocalizationKeys.Error.Auth.InvalidClientId)
        }

        return try await OAuthCodeService.issueCode(
            userID: userID,
            codeChallenge: dto.codeChallenge,
            clientID: dto.clientId,
            state: dto.state,
            redirectURI: dto.redirectURI,
            defaultRedirectURI: "fynncloud://auth",
            req: req
        )
    }
}

extension Digest {
    func base64URLEncoded() -> String {
        let data = Data(self)
        var base64 = data.base64EncodedString()

        // Make URL-safe for PKCE
        base64 = base64.replacingOccurrences(of: "+", with: "-")
        base64 = base64.replacingOccurrences(of: "/", with: "_")
        base64 = base64.replacingOccurrences(of: "=", with: "")

        return base64
    }
}
