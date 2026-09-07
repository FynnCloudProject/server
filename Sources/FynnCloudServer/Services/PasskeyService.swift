import Fluent
import Foundation
import Redis
import Vapor
import WebAuthn

struct PasskeyService: Sendable {
    static let challengeTTLSeconds = 180

    /// The URL-safe and standard base64 encodings a stored `credential_id` might be saved under.
    private static func credentialIDVariants(_ id: URLEncodedBase64) -> (urlEncoded: String, standard: String) {
        (id.asString(), id.urlDecoded.asString())
    }

    /// Looks up the passkey matching either encoding of a WebAuthn credential ID.
    private static func passkeyQuery(matching id: URLEncodedBase64, on db: any Database) -> QueryBuilder<UserPasskey> {
        let (urlEncoded, standard) = credentialIDVariants(id)
        return UserPasskey.query(on: db).group(.or) { group in
            group.filter(\.$credentialID == urlEncoded)
            group.filter(\.$credentialID == standard)
        }
    }

    /// Returns a configured WebAuthnManager based on current server settings and request context.
    static func getWebAuthnManager(req: Request) async -> WebAuthnManager {
        let frontendURL = req.application.config.frontendURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackOrigin = frontendURL.hasSuffix("/") ? String(frontendURL.dropLast()) : frontendURL

        let headerOrigin = req.headers.first(name: .origin)
            ?? req.headers.first(name: .referer).flatMap { ref in
                guard let url = URL(string: ref), let scheme = url.scheme, let host = url.host else { return nil }
                if let port = url.port {
                    return "\(scheme)://\(host):\(port)"
                } else {
                    return "\(scheme)://\(host)"
                }
            }

        var resolvedOrigin = fallbackOrigin
        if let headerOrigin = headerOrigin?.trimmingCharacters(in: .whitespacesAndNewlines), !headerOrigin.isEmpty {
            let normalizedHeader = headerOrigin.hasSuffix("/") ? String(headerOrigin.dropLast()) : headerOrigin
            // Match on the parsed host, never on substrings: "https://localhost.attacker.com"
            // contains "localhost". A CORS "*" must not confer relying-party trust either.
            let host = URL(string: normalizedHeader)?.host?.lowercased()
            let isLoopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host ?? "")
            let isAllowed = normalizedHeader == fallbackOrigin
                || req.application.config.corsAllowedOrigins.contains(normalizedHeader)
                || (isLoopback && !req.application.environment.isRelease)

            if isAllowed {
                resolvedOrigin = normalizedHeader
            } else {
                req.logger(subsystem: .auth).warning(
                    "Rejected untrusted WebAuthn origin",
                    metadata: ["origin": .string(normalizedHeader)]
                )
            }
        }

        let rpID: String
        if let host = URL(string: resolvedOrigin)?.host, !host.isEmpty {
            rpID = host
        } else if let fallbackHost = URL(string: fallbackOrigin)?.host, !fallbackHost.isEmpty {
            rpID = fallbackHost
        } else {
            rpID = "localhost"
        }

        let appName = (try? await req.application.settings.get(AppSettings.AppName.self))
            ?? AppSettings.AppName.defaultValue

