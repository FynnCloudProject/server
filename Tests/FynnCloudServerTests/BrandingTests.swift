import XCTest
import Fluent
import FluentSQLiteDriver
import JWT
import Vapor
import VaporTesting
@testable import FynnCloudServer

final class BrandingTests: XCTestCase {

    func testSVGProcessorSanitization() throws {
        let maliciousSVG = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" onload="alert('xss')">
            <script>alert('pwned');</script>
            <script type="text/javascript">document.cookie;</script>
            <a href="javascript:alert(1)">
                <circle cx="50" cy="50" r="40" fill="red" onclick="alert(2)" />
            </a>
            <foreignObject width="100" height="100">
                <iframe src="http://evil.com"></iframe>
            </foreignObject>
        </svg>
        """

        var buffer = ByteBufferAllocator().buffer(capacity: maliciousSVG.utf8.count)
        buffer.writeString(maliciousSVG)

        let sanitizedBuffer = try SVGProcessor.sanitize(buffer: buffer)
        let sanitizedString = sanitizedBuffer.getString(at: 0, length: sanitizedBuffer.readableBytes)!

        XCTAssertFalse(sanitizedString.contains("<script"))
        XCTAssertFalse(sanitizedString.contains("onload"))
        XCTAssertFalse(sanitizedString.contains("onclick"))
        XCTAssertFalse(sanitizedString.contains("javascript:"))
        XCTAssertFalse(sanitizedString.contains("foreignObject"))
        XCTAssertTrue(sanitizedString.contains("viewBox=\"0 0 100 100\""))
        XCTAssertTrue(sanitizedString.contains("<circle"))
    }

    func testMetaControllerBrandingInfo() async throws {
        let app = try await Application.make(.testing)
        defer {
            Task { try? await app.asyncShutdown() }
        }

        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateAppSettings())
        try await app.autoMigrate()

        try await TestRedis.configure(app)

        app.settings = SettingsService(database: app.db, redis: app.redis, logger: app.logger)
        app.config = try ServerConfig.load(for: app)
        try app.register(collection: MetaController())

        try await app.testing().test(.GET, "api/info") { res async in
            XCTAssertEqual(res.status, .ok)
            let info = try! res.content.decode(ServerInfo.self)
            XCTAssertNil(info.logoUpdatedAt)
            XCTAssertNil(info.iconUpdatedAt)
            XCTAssertFalse(info.showLogoAndName)
            XCTAssertEqual(info.svgColorMode, "monochrome")
        }

        try await app.settings.setGuarded(AppSettings.CustomLogoUpdatedAt.self, value: "1724322400")
        try await app.settings.setGuarded(AppSettings.ShowLogoAndName.self, value: true)
        try await app.settings.setGuarded(AppSettings.SvgColorMode.self, value: .tinted)

        try await app.testing().test(.GET, "api/info") { res async in
            XCTAssertEqual(res.status, .ok)
            let info = try! res.content.decode(ServerInfo.self)
            XCTAssertEqual(info.logoUpdatedAt, "1724322400")
            XCTAssertNil(info.iconUpdatedAt)
            XCTAssertTrue(info.showLogoAndName)
            XCTAssertEqual(info.svgColorMode, "tinted")
        }

        XCTAssertThrowsError(try AppSettings.SvgColorMode.validate("invalid_mode"))
        XCTAssertNoThrow(try AppSettings.SvgColorMode.validate("original"))
        XCTAssertNoThrow(try AppSettings.SvgColorMode.validate("monochrome"))
        XCTAssertNoThrow(try AppSettings.SvgColorMode.validate("tinted"))
    }

    func testBrandingUploadGetDelete() async throws {
        let app = try await Application.make(.testing)
        defer {
            Task { try? await app.asyncShutdown() }
        }

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

        try await app.testing().test(
            .DELETE, "/api/settings/branding/logo",
            beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            }
        ) { res async in
            XCTAssertEqual(res.status, .ok)
        }

        try await app.testing().test(
            .DELETE, "/api/settings/branding/icon",
            beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            }
        ) { res async in
            XCTAssertEqual(res.status, .ok)
        }

        let svgData = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 100\"><circle cx=\"50\" cy=\"50\" r=\"40\" fill=\"blue\" /></svg>"
        var logoBuffer = ByteBufferAllocator().buffer(capacity: svgData.utf8.count)
        logoBuffer.writeString(svgData)
        let logoFile = File(data: logoBuffer, filename: "logo.svg")
        let uploadLogoReq = UploadBrandingLogoRequest(logo: logoFile)

        try await app.testing().test(
            .POST, "/api/settings/branding/logo",
            beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(uploadLogoReq, as: .formData)
            }
        ) { res async in
            XCTAssertEqual(res.status, .ok)
        }

        try await app.testing().test(.GET, "/api/branding/logo") { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.headers.contentType?.description, "image/svg+xml")
        }

        try await app.testing().test(
            .DELETE, "/api/settings/branding/logo",
            beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            }
        ) { res async in
            XCTAssertEqual(res.status, .ok)
        }

        try await app.testing().test(.GET, "/api/branding/logo") { res async in
            XCTAssertEqual(res.status, .notFound)
        }

        let iconFile = File(data: logoBuffer, filename: "icon.svg")
        let uploadIconReq = UploadBrandingIconRequest(icon: iconFile)

        try await app.testing().test(
            .POST, "/api/settings/branding/icon",
            beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(uploadIconReq, as: .formData)
            }
        ) { res async in
            XCTAssertEqual(res.status, .ok)
        }

        try await app.testing().test(.GET, "/api/branding/icon") { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.headers.contentType?.description, "image/svg+xml")
        }

        try await app.testing().test(
            .DELETE, "/api/settings/branding/icon",
            beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            }
        ) { res async in
            XCTAssertEqual(res.status, .ok)
        }

        try await app.testing().test(.GET, "/api/branding/icon") { res async in
            XCTAssertEqual(res.status, .notFound)
        }
    }
}
