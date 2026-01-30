import Crypto
import Fluent
import Foundation
import JWT
import Vapor

struct AuthController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let api = routes.grouped("api", "auth")

        // PUBLIC
        api.post("login", use: login)
        api.post("register", use: register)
        api.post("exchange", use: exchange)
        api.post("refresh", use: refresh)

        // PROTECTED (Requires Valid JWT + Existing Grant)
        let protected = api.grouped(UserPayloadAuthenticator(), UserPayload.guardMiddleware())

        protected.post("logout", use: logout)

        protected.post("authorize", use: authorizePost)

        // List and Revoke sessions
        protected.get("sessions", use: listSessions)
        protected.delete("sessions", ":grantID", use: revokeSession)
    }

    // MARK: - Login (Web Interface)

    func login(req: Request) async throws -> AuthorizeResponse {
        let loginData = try req.content.decode(LoginWithOAuthDTO.self)

        // Verify credentials
        guard
            let user = try await User.query(on: req.db)
                .filter(\.$username == loginData.username)
                .first(),
            try user.verify(password: loginData.password)
        else {
            throw Abort(.unauthorized, reason: "Invalid credentials")
        }

        // Only allow specific redirect URIs
        let frontendURL = Environment.get("FRONTEND_URL") ?? "http://localhost"
        let allowedURIs = [
            "fynncloud://auth",
            "\(frontendURL)/auth/callback",
        ]

        let targetURI = loginData.redirectURI ?? "\(frontendURL)/auth/callback"
        guard allowedURIs.contains(targetURI) else {
            throw Abort(.badRequest, reason: "Unauthorized redirect URI")
        }

        // Create the One-Time OAuth Code
        let oauthCode = OAuthCode(
            userID: try user.requireID(),
            codeChallenge: loginData.codeChallenge,
            expiresAt: Date().addingTimeInterval(300),  // 5 minutes
            clientID: loginData.clientId,
            state: loginData.state
        )
        try await oauthCode.save(on: req.db)

        // Construct the Callback URL (technically unused for the web interface)
        var components = URLComponents(string: targetURI)
        var queryItems = components?.queryItems ?? []
        queryItems.append(URLQueryItem(name: "code", value: oauthCode.id!.uuidString))

        if let state = loginData.state {
            queryItems.append(URLQueryItem(name: "state", value: state))
        }
        components?.queryItems = queryItems

        guard let finalURL = components?.string else {
            throw Abort(.internalServerError)
        }

        // Return both for flexibility (Web can use code directly, Apps might use callbackURL if needed)
        return AuthorizeResponse(callbackURL: finalURL, code: oauthCode.id!.uuidString)
    }

    // MARK: - OAuth Exchange (Desktop/Apps)

    func exchange(req: Request) async throws -> Response {
        let dto = try req.content.decode(ExchangeDTO.self)

        guard
            let oauthCode = try await OAuthCode.query(on: req.db)
                .filter(\.$id == dto.code)
                .with(\.$user)
                .first(),
            oauthCode.expiresAt > Date()
        else {
            throw Abort(.unauthorized, reason: "Code expired or invalid")
        }

        let hashedVerifier = SHA256.hash(data: Data(dto.code_verifier.utf8)).base64URLEncoded()
        guard hashedVerifier == oauthCode.codeChallenge else {
            throw Abort(.unauthorized, reason: "Invalid verifier")
        }

        guard dto.clientId == oauthCode.clientID else {
            throw Abort(.unauthorized, reason: "Client ID mismatch")
        }

        let user = oauthCode.user
        let userID = try user.requireID()

        // Create unique grant
        let grant = OAuthGrant(
            userID: userID,
            clientID: oauthCode.clientID,
            userAgent: req.headers["User-Agent"].first ?? "",
        )
        try await grant.save(on: req.db)

        // Delete code so no reuse and db stays fairly clean
        try await oauthCode.delete(on: req.db)

        // Generate new tokens
        let loginResponse = try await generateTokens(for: grant, req: req, user: user)
        let isWeb = oauthCode.clientID == "fynncloud-web"

        // Same as in refresh, ensure SPA never sees an actual token
        let response =
            !isWeb
            ? try await loginResponse.encodeResponse(for: req)
            : try await user.toPublic().encodeResponse(for: req)

        // Set HTTP-only cookies (for web clients)
        if isWeb {
            setAuthCookies(
                response: response, accessToken: loginResponse.accessToken,
                refreshToken: loginResponse.refreshToken)
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
            throw Abort(.unauthorized, reason: "No refresh token found")
        }

        let payload = try await req.jwt.verify(refreshToken, as: UserPayload.self)

        // Fetch the grant
        guard let grant = try await OAuthGrant.find(payload.grantID, on: req.db) else {
            throw Abort(.unauthorized, reason: "Session revoked")
        }

        // Check if the token is the current refresh token based on the jti to prevent reuse attacks
        guard UUID(uuidString: payload.jti.value) == grant.currentRefreshTokenID else {
            // Revoke the whole session (grant) to be safe on reuse of a refresh token
            try await grant.delete(on: req.db)
            throw Abort(.unauthorized, reason: "Token reuse detected. Session terminated.")
        }

        guard let user = try await User.find(grant.$user.id, on: req.db) else {
            throw Abort(.unauthorized)
        }

        // Generate new tokens
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
                refreshToken: loginResponse.refreshToken)
        }

        return response
    }
    // MARK: - Token Helpers

    private func generateTokens(for grant: OAuthGrant, req: Request, user: User) async throws
        -> LoginResponse
    {
        let grantID = try grant.requireID()
        let userID = try user.requireID()
        let newRefreshTokenID = UUID()  // The "jti" for the new refresh token

        // Access Token
        let accessPayload = UserPayload(
            subject: .init(value: userID.uuidString),
            expiration: .init(value: Date().addingTimeInterval(60 * 15)),
            grantID: grantID,
            jti: .init(value: UUID().uuidString)
        )

        // Refresh Token, longer validity for desktop apps
        let refreshDuration: TimeInterval = (grant.clientID != "fynncloud-web") ? 2_592_000 : 604800
        let refreshPayload = UserPayload(
            subject: .init(value: userID.uuidString),
            expiration: .init(value: Date().addingTimeInterval(refreshDuration)),
            grantID: grantID,
            jti: .init(value: newRefreshTokenID.uuidString)
        )

        // Store the new refresh token jti as the current one
        grant.currentRefreshTokenID = newRefreshTokenID
        try await grant.save(on: req.db)

        return try await LoginResponse(
            accessToken: req.jwt.sign(accessPayload),
            refreshToken: req.jwt.sign(refreshPayload),
            user: user.toPublic()
        )
    }

    // MARK: - Cookie Helpers

    private func setAuthCookies(response: Response, accessToken: String, refreshToken: String) {
        let isProduction = Environment.get("ENVIRONMENT") == "production"
        let refreshDuration: TimeInterval = 604800

        // Access Token Cookie (15 minutes)
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

        // Refresh Token Cookie (7 days for web, 30 days for apps)
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
    }

    private func clearAuthCookies(response: Response) {
        // Clear cookies by setting them to expire immediately
        response.cookies["accessToken"] = HTTPCookies.Value(
            string: "",
            expires: Date(timeIntervalSince1970: 0),
            maxAge: 0,
            domain: nil,
            path: "/",
            isSecure: Environment.get("ENVIRONMENT") == "production",
            isHTTPOnly: true,
            sameSite: .lax
        )

        response.cookies["refreshToken"] = HTTPCookies.Value(
            string: "",
            expires: Date(timeIntervalSince1970: 0),
            maxAge: 0,
            domain: nil,
            path: "/",
            isSecure: Environment.get("ENVIRONMENT") == "production",
            isHTTPOnly: true,
            sameSite: .lax
        )
    }

    // MARK: - Session Management

    func logout(req: Request) async throws -> Response {
        let payload = try req.auth.require(UserPayload.self)

        // Only deletes the grant associated with the current token
        try await OAuthGrant.query(on: req.db)
            .filter(\.$id == payload.grantID)
            .delete()

        // Create response and clear cookies
        let response = Response(status: .ok)
        clearAuthCookies(response: response)

        return response
    }

    func listSessions(req: Request) async throws -> [OAuthGrant] {
        let payload = try req.auth.require(UserPayload.self)
        guard let userID = UUID(uuidString: payload.subject.value) else {
            throw Abort(.unauthorized)
        }

        return try await OAuthGrant.query(on: req.db)
            .filter(\.$user.$id == userID)
            .all()
    }

    func revokeSession(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(UserPayload.self)
        guard let userID = UUID(uuidString: payload.subject.value) else {
            throw Abort(.unauthorized)
        }
        guard let targetGrantID = req.parameters.get("grantID", as: UUID.self) else {
            throw Abort(.badRequest)
        }

        // Ensure the user owns the grant they are trying to revoke
        try await OAuthGrant.query(on: req.db)
            .filter(\.$id == targetGrantID)
            .filter(\.$user.$id == userID)
            .delete()

        return .noContent
    }

    // MARK: - Registration & Utilities

    func register(req: Request) async throws -> User.Public {
        let registerData = try req.content.decode(RegisterDTO.self)
        if registerData.password != registerData.confirmPassword {
            throw Abort(.badRequest, reason: "Passwords do not match")
        }

        let passwordHash = try Bcrypt.hash(registerData.password)
        guard
            let freeTier = try await StorageTier.query(on: req.db).filter(\.$name == "Free").first()
        else {
            throw Abort(.internalServerError, reason: "Storage tier not found")
        }

        let user = User(
            username: registerData.username, email: registerData.email, passwordHash: passwordHash,
            tierID: freeTier.id)
        try await user.save(on: req.db)
        return try user.toPublic()
    }

    func authorizePost(req: Request) async throws -> AuthorizeResponse {
        let payload = try req.auth.require(UserPayload.self)
        guard let userID = UUID(uuidString: payload.subject.value) else {
            throw Abort(.unauthorized)
        }
        let dto = try req.content.decode(AuthorizeDTO.self)

        let oauthCode = OAuthCode(
            userID: userID,
            codeChallenge: dto.codeChallenge,
            expiresAt: Date().addingTimeInterval(300),
            clientID: dto.clientId,
            state: dto.state
        )
        try await oauthCode.save(on: req.db)

        let allowedURIs = [
            "fynncloud://auth", "\(Environment.get("FRONTEND_URL") ?? "")/auth/callback",
        ]
        let baseCallback = dto.redirectURI ?? "fynncloud://auth"

        guard allowedURIs.contains(baseCallback) else {
            throw Abort(.badRequest, reason: "Unauthorized redirect URI")
        }

        var components = URLComponents(string: baseCallback)
        var queryItems = components?.queryItems ?? []
        queryItems.append(URLQueryItem(name: "code", value: oauthCode.id!.uuidString))
        if let state = dto.state { queryItems.append(URLQueryItem(name: "state", value: state)) }
        components?.queryItems = queryItems

        return AuthorizeResponse(
            callbackURL: components?.string ?? "", code: oauthCode.id!.uuidString)
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