        let config = WebAuthnManager.Configuration(
            relyingPartyID: rpID,
            relyingPartyName: appName,
            relyingPartyOrigin: resolvedOrigin
        )
        return WebAuthnManager(configuration: config)
    }

    // MARK: - Registration Ceremonies

    /// Generates creation options for registering a new passkey and caches the challenge.
    static func beginRegistration(user: User, req: Request) async throws -> PublicKeyCredentialCreationOptions {
        let userID = try user.requireID()
        let manager = await getWebAuthnManager(req: req)

        let userEntity = PublicKeyCredentialUserEntity(
            id: [UInt8](userID.uuidString.utf8),
            name: user.username,
            displayName: (user.displayName?.isEmpty == false ? user.displayName : nil) ?? user.username
        )

        let options = manager.beginRegistration(
            user: userEntity,
            timeout: .seconds(challengeTTLSeconds),
            attestation: .none
        )

        // Store the raw challenge in Redis with TTL
        let challengeKey = RedisKey("auth:passkey:reg:\(userID.uuidString)")
        let challengeBase64 = options.challenge.base64URLEncodedString().asString()
        _ = try await req.redis.set(challengeKey, to: challengeBase64).get()
        _ = try await req.redis.expire(challengeKey, after: .seconds(Int64(challengeTTLSeconds))).get()

        return options
    }

    /// Validates the client attestation response, verifies the challenge, and persists the new passkey.
    static func finishRegistration(
        user: User,
        credential: RegistrationCredential,
        nickname: String?,
        req: Request
    ) async throws -> UserPasskey {
        let userID = try user.requireID()
        let manager = await getWebAuthnManager(req: req)

        let challengeKey = RedisKey("auth:passkey:reg:\(userID.uuidString)")
        guard let challengeString = try await req.redis.get(challengeKey, as: String.self).get(),
              let challengeBytes = URLEncodedBase64(challengeString).decodedBytes else {
            throw Abort(.badRequest, reason: "Registration challenge expired or not found")
                .localized(LocalizationKeys.Error.Auth.PasskeyRegistrationFailed)
        }

        let credentialIDBase64URL = credentialIDVariants(credential.id).urlEncoded

        let verifiedCredential = try await manager.finishRegistration(
            challenge: challengeBytes,
            credentialCreationData: credential,
            requireUserVerification: false,
            confirmCredentialIDNotRegisteredYet: { _ in
                // The library always calls back with credential.id.asString(), i.e. credentialIDBase64URL.
                try await passkeyQuery(matching: credential.id, on: req.db).count() == 0
            }
        )

        // Clean up challenge after successful verification
        _ = try await req.redis.delete(challengeKey).get()

        let defaultNickname = nickname?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? nickname!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "Passkey (\(Date().formatted(date: .abbreviated, time: .shortened)))"

        let passkey = UserPasskey(
            userID: userID,
            credentialID: credentialIDBase64URL,
            publicKey: Data(verifiedCredential.publicKey),
            currentSignCount: Int64(verifiedCredential.signCount),
            nickname: defaultNickname,
            aaguid: nil,
            transports: nil
        )

        try await passkey.save(on: req.db)

        req.logger(subsystem: .auth).info(
            "Passkey registered successfully",
            metadata: [
                "user_id": .stringConvertible(userID),
                "credential_id": .string(passkey.credentialID),
                "nickname": .string(passkey.nickname),
            ]
        )

        return passkey
    }

    // MARK: - Authentication Ceremonies

    /// Generates authentication options for signing in with a passkey and caches the challenge.
    static func beginAuthentication(username: String?, req: Request) async throws -> PublicKeyCredentialRequestOptions {
        let manager = await getWebAuthnManager(req: req)
        var descriptors: [PublicKeyCredentialDescriptor]? = nil

        if let username = username?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !username.isEmpty {
            if let user = try await User.query(on: req.db).filter(\.$username == username).first() {
                let passkeys = try await UserPasskey.query(on: req.db)
                    .filter(\.$user.$id == user.requireID())
                    .all()

                if !passkeys.isEmpty {
                    descriptors = passkeys.compactMap { passkey in
                        guard let idBytes = URLEncodedBase64(passkey.credentialID).decodedBytes else { return nil }
                        let transports = passkey.transportsList.map {
                            PublicKeyCredentialDescriptor.AuthenticatorTransport($0)
                        }
                        return PublicKeyCredentialDescriptor(
                            type: .publicKey,
                            id: idBytes,
                            transports: transports
                        )
                    }
                }
            }
        }

        let options = manager.beginAuthentication(
            timeout: .seconds(challengeTTLSeconds),
            allowCredentials: descriptors
        )

        let challengeBase64 = options.challenge.base64URLEncodedString().asString()
        let challengeKey = RedisKey("auth:passkey:auth:\(challengeBase64)")
        _ = try await req.redis.set(challengeKey, to: challengeBase64).get()
        _ = try await req.redis.expire(challengeKey, after: .seconds(Int64(challengeTTLSeconds))).get()

        return options
    }

    /// Verifies the assertion signature and returns the authenticated user and updated passkey.
    static func finishAuthentication(
        credential: AuthenticationCredential,
        req: Request
    ) async throws -> (user: User, passkey: UserPasskey) {
        let manager = await getWebAuthnManager(req: req)

        // Parse challenge from clientDataJSON to retrieve cached challenge
        guard let clientData = try? JSONDecoder().decode(CollectedClientData.self, from: Data(credential.response.clientDataJSON)) else {
            throw Abort(.badRequest, reason: "Invalid clientDataJSON")
                .localized(LocalizationKeys.Error.Auth.PasskeyInvalid)
        }

        let challengeString = clientData.challenge.asString()
        let challengeKey = RedisKey("auth:passkey:auth:\(challengeString)")
        guard let storedChallenge = try await req.redis.get(challengeKey, as: String.self).get(),
              let challengeBytes = URLEncodedBase64(storedChallenge).decodedBytes else {
            throw Abort(.unauthorized, reason: "Authentication challenge expired or invalid")
                .localized(LocalizationKeys.Error.Auth.PasskeyInvalid)
        }

        guard let passkey = try await passkeyQuery(matching: credential.id, on: req.db)
            .with(\.$user)
            .first() else {
            throw Abort(.unauthorized, reason: "Passkey not found or revoked")
                .localized(LocalizationKeys.Error.Auth.PasskeyNotFound)
        }

        let verified = try manager.finishAuthentication(
            credential: credential,
            expectedChallenge: challengeBytes,
            credentialPublicKey: [UInt8](passkey.publicKey),
            credentialCurrentSignCount: UInt32(max(0, passkey.currentSignCount)),
            requireUserVerification: false
        )

        // Update signature counter and last used timestamp
        passkey.currentSignCount = Int64(verified.newSignCount)
        passkey.lastUsedAt = Date()
        try await passkey.save(on: req.db)

        // Invalidate challenge
        _ = try await req.redis.delete(challengeKey).get()

        let authedUserID = try passkey.user.requireID()
        req.logger(subsystem: .auth).info(
            "User authenticated with passkey",
            metadata: [
                "user_id": .stringConvertible(authedUserID),
                "username": .string(passkey.user.username),
                "credential_id": .string(passkey.credentialID),
                "ip": .string(req.clientIP),
            ]
        )

        return (user: passkey.user, passkey: passkey)
    }
}
