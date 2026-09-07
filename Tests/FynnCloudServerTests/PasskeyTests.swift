import Crypto
import Fluent
import FluentSQLiteDriver
import JWT
import Redis
import Vapor
import VaporTesting
import WebAuthn
import XCTest
@testable import FynnCloudServer

final class PasskeyTests: XCTestCase {
    private var app: Application!

    override func setUp() async throws {
        setenv("RATE_LIMIT_ENABLED", "false", 1)
        setenv("APP_NAME", "FynnCloud", 1)
        setenv("REGISTRATION_ENABLED", "true", 1)
        setenv("FRONTEND_URL", "http://localhost:3000", 1)
        setenv("ENCRYPTION_KEY", "MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE=", 1)

        app = try await Application.make(.testing)
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
        app.migrations.add(CreateInternalShares())
        app.migrations.add(DropOAuthCodes())
        app.migrations.add(DropMultipartUploadSessions())
        app.migrations.add(CreateUserPasskeys())

        try await app.autoMigrate()

        let redisURL = Environment.get("REDIS_URL") ?? "redis://127.0.0.1:6379"
        if let redisConfig = try? RedisConfiguration(url: redisURL) {
            app.redis.configuration = redisConfig
        }

        let config = try ServerConfig.load(for: app)
        app.config = config

        await app.jwt.keys.add(hmac: HMACKey(from: "test_secret_1234567890_1234567890"), digestAlgorithm: .sha256)
        app.settings = SettingsService(database: app.db, redis: app.redis, logger: app.logger)

        try routes(app)
    }

    override func tearDown() async throws {
        unsetenv("RATE_LIMIT_ENABLED")
        unsetenv("APP_NAME")
        unsetenv("REGISTRATION_ENABLED")
        unsetenv("FRONTEND_URL")
        unsetenv("ENCRYPTION_KEY")
        try await app.asyncShutdown()
    }

    private func createTestUser(username: String = "passkeyuser") async throws -> User {
        let passwordHash = try Bcrypt.hash("TestPassword123!")
        let user = User(username: username, email: "\(username)@example.com", passwordHash: passwordHash)
        try await user.save(on: app.db)
        return user
    }

    private func makeAuthHeader(for user: User) async throws -> [String: String] {
        let userID = try user.requireID()
        let grant = OAuthGrant(
            userID: userID,
            clientID: "fynncloud-web",
            userAgent: "TestAgent",
            ipAddress: "127.0.0.1"
        )
        try await grant.save(on: app.db)
        let grantID = try grant.requireID()

        let payload = UserPayload(
            subject: .init(value: userID.uuidString),
            expiration: .init(value: Date().addingTimeInterval(3600)),
            grantID: grantID,
            jti: .init(value: UUID().uuidString)
        )
        let token = try await app.jwt.keys.sign(payload)
        return ["Authorization": "Bearer \(token)"]
    }

    func testPasskeyLoginStartWithoutUsername() async throws {
        try await app.testing().test(.POST, "api/auth/passkeys/login/start") { res in
            XCTAssertEqual(res.status, .ok)
            let options = try res.content.decode(PublicKeyCredentialRequestOptions.self)
            XCTAssertFalse(options.challenge.isEmpty)
            XCTAssertEqual(options.relyingPartyID, "localhost")
            XCTAssertNil(options.allowCredentials)
        }
    }

    func testPasskeyLoginStartWithUsername() async throws {
        let user = try await createTestUser(username: "registereduser")
        let passkey = UserPasskey(
            userID: try user.requireID(),
            credentialID: "dGVzdC1jcmVkZW50aWFsLWlk",
            publicKey: Data([1, 2, 3, 4]),
            currentSignCount: 0,
            nickname: "MacBook Touch ID"
        )
        try await passkey.save(on: app.db)

        let body = PasskeyController.LoginStartDTO(username: "registereduser")
        try await app.testing().test(.POST, "api/auth/passkeys/login/start", beforeRequest: { req in
            try req.content.encode(body)
        }) { res in
            XCTAssertEqual(res.status, .ok)
            let options = try res.content.decode(PublicKeyCredentialRequestOptions.self)
            XCTAssertFalse(options.challenge.isEmpty)
            XCTAssertEqual(options.allowCredentials?.count, 1)
        }
    }

    func testPasskeyCRUDOperations() async throws {
        let user = try await createTestUser(username: "cruduser")
        let authHeaders = try await makeAuthHeader(for: user)

        let passkey = UserPasskey(
            userID: try user.requireID(),
            credentialID: "Y3J1ZC1jcmVkZW50aWFsLWlk",
            publicKey: Data([10, 20, 30, 40]),
            currentSignCount: 0,
            nickname: "My YubiKey"
        )
        try await passkey.save(on: app.db)
        let passkeyID = try passkey.requireID()

        // 1. List passkeys
        try await app.testing().test(.GET, "api/auth/passkeys", beforeRequest: { req in
            for (k, v) in authHeaders { req.headers.add(name: k, value: v) }
        }) { res in
            XCTAssertEqual(res.status, .ok)
            let list = try res.content.decode([UserPasskey.PublicDTO].self)
            XCTAssertEqual(list.count, 1)
            XCTAssertEqual(list.first?.nickname, "My YubiKey")
            XCTAssertEqual(list.first?.id, passkeyID)
        }

        // 2. Rename passkey
        let renameDTO = PasskeyController.RenameDTO(nickname: "Renamed Hardware Key")
        try await app.testing().test(.PATCH, "api/auth/passkeys/\(passkeyID)", beforeRequest: { req in
            for (k, v) in authHeaders { req.headers.add(name: k, value: v) }
            try req.content.encode(renameDTO)
        }) { res in
            XCTAssertEqual(res.status, .ok)
            let updated = try res.content.decode(UserPasskey.PublicDTO.self)
            XCTAssertEqual(updated.nickname, "Renamed Hardware Key")
        }

        // 3. Delete passkey
        try await app.testing().test(.DELETE, "api/auth/passkeys/\(passkeyID)", beforeRequest: { req in
            for (k, v) in authHeaders { req.headers.add(name: k, value: v) }
        }) { res in
            XCTAssertEqual(res.status, .noContent)
        }

        // 4. Verify deletion
        try await app.testing().test(.GET, "api/auth/passkeys", beforeRequest: { req in
            for (k, v) in authHeaders { req.headers.add(name: k, value: v) }
        }) { res in
            XCTAssertEqual(res.status, .ok)
            let list = try res.content.decode([UserPasskey.PublicDTO].self)
            XCTAssertEqual(list.count, 0)
        }
    }
}
