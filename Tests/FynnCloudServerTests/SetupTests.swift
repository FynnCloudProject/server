import XCTest
import Fluent
import FluentSQLiteDriver
import JWT
import Vapor
import VaporTesting
@testable import FynnCloudServer

final class SetupTests: XCTestCase {

    private func createTestApp(appName: String? = nil, primaryColor: String? = nil) async throws -> Application {
        setenv("RATE_LIMIT_ENABLED", "false", 1)
        if let appName {
            setenv("APP_NAME", appName, 1)
        } else {
            setenv("APP_NAME", "", 1)
        }
        if let primaryColor {
            setenv("PRIMARY_COLOR", primaryColor, 1)
        } else {
            setenv("PRIMARY_COLOR", "", 1)
        }
        setenv("REGISTRATION_ENABLED", "", 1)
        let app = try await Application.make(.testing)
        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateInitialMigration())
        app.migrations.add(AddDisplayNameToUsers())
        app.migrations.add(CreateSyncLog())
        app.migrations.add(CreateOAuthCode())
        app.migrations.add(AddClientIdAndStateToOAuthCode())
        app.migrations.add(CreateOAuthGrant())
        app.migrations.add(UpdateGrantForRotation())
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

        try await TestRedis.configure(app)

        app.settings = SettingsService(database: app.db, redis: app.redis, logger: app.logger)
        app.config = try ServerConfig.load(for: app)
        app.fileStorage = TestStorage.createLocalProvider()
        app.subscription = SubscriptionService(envSubscriptionKey: nil, keys: JWTKeyCollection(), database: app.db)

        try routes(app)
        return app
    }

    func testSetupFlow() async throws {
        let app = try await createTestApp()
        defer {
            Task { try? await app.asyncShutdown() }
        }

        try await app.testing().test(.GET, "api/info") { res async throws in
            XCTAssertEqual(res.status, .ok)
            let info = try res.content.decode(ServerInfo.self)
            XCTAssertTrue(info.isSetupRequired)
            XCTAssertFalse(info.isAppNameManagedByEnv)
            XCTAssertFalse(info.isPrimaryColorManagedByEnv)
        }

        let setupDTO = SetupDTO(
            username: "adminuser",
            password: "SecurePassword123!",
            confirmPassword: "SecurePassword123!",
            email: "admin@example.com",
            displayName: "System Administrator",
            appName: "My Private Cloud",
            primaryColor: "emerald",
            registrationEnabled: false
        )

        try await app.testing().test(.POST, "api/auth/setup", beforeRequest: { req async throws in
            try req.content.encode(setupDTO)
        }) { res async throws in
            XCTAssertEqual(res.status, .ok)
            let user = try res.content.decode(User.Public.self)
            XCTAssertEqual(user.username, "adminuser")
            XCTAssertEqual(user.displayName, "System Administrator")
            XCTAssertEqual(user.email, "admin@example.com")
            XCTAssertTrue(user.isAdmin)
        }

        let appName = try await app.settings.get(AppSettings.AppName.self)
        XCTAssertEqual(appName, "My Private Cloud")

        let primaryColor = try await app.settings.get(AppSettings.PrimaryColor.self)
        XCTAssertEqual(primaryColor, "emerald")

        let regEnabled = try await app.settings.get(AppSettings.RegistrationEnabled.self)
        XCTAssertFalse(regEnabled)

        try await app.testing().test(.GET, "api/info") { res async throws in
            XCTAssertEqual(res.status, .ok)
            let info = try res.content.decode(ServerInfo.self)
            XCTAssertFalse(info.isSetupRequired)
            XCTAssertEqual(info.appName, "My Private Cloud")
        }

        let secondAttemptDTO = SetupDTO(
            username: "attacker",
            password: "SecurePassword123!",
            confirmPassword: "SecurePassword123!",
            email: "attacker@example.com"
        )

        try await app.testing().test(.POST, "api/auth/setup", beforeRequest: { req async throws in
            try req.content.encode(secondAttemptDTO)
        }) { res async in
            XCTAssertEqual(res.status, .forbidden)
        }
    }

    func testSetupWithEnvOverrides() async throws {
        setenv("APP_NAME", "EnvCloud", 1)
        setenv("PRIMARY_COLOR", "rose", 1)
        defer {
            setenv("APP_NAME", "", 1)
            setenv("PRIMARY_COLOR", "", 1)
        }

        let app = try await createTestApp(appName: "EnvCloud", primaryColor: "rose")
        defer {
            Task { try? await app.asyncShutdown() }
        }

        try await app.testing().test(.GET, "api/info") { res async throws in
            XCTAssertEqual(res.status, .ok)
            let info = try res.content.decode(ServerInfo.self)
            XCTAssertTrue(info.isSetupRequired)
            XCTAssertEqual(info.appName, "EnvCloud")
            XCTAssertEqual(info.primaryColor, "rose")
            XCTAssertTrue(info.isAppNameManagedByEnv)
            XCTAssertTrue(info.isPrimaryColorManagedByEnv)
        }
    }

    override func tearDown() {
        unsetenv("RATE_LIMIT_ENABLED")
        unsetenv("APP_NAME")
        unsetenv("PRIMARY_COLOR")
        unsetenv("REGISTRATION_ENABLED")
        super.tearDown()
    }
}
