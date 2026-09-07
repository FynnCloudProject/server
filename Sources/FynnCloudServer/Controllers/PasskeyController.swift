import Fluent
import Foundation
import Redis
import Vapor
import WebAuthn

extension PublicKeyCredentialCreationOptions: @retroactive Content {}
extension PublicKeyCredentialRequestOptions: @retroactive Content {}
extension RegistrationCredential: @retroactive Content {}
extension AuthenticationCredential: @retroactive Content {}

struct PasskeyController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let passkeys = routes.grouped("api", "auth", "passkeys")
        let publicPasskeys = passkeys.grouped(RateLimitMiddleware(category: .auth))

        // Public authentication ceremony
        publicPasskeys.post("login", "start", use: loginStart)
        publicPasskeys.post("login", "finish", use: loginFinish)

        // Protected registration & management ceremonies
        let protected = passkeys.grouped(UserPayloadAuthenticator(), UserPayload.guardMiddleware())

        protected.get(use: listPasskeys)
        protected.post("register", "start", use: registerStart)
        protected.post("register", "finish", use: registerFinish)
        protected.patch(":passkeyID", use: renamePasskey)
        protected.delete(":passkeyID", use: deletePasskey)
    }

    // MARK: - DTOs

    struct LoginStartDTO: Content {
        let username: String?
    }

    struct LoginFinishDTO: Content {
        let credential: AuthenticationCredential
        let clientId: String
        let codeChallenge: String
        let redirectURI: String?
        let state: String?
    }

    struct RegisterFinishDTO: Content {
        let credential: RegistrationCredential
        let nickname: String?
    }

    struct RenameDTO: Content {
        let nickname: String
    }

    // MARK: - Handlers

    func loginStart(req: Request) async throws -> PublicKeyCredentialRequestOptions {
        let dto = try? req.content.decode(LoginStartDTO.self)
        return try await PasskeyService.beginAuthentication(username: dto?.username, req: req)
    }

    func loginFinish(req: Request) async throws -> AuthorizeResponse {
        let dto = try req.content.decode(LoginFinishDTO.self)

        guard AuthController.allowedClientIDs.contains(dto.clientId) else {
            throw Abort(.badRequest, reason: "Invalid client ID").localized(
                LocalizationKeys.Error.Auth.InvalidClientId)
        }

        let (user, _) = try await PasskeyService.finishAuthentication(credential: dto.credential, req: req)
        let userID = try user.requireID()

        let frontendURL = req.application.config.frontendURL
        return try await OAuthCodeService.issueCode(
            userID: userID,
            codeChallenge: dto.codeChallenge,
            clientID: dto.clientId,
            state: dto.state,
            redirectURI: dto.redirectURI,
            defaultRedirectURI: "\(frontendURL)/auth/callback",
            req: req
        )
    }

    func listPasskeys(req: Request) async throws -> [UserPasskey.PublicDTO] {
        let userID = try req.auth.require(UserPayload.self).getID()
        let passkeys = try await UserPasskey.query(on: req.db)
            .filter(\.$user.$id == userID)
            .sort(\.$createdAt, .descending)
            .all()

        return try passkeys.map { try $0.toPublicDTO() }
    }

    func registerStart(req: Request) async throws -> PublicKeyCredentialCreationOptions {
        let user = try await req.getFullUser()
        return try await PasskeyService.beginRegistration(user: user, req: req)
    }

    func registerFinish(req: Request) async throws -> UserPasskey.PublicDTO {
        let user = try await req.getFullUser()
        let dto = try req.content.decode(RegisterFinishDTO.self)
        let passkey = try await PasskeyService.finishRegistration(
            user: user,
            credential: dto.credential,
            nickname: dto.nickname,
            req: req
        )
        return try passkey.toPublicDTO()
    }

    func renamePasskey(req: Request) async throws -> UserPasskey.PublicDTO {
        let userID = try req.auth.require(UserPayload.self).getID()
        guard let passkeyID = req.parameters.get("passkeyID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid passkey ID")
        }

        let dto = try req.content.decode(RenameDTO.self)
        let trimmed = dto.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Abort(.badRequest, reason: "Nickname cannot be empty")
        }

        guard let passkey = try await UserPasskey.query(on: req.db)
            .filter(\.$id == passkeyID)
            .filter(\.$user.$id == userID)
            .first() else {
            throw Abort(.notFound, reason: "Passkey not found")
        }

        passkey.nickname = trimmed
        try await passkey.save(on: req.db)
        return try passkey.toPublicDTO()
    }

    func deletePasskey(req: Request) async throws -> HTTPStatus {
        let userID = try req.auth.require(UserPayload.self).getID()
        guard let passkeyID = req.parameters.get("passkeyID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid passkey ID")
        }

        guard let passkey = try await UserPasskey.query(on: req.db)
            .filter(\.$id == passkeyID)
            .filter(\.$user.$id == userID)
            .first() else {
            throw Abort(.notFound, reason: "Passkey not found")
        }

        try await passkey.delete(on: req.db)

        req.logger(subsystem: .auth).info(
            "Passkey revoked",
            metadata: [
                "user_id": .stringConvertible(userID),
                "passkey_id": .stringConvertible(passkeyID),
            ]
        )

        return .noContent
    }
}
