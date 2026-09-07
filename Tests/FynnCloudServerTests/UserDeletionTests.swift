import XCTest
import Fluent
import FluentSQLiteDriver
import JWT
import Vapor
import VaporTesting
@testable import FynnCloudServer

final class UserDeletionTests: XCTestCase {

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
        app.migrations.add(CreateUserFavorites())
        try await app.autoMigrate()
        app.config = try ServerConfig.load(for: app)
        app.fileStorage = TestStorage.createLocalProvider()
        app.subscription = SubscriptionService(envSubscriptionKey: nil, keys: JWTKeyCollection(), database: app.db)
        return app
    }

    func testUserDeletionWithFilesAndGroupCleanUp() async throws {
        let app = try await createTestApp()
        defer {
            Task { try? await app.asyncShutdown() }
        }

        let adminGroup = Group(name: "Admins", isAdmin: true)
        let memberGroup = Group(name: "Members", isAdmin: false)
        try await adminGroup.save(on: app.db)
        try await memberGroup.save(on: app.db)

        let admin1 = User(username: "admin1", email: "admin1@test.com", passwordHash: "hash")
        let admin2 = User(username: "admin2", email: "admin2@test.com", passwordHash: "hash")
        try await admin1.save(on: app.db)
        try await admin2.save(on: app.db)

        let admin1GroupPivot = UserGroup(userID: try admin1.requireID(), groupID: try adminGroup.requireID())
        let admin2GroupPivot = UserGroup(userID: try admin2.requireID(), groupID: try adminGroup.requireID())
        try await admin1GroupPivot.save(on: app.db)
        try await admin2GroupPivot.save(on: app.db)

        let user = User(username: "testuser", email: "testuser@test.com", passwordHash: "hash")
        try await user.save(on: app.db)
        let userID = try user.requireID()

        let userGroupPivot = UserGroup(userID: userID, groupID: try memberGroup.requireID())
        try await userGroupPivot.save(on: app.db)

        let file = FileMetadata(filename: "test.txt", contentType: "text/plain", size: 100, isDirectory: false, ownerID: userID)
        try await file.save(on: app.db)

        let eventLoop = app.eventLoopGroup.next()
        let redis = try await TestRedis.configure(app)
        let storageService = StorageService(provider: app.fileStorage, eventLoop: eventLoop)
        let fileService = FileService(
            FileServiceContext(
                db: app.db, logger: app.logger,
                storage: storageService, redis: redis))

        let userService = UserService(db: app.db, subscriptionService: app.subscription, redis: redis)
        try await userService.deleteUser(user: user, fileService: fileService)

        let deletedUser = try await User.find(userID, on: app.db)
        XCTAssertNil(deletedUser)

        let remainingFiles = try await FileMetadata.query(on: app.db).filter(\.$owner.$id == userID).all()
        XCTAssertTrue(remainingFiles.isEmpty)

        let remainingPivots = try await UserGroup.query(on: app.db).filter(\.$user.$id == userID).all()
        XCTAssertTrue(remainingPivots.isEmpty)
    }

    func testCannotDeleteLastAdminUser() async throws {
        let app = try await createTestApp()
        defer {
            Task { try? await app.asyncShutdown() }
        }

        let adminGroup = Group(name: "Admins", isAdmin: true)
        try await adminGroup.save(on: app.db)

        let soleAdmin = User(username: "soleadmin", email: "admin@test.com", passwordHash: "hash")
        try await soleAdmin.save(on: app.db)

        let pivot = UserGroup(userID: try soleAdmin.requireID(), groupID: try adminGroup.requireID())
        try await pivot.save(on: app.db)

        let eventLoop = app.eventLoopGroup.next()
        let redis = try await TestRedis.configure(app)
        let storageService = StorageService(provider: app.fileStorage, eventLoop: eventLoop)
        let fileService = FileService(
            FileServiceContext(
                db: app.db, logger: app.logger,
                storage: storageService, redis: redis))

        do {
            let userService = UserService(db: app.db, subscriptionService: app.subscription, redis: redis)
            try await userService.deleteUser(user: soleAdmin, fileService: fileService)
            XCTFail("Should have thrown conflict error when deleting the last admin")
        } catch let abort as any AbortError {
            XCTAssertEqual(abort.status, .conflict)
        }
    }

    func testDefaultMaxUserLimitWithoutSubscriptionKey() async throws {
        let app = try await createTestApp()
        defer {
            Task { try? await app.asyncShutdown() }
        }

        let userService = UserService(db: app.db, subscriptionService: app.subscription, redis: try await TestRedis.configure(app))

        // First user (first-user bootstrap bypasses limit)
        _ = try await userService.createUser(input: .init(username: "user0", email: "user0@test.com", password: "Password123!", isFirstUserCheck: true))

        for i in 1...9 {
            _ = try await userService.createUser(input: .init(username: "user\(i)", email: "user\(i)@test.com", password: "Password123!"))
        }

        // The 11th user registration should throw .forbidden because default limit is 10
        do {
            _ = try await userService.createUser(input: .init(username: "user10", email: "user10@test.com", password: "Password123!"))
            XCTFail("Should have thrown forbidden error when exceeding 10 users without subscription key")
        } catch let abort as any AbortError {
            XCTAssertEqual(abort.status, .forbidden)
        }
    }
}
