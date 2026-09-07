import Crypto
import Fluent
import FluentSQLiteDriver
import JWT
import Redis
import Vapor
import VaporTesting
import XCTest
@testable import FynnCloudServer

final class OAuthTests: XCTestCase {

    private func createTestApp() async throws -> Application {
        setenv("RATE_LIMIT_ENABLED", "false", 1)
        setenv("APP_NAME", "FynnCloud", 1)
        setenv("REGISTRATION_ENABLED", "true", 1)
        setenv("FRONTEND_URL", "http://localhost:3000", 1)

        let app = try await Application.make(.testing)
        app.databases.use(.sqlite(.memory), as: .sqlite)

        app.migrations.add(CreateInitialMigration())
        app.migrations.add(AddDisplayNameToUsers())
        app.migrations.add(CreateSyncLog())
        app.migrations.add(CreateOAuthCode())
        app.migrations.add(AddClientIdAndStateToOAuthCode())
        app.migrations.add(CreateOAuthGrant())
        app.migrations.add(UpdateGrantForRotation())
        app.migrations.add(AddGracePeriodToOAuthGrant())
        app.migrations.add(AddLastUsedAtToOAuthGrant())
        app.migrations.add(AddIPAddressToOAuthGrant())
        app.migrations.add(CreateMultipartUploadSessions())
        app.migrations.add(CreateGroups())
        app.migrations.add(CreateAppSettings())
        app.migrations.add(UpdateUnlimitedTier())
        app.migrations.add(AddIsAdminToGroups())
        app.migrations.add(AddAvatarUpdatedAtToUsers())
        app.migrations.add(LowercaseUsernames())
        app.migrations.add(AddIndicesToFileMetadata())
        app.migrations.add(AddTrashGroupToFileMetadata())
        app.migrations.add(RewriteSyncInfrastructure())
        app.migrations.add(CreateShareLinks())
        app.migrations.add(CreateFilenameSearchIndex())
        app.migrations.add(AddContentHashToFileMetadata())
        app.migrations.add(CreateFileEmbeddings())
        app.migrations.add(UpdateEmbeddingDimension())
        app.migrations.add(AddHasThumbnailToFileMetadata())
        app.migrations.add(CreateSubscriptions())
        app.migrations.add(AddLinkTypeAndRequiresAuthToShareLink())
        app.migrations.add(AddAncestorIDsToFileMetadata())
        app.migrations.add(AddUploadedAtToFileMetadata())
        app.migrations.add(OverhaulSyncInfrastructure())
        app.migrations.add(AddAllUsersGroup())
        app.migrations.add(RenameEuroOfficeUrlSetting())
        app.migrations.add(CreateUserIdentities())
        app.migrations.add(AddSSOManagedToGroups())
        app.migrations.add(AddSourceToUserGroups())
        app.migrations.add(CreateUserTOTP())
        app.migrations.add(CreateUserTOTPRecoveryCode())
        app.migrations.add(DropRecoveryCodesFromUserTOTP())
        app.migrations.add(AddSSOSourceToGroups())
        app.migrations.add(RenameSSOSourceToSourceOnGroups())
        app.migrations.add(DropOAuthCodes())
        app.migrations.add(DropMultipartUploadSessions())
        try await app.autoMigrate()

        let redisURL = Environment.get("REDIS_URL") ?? "redis://127.0.0.1:6379"
        if let redisConfig = try? RedisConfiguration(url: redisURL) {
            app.redis.configuration = redisConfig
        }

        await app.jwt.keys.add(hmac: HMACKey(from: "test_secret_key_12345678901234567890"), digestAlgorithm: .sha256)
        app.settings = SettingsService(database: app.db, redis: app.redis, logger: app.logger)
        app.config = try ServerConfig.load(for: app)
        app.fileStorage = TestStorage.createLocalProvider()
        app.subscription = SubscriptionService(envSubscriptionKey: nil, keys: JWTKeyCollection(), database: app.db)

        try routes(app)
        return app
    }

