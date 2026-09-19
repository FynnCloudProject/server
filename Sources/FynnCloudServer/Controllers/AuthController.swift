import Crypto
import Fluent
import Foundation
import JWT
import Redis
import Vapor

struct AuthController: RouteCollection {
    /// Allowed official OAuth client IDs for authentication (forwarded to `AuthService.allowedClientIDs`)
    public static let allowedClientIDs: Set<String> = AuthService.allowedClientIDs

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

        let user = try await req.authService.authenticate(
            usernameOrEmail: loginData.username, password: loginData.password)
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
            guard try await req.authService.verifyTOTP(submitted, for: totp) else {
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

    // MARK: - OIDC redirect flow

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

        let flow = AuthService.OIDCFlowState(
            nonce: nonce, verifier: pkce.verifier, clientChallenge: clientChallenge,
            clientID: clientID, clientState: clientState, redirectURI: redirectURI)
        try await req.authService.storeOIDCFlow(state: state, flow: flow)

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

        let flow = try await req.authService.consumeOIDCFlow(state: state)

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
        let (loginResponse, user, isWeb) = try await req.authService.exchangeCode(dto: dto)

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

        let (loginResponse, user, isWeb) = try await req.authService.rotateRefreshToken(rawToken: refreshToken)

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
        try await req.authService.logout(grantID: payload.grantID, userID: payload.subject.value)

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
        return try await req.authService.listSessions(userID: userID, currentGrantID: payload.grantID)
    }

    func revokeSession(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(UserPayload.self)
        guard let userID = UUID(uuidString: payload.subject.value) else {
            throw Abort(.unauthorized).localized(LocalizationKeys.Error.Http.Unauthorized)
        }
        guard let targetGrantID = req.parameters.get("grantID", as: UUID.self) else {
            throw Abort(.badRequest).localized(LocalizationKeys.Error.Auth.MissingParams)
        }

        try await req.authService.revokeSession(targetGrantID: targetGrantID, userID: userID)
        return .noContent
    }

    func revokeOtherSessions(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(UserPayload.self)
        guard let userID = UUID(uuidString: payload.subject.value) else {
            throw Abort(.unauthorized).localized(LocalizationKeys.Error.Http.Unauthorized)
        }

        try await req.authService.revokeOtherSessions(currentGrantID: payload.grantID, userID: userID)
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
