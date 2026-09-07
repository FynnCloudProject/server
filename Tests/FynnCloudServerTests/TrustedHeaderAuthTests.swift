import Fluent
import FluentSQLiteDriver
import JWT
import Vapor
import VaporTesting
import XCTest
@testable import FynnCloudServer

final class TrustedHeaderAuthTests: XCTestCase {

    override func setUp() {
        super.setUp()
        unsetenv("TRUSTED_HEADER_ENABLED")
        unsetenv("TRUSTED_EMAIL_HEADER")
        unsetenv("TRUSTED_NAME_HEADER")
        unsetenv("TRUSTED_GROUPS_HEADER")
        unsetenv("TRUSTED_ROLE_HEADER")
        unsetenv("TRUSTED_HEADER_SECRET")
    }

    override func tearDown() {
        unsetenv("TRUSTED_HEADER_ENABLED")
        unsetenv("TRUSTED_EMAIL_HEADER")
        unsetenv("TRUSTED_NAME_HEADER")
        unsetenv("TRUSTED_GROUPS_HEADER")
        unsetenv("TRUSTED_ROLE_HEADER")
        unsetenv("TRUSTED_HEADER_SECRET")
        unsetenv("RATE_LIMIT_ENABLED")
        unsetenv("APP_NAME")
        unsetenv("REGISTRATION_ENABLED")
        unsetenv("FRONTEND_URL")
        super.tearDown()
    }

    private func createTestApp() async throws -> Application {
        setenv("RATE_LIMIT_ENABLED", "false", 1)
        setenv("APP_NAME", "FynnCloud", 1)
        setenv("REGISTRATION_ENABLED", "true", 1)
        setenv("FRONTEND_URL", "http://localhost:3000", 1)

        let app = try await Application.make(.testing)
        unsetenv("TRUSTED_HEADER_ENABLED")
        unsetenv("TRUSTED_EMAIL_HEADER")
        unsetenv("TRUSTED_NAME_HEADER")
        unsetenv("TRUSTED_GROUPS_HEADER")
        unsetenv("TRUSTED_ROLE_HEADER")
        unsetenv("TRUSTED_HEADER_SECRET")

        app.databases.use(.sqlite(.memory), as: .sqlite)

        app.migrations.add(CreateInitialMigration())
        app.migrations.add(AddDisplayNameToUsers())
        app.migrations.add(CreateSyncLog())
        app.migrations.add(CreateOAuthGrant())
        app.migrations.add(UpdateGrantForRotation())
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
        app.migrations.add(CreateUserFavorites())
        try await app.autoMigrate()

        app.settings = SettingsService(database: app.db, redis: try await TestRedis.configure(app), logger: app.logger)
        app.config = try ServerConfig.load(for: app)
        app.fileStorage = TestStorage.createLocalProvider()
        app.subscription = SubscriptionService(envSubscriptionKey: nil, keys: JWTKeyCollection(), database: app.db)

        await reloadSSOProviders(app)
        try routes(app)
        return app
    }

    /// Trusted-header auth refuses to run without a shared proxy secret, so every positive-path
    /// test has to configure one and present it.
    private static let proxySecret = "test-proxy-secret"

    private func enableTrustedHeaders(_ app: Application) {
        setenv("TRUSTED_HEADER_SECRET", Self.proxySecret, 1)
    }

