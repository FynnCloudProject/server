import XCTest
import Fluent
import FluentSQLiteDriver
import JWT
import Vapor
import VaporTesting
@testable import FynnCloudServer

final class GroupPermissionTests: XCTestCase {

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
        try await TestRedis.configure(app)

        await app.jwt.keys.add(hmac: HMACKey(from: "test_secret_key_1234567890"), digestAlgorithm: .sha256)
        app.fileStorage = TestStorage.createLocalProvider()
        app.subscription = SubscriptionService(envSubscriptionKey: nil, keys: JWTKeyCollection(), database: app.db)

        try app.register(collection: UserController())
        return app
    }

    private func createAdminAndToken(on app: Application) async throws -> (User, String) {
        let adminUser = User(username: "adminuser", email: "admin@test.com", passwordHash: "hash")
        try await adminUser.save(on: app.db)

        let adminGroup = try await Group.query(on: app.db).filter(\.$systemKey == "admin").first()!
        let pivot = UserGroup(userID: try adminUser.requireID(), groupID: try adminGroup.requireID())
        try await pivot.save(on: app.db)

        let grant = OAuthGrant(userID: try adminUser.requireID(), clientID: "fynncloud-web", userAgent: "test")
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

    func testCreateGroupWithAdminPermissions() async throws {
        let app = try await createTestApp()
        defer {
            Task { try? await app.asyncShutdown() }
        }

        let (_, token) = try await createAdminAndToken(on: app)

        try await app.testing().test(.POST, "api/admin/groups", beforeRequest: { req async in
            req.headers.bearerAuthorization = .init(token: token)
            try! req.content.encode(GroupRequest(name: "Designers", isAdmin: false))
        }) { res async in
            XCTAssertEqual(res.status, .ok)
            let group = try! res.content.decode(Group.Public.self)
            XCTAssertEqual(group.name, "Designers")
            XCTAssertFalse(group.isAdmin)
        }

        try await app.testing().test(.POST, "api/admin/groups", beforeRequest: { req async in
            req.headers.bearerAuthorization = .init(token: token)
            try! req.content.encode(GroupRequest(name: "DevOps", isAdmin: true))
        }) { res async in
            XCTAssertEqual(res.status, .ok)
            let group = try! res.content.decode(Group.Public.self)
            XCTAssertEqual(group.name, "DevOps")
            XCTAssertTrue(group.isAdmin)
        }
    }

    func testUpdateGroupPermissions() async throws {
        let app = try await createTestApp()
        defer {
            Task { try? await app.asyncShutdown() }
        }

        let (_, token) = try await createAdminAndToken(on: app)

        let customGroup = Group(name: "Engineering", isAdmin: false)
        try await customGroup.save(on: app.db)
        let groupID = try customGroup.requireID()

        try await app.testing().test(.PUT, "api/admin/groups/\(groupID)", beforeRequest: { req async in
            req.headers.bearerAuthorization = .init(token: token)
            try! req.content.encode(GroupRequest(name: "Senior Engineering", isAdmin: true))
        }) { res async in
            XCTAssertEqual(res.status, .ok)
            let group = try! res.content.decode(Group.Public.self)
            XCTAssertEqual(group.name, "Senior Engineering")
            XCTAssertTrue(group.isAdmin)
        }

        try await app.testing().test(.PUT, "api/admin/groups/\(groupID)", beforeRequest: { req async in
            req.headers.bearerAuthorization = .init(token: token)
            try! req.content.encode(GroupRequest(name: "Senior Engineering", isAdmin: false))
        }) { res async in
            XCTAssertEqual(res.status, .ok)
            let group = try! res.content.decode(Group.Public.self)
            XCTAssertFalse(group.isAdmin)
        }
    }

    func testSystemGroupSafeguards() async throws {
        let app = try await createTestApp()
        defer {
            Task { try? await app.asyncShutdown() }
        }

        let (_, token) = try await createAdminAndToken(on: app)

        let adminGroup = try await Group.query(on: app.db).filter(\.$systemKey == "admin").first()!
        let allUsersGroup = try await Group.query(on: app.db).filter(\.$systemKey == "all_users").first()!

        let adminGroupID = try adminGroup.requireID()
        let allUsersGroupID = try allUsersGroup.requireID()

        try await app.testing().test(.PUT, "api/admin/groups/\(adminGroupID)", beforeRequest: { req async in
            req.headers.bearerAuthorization = .init(token: token)
            try! req.content.encode(GroupRequest(name: "Super Admins", isAdmin: true))
        }) { res async in
            XCTAssertEqual(res.status, .forbidden)
        }

        try await app.testing().test(.PUT, "api/admin/groups/\(adminGroupID)", beforeRequest: { req async in
            req.headers.bearerAuthorization = .init(token: token)
            try! req.content.encode(GroupRequest(name: adminGroup.name, isAdmin: false))
        }) { res async in
            XCTAssertEqual(res.status, .forbidden)
        }

        try await app.testing().test(.PUT, "api/admin/groups/\(allUsersGroupID)", beforeRequest: { req async in
            req.headers.bearerAuthorization = .init(token: token)
            try! req.content.encode(GroupRequest(name: allUsersGroup.name, isAdmin: true))
        }) { res async in
            XCTAssertEqual(res.status, .forbidden)
        }

        try await app.testing().test(.DELETE, "api/admin/groups/\(adminGroupID)", beforeRequest: { req async in
            req.headers.bearerAuthorization = .init(token: token)
        }) { res async in
            XCTAssertEqual(res.status, .conflict)
        }

        try await app.testing().test(.DELETE, "api/admin/groups/\(allUsersGroupID)", beforeRequest: { req async in
            req.headers.bearerAuthorization = .init(token: token)
        }) { res async in
            XCTAssertEqual(res.status, .conflict)
        }
    }

    func testDeleteCustomAdminGroupWithSafeguards() async throws {
        let app = try await createTestApp()
        defer {
            Task { try? await app.asyncShutdown() }
        }

        let (_, token) = try await createAdminAndToken(on: app)

        let customAdminGroup = Group(name: "Platform Leads", isAdmin: true)
        try await customAdminGroup.save(on: app.db)
        let customAdminGroupID = try customAdminGroup.requireID()

        try await app.testing().test(.DELETE, "api/admin/groups/\(customAdminGroupID)", beforeRequest: { req async in
            req.headers.bearerAuthorization = .init(token: token)
        }) { res async in
            XCTAssertEqual(res.status, .noContent)
        }

        let deleted = try await Group.find(customAdminGroupID, on: app.db)
        XCTAssertNil(deleted)
    }
}