    func testOAuthLoginAndExchangeWithRedis() async throws {
        let app = try await createTestApp()
        defer {
            Task { try? await app.asyncShutdown() }
        }

        let tier = StorageTier(name: "Default", limitBytes: 10_000_000)
        try await tier.save(on: app.db)

        let passwordHash = try Bcrypt.hash("Secret123!")
        let user = User(
            username: "oauthuser",
            email: "oauth@example.com",
            passwordHash: passwordHash,
            tierID: try tier.requireID()
        )
        try await user.save(on: app.db)

        let verifier = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
        let challenge = SHA256.hash(data: Data(verifier.utf8)).base64URLEncoded()

        let loginDTO = LoginWithOAuthDTO(
            username: "oauthuser",
            password: "Secret123!",
            codeChallenge: challenge,
            clientId: "fynncloud-desktop",
            state: "randomstate123",
            redirectURI: "fynncloud://auth"
        )

        var emittedCode: String?
        try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req async throws in
            try req.content.encode(loginDTO)
        }) { res async throws in
            XCTAssertEqual(res.status, .ok)
            let authResponse = try res.content.decode(AuthorizeResponse.self)
            XCTAssertFalse(authResponse.totpRequired)
            XCTAssertNotNil(authResponse.code)
            emittedCode = authResponse.code
            XCTAssertTrue(authResponse.callbackURL.contains("code=\(authResponse.code!)"))
        }

        guard let code = emittedCode else {
            XCTFail("No code returned from login")
            return
        }

        let exchangeDTO = ExchangeDTO(
            code: code,
            code_verifier: verifier,
            clientId: "fynncloud-desktop"
        )

        try await app.testing().test(.POST, "api/auth/exchange", beforeRequest: { req async throws in
            try req.content.encode(exchangeDTO)
        }) { res async throws in
            XCTAssertEqual(res.status, .ok)
            let loginResponse = try res.content.decode(LoginResponse.self)
            XCTAssertFalse(loginResponse.accessToken.isEmpty)
            XCTAssertFalse(loginResponse.refreshToken.isEmpty)
            XCTAssertEqual(loginResponse.user.username, "oauthuser")
        }

        try await app.testing().test(.POST, "api/auth/exchange", beforeRequest: { req async throws in
            try req.content.encode(exchangeDTO)
        }) { res async in
            XCTAssertEqual(res.status, .unauthorized)
        }
    }

    func testListAndRevokeSessions() async throws {
        let app = try await createTestApp()
        defer { Task { try? await app.asyncShutdown() } }
        try await app.asyncBoot()

        let user = User(
            username: "sessionuser",
            email: "sessionuser@example.com",
            passwordHash: try Bcrypt.hash("Secret123!")
        )
        try await user.save(on: app.db)
        let userID = try user.requireID()

        // Create two grants for the user
        let grant1 = OAuthGrant(
            userID: userID,
            clientID: "fynncloud-web",
            userAgent: "Mozilla/5.0",
            ipAddress: "192.168.1.1"
        )
        try await grant1.save(on: app.db)
        let grant1ID = try grant1.requireID()

        let grant2 = OAuthGrant(
            userID: userID,
            clientID: "fynncloud-desktop",
            userAgent: "FynnCloudDesktop/1.0",
            ipAddress: "192.168.1.2"
        )
        try await grant2.save(on: app.db)
        let grant2ID = try grant2.requireID()

        // Buffer activity in Redis for grant2 (not current session so UserPayloadAuthenticator won't overwrite it)
        let bufferedTimestamp = Int64(Date().timeIntervalSince1970) + 100
        let buffer = SessionActivityBuffer(grantID: grant2ID, timestamp: bufferedTimestamp, ipAddress: "10.0.0.99")
        let bufferData = try JSONEncoder().encode(buffer)
        _ = try await app.redis.hset(grant2ID.uuidString, to: String(decoding: bufferData, as: UTF8.self), in: RedisKey("session_activity")).get()

        // Verify SessionActivityService.get directly (HMGET)
        let directActivity = await SessionActivityService.get(for: [grant1ID, grant2ID], on: app.redis)
        XCTAssertEqual(directActivity[grant2ID]?.ipAddress, "10.0.0.99")

        // Sign JWT token for grant1
        let payload = UserPayload(
            subject: .init(value: userID.uuidString),
            expiration: .init(value: Date().addingTimeInterval(3600)),
            grantID: grant1ID,
            jti: .init(value: UUID().uuidString)
        )
        let token = try await app.jwt.keys.sign(payload)

        // GET /api/auth/sessions
        try await app.testing().test(.GET, "api/auth/sessions", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: token)
        }) { res async throws in
            XCTAssertEqual(res.status, .ok)
            let sessions = try res.content.decode([SessionResponse].self)
            XCTAssertEqual(sessions.count, 2)

            let session1 = sessions.first { $0.id == grant1ID }
            XCTAssertNotNil(session1)
            XCTAssertTrue(session1?.isCurrent == true)

            let session2 = sessions.first { $0.id == grant2ID }
            XCTAssertNotNil(session2)
            XCTAssertFalse(session2?.isCurrent == true)
            XCTAssertEqual(session2?.ipAddress, "10.0.0.99", "Buffered IP in Redis should take precedence for grant2")
            XCTAssertEqual(session2?.lastUsedAt, Date(timeIntervalSince1970: Double(bufferedTimestamp)))
        }

        // DELETE /api/auth/sessions/:grantID (revoke grant2)
        try await app.testing().test(.DELETE, "api/auth/sessions/\(grant2ID)", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: token)
        }) { res async in
            XCTAssertEqual(res.status, .noContent)
        }

        // Verify grant2 is gone
        try await app.testing().test(.GET, "api/auth/sessions", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: token)
        }) { res async throws in
            XCTAssertEqual(res.status, .ok)
            let sessions = try res.content.decode([SessionResponse].self)
            XCTAssertEqual(sessions.count, 1)
            XCTAssertEqual(sessions.first?.id, grant1ID)
        }

        // DELETE /api/auth/sessions (revoke other sessions)
        try await app.testing().test(.DELETE, "api/auth/sessions", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: token)
        }) { res async in
            XCTAssertEqual(res.status, .noContent)
        }
    }

    override func tearDown() {
        unsetenv("RATE_LIMIT_ENABLED")
        unsetenv("APP_NAME")
        unsetenv("REGISTRATION_ENABLED")
        unsetenv("FRONTEND_URL")
        super.tearDown()
    }
}