    private func trustedHeaders(_ pairs: (String, String)...) -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.add(name: "X-Auth-Secret", value: Self.proxySecret)
        for (name, value) in pairs { headers.add(name: name, value: value) }
        return headers
    }

    func testTrustedHeaderDisabledByDefault() async throws {
        let app = try await createTestApp()
        defer {
            Task { try? await app.asyncShutdown() }
        }

        var headers = HTTPHeaders()
        headers.add(name: "X-User-Email", value: "header-user@example.com")

        try await app.testing().test(.GET, "api/user/me", headers: headers) { res async throws in
            XCTAssertEqual(res.status, .unauthorized)
        }
    }

    func testTrustedHeaderProvisioningAndAuth() async throws {
        let app = try await createTestApp()
        defer {
            Task { try? await app.asyncShutdown() }
        }

        // Enable trusted header auth in settings
        enableTrustedHeaders(app)
        try await app.settings.setGuarded(AppSettings.TrustedHeaderEnabled.self, value: true)
        try await app.settings.setGuarded(AppSettings.TrustedEmailHeader.self, value: "X-User-Email")
        try await app.settings.setGuarded(AppSettings.TrustedNameHeader.self, value: "X-User-Name")
        await reloadSSOProviders(app)

        let headers = trustedHeaders(
            ("X-User-Email", "alice@example.com"),
            ("X-User-Name", "Alice Smith")
        )

        try await app.testing().test(.GET, "api/user/me", headers: headers) { res async throws in
            XCTAssertEqual(res.status, .ok)
            let user = try res.content.decode(User.Public.self)
            XCTAssertEqual(user.email, "alice@example.com")
            XCTAssertEqual(user.displayName, "Alice Smith")
        }

        // Verify UserIdentity was created
        let identity = try await UserIdentity.query(on: app.db)
            .filter(\.$provider == "trusted_header")
            .filter(\.$subject == "alice@example.com")
            .first()
        XCTAssertNotNil(identity)
    }

    func testTrustedHeaderGroupSync() async throws {
        let app = try await createTestApp()
        defer {
            Task { try? await app.asyncShutdown() }
        }

        enableTrustedHeaders(app)
        try await app.settings.setGuarded(AppSettings.TrustedHeaderEnabled.self, value: true)
        try await app.settings.setGuarded(AppSettings.TrustedEmailHeader.self, value: "X-User-Email")
        try await app.settings.setGuarded(AppSettings.TrustedGroupsHeader.self, value: "X-User-Groups")
        try await app.settings.setGuarded(AppSettings.SsoGroupImport.self, value: true)
        await reloadSSOProviders(app)

        let headers = trustedHeaders(
            ("X-User-Email", "bob@example.com"),
            ("X-User-Groups", "engineers, designers")
        )

        try await app.testing().test(.GET, "api/user/me", headers: headers) { res async throws in
            XCTAssertEqual(res.status, .ok)
            let user = try res.content.decode(User.Public.self)
            let groupNames = Set(user.groups.map(\.name))
            XCTAssertTrue(groupNames.contains("engineers"))
            XCTAssertTrue(groupNames.contains("designers"))
        }
    }

    func testTrustedHeaderRoleElevation() async throws {
        let app = try await createTestApp()
        defer {
            Task { try? await app.asyncShutdown() }
        }

        enableTrustedHeaders(app)
        try await app.settings.setGuarded(AppSettings.TrustedHeaderEnabled.self, value: true)
        try await app.settings.setGuarded(AppSettings.TrustedEmailHeader.self, value: "X-User-Email")
        try await app.settings.setGuarded(AppSettings.TrustedRoleHeader.self, value: "X-User-Role")
        await reloadSSOProviders(app)

        let headers = trustedHeaders(
            ("X-User-Email", "admin-sso@example.com"),
            ("X-User-Role", "admin")
        )

        // Access admin route
        try await app.testing().test(.GET, "api/admin/users", headers: headers) { res async throws in
            XCTAssertEqual(res.status, .ok)
        }
    }

    func testTrustedHeaderSecretVerification() async throws {
        let app = try await createTestApp()
        defer {
            Task { try? await app.asyncShutdown() }
        }

        setenv("TRUSTED_HEADER_SECRET", "supersecret123", 1)
        try await app.settings.setGuarded(AppSettings.TrustedHeaderEnabled.self, value: true)
        try await app.settings.setGuarded(AppSettings.TrustedEmailHeader.self, value: "X-User-Email")
        await reloadSSOProviders(app)

        // Request with missing secret
        var headersWithoutSecret = HTTPHeaders()
        headersWithoutSecret.add(name: "X-User-Email", value: "secret-user@example.com")

        try await app.testing().test(.GET, "api/user/me", headers: headersWithoutSecret) { res async throws in
            XCTAssertEqual(res.status, .unauthorized)
        }

        // Request with valid secret
        var headersWithSecret = HTTPHeaders()
        headersWithSecret.add(name: "X-User-Email", value: "secret-user@example.com")
        headersWithSecret.add(name: "X-Auth-Secret", value: "supersecret123")

        try await app.testing().test(.GET, "api/user/me", headers: headersWithSecret) { res async throws in
            XCTAssertEqual(res.status, .ok)
            let user = try res.content.decode(User.Public.self)
            XCTAssertEqual(user.email, "secret-user@example.com")
        }
    }

    /// Enabling trusted headers without a proxy secret must fail closed - otherwise anyone who can
    /// reach the port could impersonate any user just by setting the email header.
    func testTrustedHeaderWithoutConfiguredSecretFailsClosed() async throws {
        let app = try await createTestApp()
        defer {
            Task { try? await app.asyncShutdown() }
        }

        unsetenv("TRUSTED_HEADER_SECRET")
        try await app.settings.setGuarded(AppSettings.TrustedHeaderEnabled.self, value: true)
        try await app.settings.setGuarded(AppSettings.TrustedEmailHeader.self, value: "X-User-Email")
        await reloadSSOProviders(app)

        var headers = HTTPHeaders()
        headers.add(name: "X-User-Email", value: "impersonated@example.com")

        try await app.testing().test(.GET, "api/user/me", headers: headers) { res async throws in
            XCTAssertEqual(res.status, .unauthorized)
        }

        let userCount = try await User.query(on: app.db)
            .filter(\.$email == "impersonated@example.com")
            .count()
        XCTAssertEqual(userCount, 0)
    }

    func testTrustedHeaderPreservesExistingUsername() async throws {        let app = try await createTestApp()
        defer {
            Task { try? await app.asyncShutdown() }
        }

        // Create an existing local user with a specific chosen username
        let existingUser = User(
            username: "chosen_custom_handle",
            email: "charlie@example.com",
            passwordHash: "dummy",
            displayName: "Charlie"
        )
        try await existingUser.create(on: app.db)

        enableTrustedHeaders(app)
        try await app.settings.setGuarded(AppSettings.TrustedHeaderEnabled.self, value: true)
        try await app.settings.setGuarded(AppSettings.TrustedEmailHeader.self, value: "X-User-Email")
        try await app.settings.setGuarded(AppSettings.TrustedNameHeader.self, value: "X-User-Name")
        await reloadSSOProviders(app)

        let headers = trustedHeaders(
            ("X-User-Email", "charlie@example.com"),
            ("X-User-Name", "Charlie Brown")
        )

        try await app.testing().test(.GET, "api/user/me", headers: headers) { res async throws in
            XCTAssertEqual(res.status, .ok)
            let user = try res.content.decode(User.Public.self)
            XCTAssertEqual(user.username, "chosen_custom_handle") // Must NOT be changed to charlie or Charlie Brown
            XCTAssertEqual(user.displayName, "Charlie Brown")
            XCTAssertEqual(user.email, "charlie@example.com")
        }
    }

    func testTrustedHeaderAutoProvisioningDisabledBlocksNewUser() async throws {
        let app = try await createTestApp()
        defer {
            Task { try? await app.asyncShutdown() }
        }

        enableTrustedHeaders(app)
        try await app.settings.setGuarded(AppSettings.TrustedHeaderEnabled.self, value: true)
        try await app.settings.setGuarded(AppSettings.TrustedEmailHeader.self, value: "X-User-Email")
        try await app.settings.setGuarded(AppSettings.SsoAutoProvision.self, value: false)
        await reloadSSOProviders(app)

        let headers = trustedHeaders(("X-User-Email", "blocked-user@example.com"))

        try await app.testing().test(.GET, "api/user/me", headers: headers) { res async throws in
            XCTAssertEqual(res.status, .unauthorized)
        }

        let userCount = try await User.query(on: app.db)
            .filter(\.$email == "blocked-user@example.com")
            .count()
        XCTAssertEqual(userCount, 0)

        let identityCount = try await UserIdentity.query(on: app.db)
            .filter(\.$subject == "blocked-user@example.com")
            .count()
        XCTAssertEqual(identityCount, 0)
    }

    func testTrustedHeaderAutoProvisioningDisabledAllowsExistingUser() async throws {
        let app = try await createTestApp()
        defer {
            Task { try? await app.asyncShutdown() }
        }

        let existingUser = User(
            username: "existing_employee",
            email: "employee@example.com",
            passwordHash: "dummy",
            displayName: "Existing Employee"
        )
        try await existingUser.create(on: app.db)

        enableTrustedHeaders(app)
        try await app.settings.setGuarded(AppSettings.TrustedHeaderEnabled.self, value: true)
        try await app.settings.setGuarded(AppSettings.TrustedEmailHeader.self, value: "X-User-Email")
        try await app.settings.setGuarded(AppSettings.SsoAutoProvision.self, value: false)
        await reloadSSOProviders(app)

        let headers = trustedHeaders(("X-User-Email", "employee@example.com"))

        try await app.testing().test(.GET, "api/user/me", headers: headers) { res async throws in
            XCTAssertEqual(res.status, .ok)
            let user = try res.content.decode(User.Public.self)
            XCTAssertEqual(user.username, "existing_employee")
            XCTAssertEqual(user.email, "employee@example.com")
        }

        let identity = try await UserIdentity.query(on: app.db)
            .filter(\.$provider == "trusted_header")
            .filter(\.$subject == "employee@example.com")
            .first()
        XCTAssertNotNil(identity)
        XCTAssertEqual(identity?.$user.id, try existingUser.requireID())
    }
}
