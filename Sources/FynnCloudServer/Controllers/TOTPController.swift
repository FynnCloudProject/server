import Fluent
import Vapor

/// Manages a user's TOTP two-factor enrollment: starting setup, confirming/enabling,
/// disabling, and regenerating recovery codes. Login-time verification lives in `AuthController`.
struct TOTPController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let totp = routes.grouped("api", "auth", "totp")
            .grouped(UserPayloadAuthenticator(), UserPayload.guardMiddleware())

        totp.get("status", use: status)
        totp.post("setup", use: setup)
        totp.post("enable", use: enable)
        totp.post("disable", use: disable)
        totp.post("recovery-codes", use: regenerateRecoveryCodes)
    }

    func status(req: Request) async throws -> TOTPStatusResponse {
        let userID = try req.auth.require(UserPayload.self).getID()
        let record = try await UserTOTP.query(on: req.db)
            .filter(\.$user.$id == userID)
            .first()
        let remaining = try await record?.remainingRecoveryCodeCount(on: req.db) ?? 0
        return TOTPStatusResponse(
            enabled: record?.isEnabled ?? false,
            remainingRecoveryCodes: remaining
        )
    }

    /// Creates (or replaces, while still unconfirmed) a pending secret and returns the
    /// provisioning details for the authenticator QR code. Stateless: no DB row is written here,
    /// so an abandoned setup leaves nothing behind. The secret is confirmed in `enable`.
    func setup(req: Request) async throws -> TOTPSetupResponse {
        let user = try await req.getFullUser()
        let userID = try user.requireID()

        let alreadyEnabled = try await UserTOTP.query(on: req.db)
            .filter(\.$user.$id == userID)
            .filter(\.$isEnabled == true)
            .first() != nil
        if alreadyEnabled {
            throw Abort(.conflict, reason: "Two-factor is already enabled")
                .localized(LocalizationKeys.Error.Auth.TotpAlreadyEnabled)
        }

        let secret = TOTP.generateSecret()
        let issuer = (try? await req.application.settings.get(AppSettings.AppName.self))
            ?? AppSettings.AppName.defaultValue
        let account = user.email.isEmpty ? user.username : user.email
        let uri = TOTP.provisioningURI(secret: secret, account: account, issuer: issuer)

        return TOTPSetupResponse(secret: secret, otpauthURL: uri)
    }

    /// Confirms the client-supplied secret with a live code, then persists the enabled row and
    /// issues recovery codes. This is the first and only point a `UserTOTP` row is created.
    func enable(req: Request) async throws -> TOTPRecoveryCodesResponse {
        let userID = try req.auth.require(UserPayload.self).getID()
        let dto = try req.content.decode(TOTPEnableDTO.self)

        let existing = try await UserTOTP.query(on: req.db)
            .filter(\.$user.$id == userID)
            .first()
        if let existing, existing.isEnabled {
            throw Abort(.conflict, reason: "Two-factor is already enabled")
                .localized(LocalizationKeys.Error.Auth.TotpAlreadyEnabled)
        }

        guard TOTP.verify(code: dto.code, secret: dto.secret) else {
            throw Abort(.unauthorized, reason: "Invalid authentication code")
                .localized(LocalizationKeys.Error.Auth.TotpInvalid)
        }

        let plaintext = TOTP.generateRecoveryCodes()
        let record = existing ?? UserTOTP(userID: userID, secret: dto.secret)
        // Atomic: the enabled row and its recovery codes must commit together, so a failure
        // never leaves a half-enabled row with no codes.
        try await req.db.transaction { db in
            record.secret = try req.secretBox.encrypt(dto.secret)
            record.isEnabled = true
            record.confirmedAt = Date()
            try await record.save(on: db)
            try await record.resetRecoveryCodes(plaintext, on: db)
        }

        req.logger(subsystem: .auth).info(
            "Two-factor authentication enabled",
            metadata: ["user_id": .stringConvertible(userID)]
        )

        return TOTPRecoveryCodesResponse(recoveryCodes: plaintext)
    }

    /// Disables and removes 2FA after confirming identity with a code or the account password.
    func disable(req: Request) async throws -> HTTPStatus {
        let user = try await req.getFullUser()
        let userID = try user.requireID()
        let dto = try req.content.decode(TOTPDisableDTO.self)

        guard
            let record = try await UserTOTP.query(on: req.db)
                .filter(\.$user.$id == userID)
                .first(), record.isEnabled
        else {
            throw Abort(.badRequest, reason: "Two-factor is not enabled")
                .localized(LocalizationKeys.Error.Auth.TotpNotEnabled)
        }

        let codeValid = dto.code.map { TOTP.verify(code: $0, secret: (try? req.secretBox.decrypt(record.secret)) ?? record.secret) } ?? false
        let passwordValid = dto.password.flatMap { try? user.verify(password: $0) } ?? false
        guard codeValid || passwordValid else {
            throw Abort(.unauthorized, reason: "Invalid authentication code")
                .localized(LocalizationKeys.Error.Auth.TotpInvalid)
        }

        try await record.delete(on: req.db)

        req.logger(subsystem: .auth).info(
            "Two-factor authentication disabled",
            metadata: ["user_id": .stringConvertible(userID)]
        )

        return .noContent
    }

    /// Issues a fresh set of recovery codes (invalidating the old ones) after a valid code.
    func regenerateRecoveryCodes(req: Request) async throws -> TOTPRecoveryCodesResponse {
        let userID = try req.auth.require(UserPayload.self).getID()
        let dto = try req.content.decode(TOTPCodeDTO.self)

        guard
            let record = try await UserTOTP.query(on: req.db)
                .filter(\.$user.$id == userID)
                .first(), record.isEnabled
        else {
            throw Abort(.badRequest, reason: "Two-factor is not enabled")
                .localized(LocalizationKeys.Error.Auth.TotpNotEnabled)
        }

        guard TOTP.verify(code: dto.code, secret: try req.secretBox.decrypt(record.secret)) else {
            throw Abort(.unauthorized, reason: "Invalid authentication code")
                .localized(LocalizationKeys.Error.Auth.TotpInvalid)
        }

        let plaintext = TOTP.generateRecoveryCodes()
        try await req.db.transaction { db in
            try await record.resetRecoveryCodes(plaintext, on: db)
        }

        req.logger(subsystem: .auth).info(
            "Two-factor recovery codes regenerated",
            metadata: ["user_id": .stringConvertible(userID)]
        )

        return TOTPRecoveryCodesResponse(recoveryCodes: plaintext)
    }
}
