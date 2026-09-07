import Fluent
import FluentSQLiteDriver
import JWT
import Vapor
import VaporTesting
import XCTest

@testable import FynnCloudServer

final class ScheduledJobsTests: XCTestCase {

    private func createTestApp() async throws -> Application {
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

        await app.jwt.keys.add(
            hmac: HMACKey(from: "test_secret_key_1234567890"), digestAlgorithm: .sha256)
        app.fileStorage = TestStorage.createLocalProvider()
        app.subscription = SubscriptionService(
            envSubscriptionKey: nil, keys: JWTKeyCollection(), database: app.db)
        try await TestRedis.configure(app)
        app.settings = SettingsService(database: app.db, redis: app.redis, logger: app.logger)
        app.config = try ServerConfig.load(for: app)

        try routes(app)
        return app
    }

    private func createAdminUser(on app: Application) async throws -> (User, String) {
        let adminGroup = try await Group.query(on: app.db).filter(\.$isAdmin == true).first()
            ?? Group(name: "admin", isAdmin: true)
        if adminGroup.id == nil {
            try await adminGroup.save(on: app.db)
        }

        let adminUser = User(
            id: UUID(),
            username: "admin",
            email: "admin@example.com",
            passwordHash: "hash"
        )
        try await adminUser.save(on: app.db)
        try await adminUser.$groups.attach(adminGroup, on: app.db)

        let grant = OAuthGrant(
            userID: try adminUser.requireID(), clientID: "fynncloud-web", userAgent: "test")
        try await grant.save(on: app.db)

        let payload = UserPayload(
            subject: .init(value: try adminUser.requireID().uuidString),
            expiration: .init(value: Date().addingTimeInterval(3600)),
            grantID: try grant.requireID(),
            jti: .init(value: UUID().uuidString)
        )
        let token = try await app.jwt.keys.sign(payload)
        return (adminUser, token)
    }

    func testGetScheduledJobsIncludesIDs() async throws {
        let app = try await createTestApp()
        defer { Task { try? await app.asyncShutdown() } }

        let (_, token) = try await createAdminUser(on: app)

        try await app.testing().test(
            .GET, "/api/scheduled-jobs",
            beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            },
            afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                let response = try res.content.decode(ScheduledJobsResponse.self)
                XCTAssertFalse(response.jobs.isEmpty)
                XCTAssertTrue(response.jobs.contains(where: { $0.id == "quota_recalculation" }))
                XCTAssertTrue(response.jobs.contains(where: { $0.id == "upload_cleanup" }))
                XCTAssertTrue(response.jobs.contains(where: { $0.id == "trash_cleanup" }))
                XCTAssertTrue(response.jobs.contains(where: { $0.id == "expired_token_cleanup" }))
                XCTAssertTrue(response.jobs.contains(where: { $0.id == "sync_log_prune" }))
            }
        )
    }

    func testTriggerScheduledJobSuccess() async throws {
        let app = try await createTestApp()
        defer { Task { try? await app.asyncShutdown() } }

        let (_, token) = try await createAdminUser(on: app)

        try await app.testing().test(
            .POST, "/api/scheduled-jobs/quota_recalculation/trigger",
            beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            },
            afterResponse: { res async in
                XCTAssertEqual(res.status, .ok)
            }
        )

        try await app.testing().test(
            .POST, "/api/scheduled-jobs/upload_cleanup/trigger",
            beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            },
            afterResponse: { res async in
                XCTAssertEqual(res.status, .ok)
            }
        )

        try await app.testing().test(
            .POST, "/api/scheduled-jobs/trash_cleanup/trigger",
            beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            },
            afterResponse: { res async in
                XCTAssertEqual(res.status, .ok)
            }
        )
    }

    func testTriggerInvalidTaskReturnsNotFound() async throws {
        let app = try await createTestApp()
        defer { Task { try? await app.asyncShutdown() } }

        let (_, token) = try await createAdminUser(on: app)

        try await app.testing().test(
            .POST, "/api/scheduled-jobs/non_existent_task/trigger",
            beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            },
            afterResponse: { res async in
                XCTAssertEqual(res.status, .notFound)
            }
        )
    }
}
