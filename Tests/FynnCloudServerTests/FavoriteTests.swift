import XCTest
import Vapor
import Fluent
import FluentSQLiteDriver
import JWT
@testable import FynnCloudServer

final class FavoriteTests: XCTestCase {
    var app: Application!
    var owner: User!
    var collaborator: User!
    var ownerID: UUID!
    var collaboratorID: UUID!
    var fileService: FileService!

    override func setUp() async throws {
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
        app.migrations.add(AddUploadedAtToFileMetadata())
        app.migrations.add(OverhaulSyncInfrastructure())
        app.migrations.add(CreateInternalShares())
        app.migrations.add(DropOAuthCodes())
        app.migrations.add(DropMultipartUploadSessions())
        app.migrations.add(CreateUserFavorites())
        try await app.autoMigrate()

        await app.jwt.keys.add(hmac: HMACKey(from: "test_secret_key_12345678901234567890"), digestAlgorithm: .sha256)
        try await TestRedis.configure(app)
        app.settings = SettingsService(database: app.db, redis: app.redis, logger: app.logger)
        app.config = try ServerConfig.load(for: app)

        let mockProvider = TestStorage.createLocalProvider()
        let storageService = StorageService(provider: mockProvider, eventLoop: app.eventLoopGroup.next())
        fileService = FileService(
    FileServiceContext(
        db: app.db, logger: app.logger,
        storage: storageService, redis: try await TestRedis.configure(app)))
        app.fileStorage = mockProvider
        app.subscription = SubscriptionService(envSubscriptionKey: nil, keys: JWTKeyCollection(), database: app.db)

        let tier = StorageTier(name: "Favorite Test Tier", limitBytes: 100_000_000)
        try await tier.save(on: app.db)

        owner = User(username: "alice", email: "alice@test.com", passwordHash: "h", displayName: "Alice Owner", tierID: try tier.requireID())
        try await owner.save(on: app.db)
        ownerID = try owner.requireID()

        collaborator = User(username: "bob", email: "bob@test.com", passwordHash: "h", displayName: "Bob Collab", tierID: try tier.requireID())
        try await collaborator.save(on: app.db)
        collaboratorID = try collaborator.requireID()

        try routes(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
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

    func testOwnerCanFavoriteAndUnfavoriteOwnFile() async throws {
        let file = FileMetadata(
            filename: "alice_notes.txt",
            contentType: "text/plain",
            size: 100,
            isDirectory: false,
            ownerID: ownerID
        )
        try await file.save(on: app.db)
        let fileID = try file.requireID()

        let headers = try await makeAuthHeader(for: owner)

        try await app.test(.POST, "api/files/\(fileID)/favorite", headers: HTTPHeaders(headers.map { ($0.key, $0.value) })) { res in
            XCTAssertEqual(res.status, .ok)
            let dto = try res.content.decode(FileIndexItemDTO.self)
            XCTAssertTrue(dto.isFavorite)
        }

        try await app.test(.GET, "api/files/favorites", headers: HTTPHeaders(headers.map { ($0.key, $0.value) })) { res in
            XCTAssertEqual(res.status, .ok)
            let list = try res.content.decode(FileIndexDTO.self)
            XCTAssertEqual(list.files.count, 1)
            XCTAssertEqual(list.files.first?.id, fileID)
            XCTAssertTrue(list.files.first?.isFavorite ?? false)
        }

        try await app.test(.POST, "api/files/\(fileID)/favorite", headers: HTTPHeaders(headers.map { ($0.key, $0.value) })) { res in
            XCTAssertEqual(res.status, .ok)
            let dto = try res.content.decode(FileIndexItemDTO.self)
            XCTAssertFalse(dto.isFavorite)
        }

        try await app.test(.GET, "api/files/favorites", headers: HTTPHeaders(headers.map { ($0.key, $0.value) })) { res in
            XCTAssertEqual(res.status, .ok)
            let list = try res.content.decode(FileIndexDTO.self)
            XCTAssertEqual(list.files.count, 0)
        }
    }

    func testRecipientCanFavoriteSharedFileWithPerUserIsolation() async throws {
        let file = FileMetadata(
            filename: "shared_doc.pdf",
            contentType: "application/pdf",
            size: 500,
            isDirectory: false,
            ownerID: ownerID,
            isShared: true
        )
        try await file.save(on: app.db)
        let fileID = try file.requireID()

        let share = InternalShare(
            fileID: fileID,
            granteeType: .user,
            granteeUserID: collaboratorID,
            role: .viewer,
            createdBy: ownerID
        )
        try await share.save(on: app.db)

        let bobHeaders = try await makeAuthHeader(for: collaborator)
        let aliceHeaders = try await makeAuthHeader(for: owner)

        try await app.test(.POST, "api/files/\(fileID)/favorite", headers: HTTPHeaders(bobHeaders.map { ($0.key, $0.value) })) { res in
            XCTAssertEqual(res.status, .ok)
            let dto = try res.content.decode(FileIndexItemDTO.self)
            XCTAssertTrue(dto.isFavorite)
            XCTAssertEqual(dto.owner.id, ownerID)
            XCTAssertFalse(dto.permissions?.isOwner ?? true)
        }

        try await app.test(.GET, "api/files/favorites", headers: HTTPHeaders(bobHeaders.map { ($0.key, $0.value) })) { res in
            XCTAssertEqual(res.status, .ok)
            let list = try res.content.decode(FileIndexDTO.self)
            XCTAssertEqual(list.files.count, 1)
            XCTAssertEqual(list.files.first?.id, fileID)
            XCTAssertTrue(list.files.first?.isFavorite ?? false)
            XCTAssertEqual(list.files.first?.owner.displayName, "Alice Owner")
        }

        try await app.test(.GET, "api/files/favorites", headers: HTTPHeaders(aliceHeaders.map { ($0.key, $0.value) })) { res in
            XCTAssertEqual(res.status, .ok)
            let list = try res.content.decode(FileIndexDTO.self)
            XCTAssertEqual(list.files.count, 0)
        }

        try await app.test(.GET, "api/files/\(fileID)", headers: HTTPHeaders(bobHeaders.map { ($0.key, $0.value) })) { res in
            XCTAssertEqual(res.status, .ok)
            let dto = try res.content.decode(FileIndexItemDTO.self)
            XCTAssertTrue(dto.isFavorite)
        }

        try await app.test(.GET, "api/files/\(fileID)", headers: HTTPHeaders(aliceHeaders.map { ($0.key, $0.value) })) { res in
            XCTAssertEqual(res.status, .ok)
            let dto = try res.content.decode(FileIndexItemDTO.self)
            XCTAssertFalse(dto.isFavorite)
        }
    }

    func testRecipientCanFavoriteNestedFileInSharedFolder() async throws {
        let parentFolder = FileMetadata(
            filename: "Shared Project",
            contentType: "application/x-directory",
            size: 0,
            isDirectory: true,
            ownerID: ownerID,
            isShared: true
        )
        try await parentFolder.save(on: app.db)
        let folderID = try parentFolder.requireID()

        let nestedFile = FileMetadata(
            filename: "design.png",
            contentType: "image/png",
            size: 2048,
            isDirectory: false,
            parentID: folderID,
            ownerID: ownerID,
            ancestorIDs: [folderID]
        )
        try await nestedFile.save(on: app.db)
        let nestedFileID = try nestedFile.requireID()

        let share = InternalShare(
            fileID: folderID,
            granteeType: .user,
            granteeUserID: collaboratorID,
            role: .editor,
            createdBy: ownerID
        )
        try await share.save(on: app.db)

        let bobHeaders = try await makeAuthHeader(for: collaborator)

        try await app.test(.POST, "api/files/\(nestedFileID)/favorite", headers: HTTPHeaders(bobHeaders.map { ($0.key, $0.value) })) { res in
            XCTAssertEqual(res.status, .ok)
            let dto = try res.content.decode(FileIndexItemDTO.self)
            XCTAssertTrue(dto.isFavorite)
        }

        try await app.test(.GET, "api/files/favorites", headers: HTTPHeaders(bobHeaders.map { ($0.key, $0.value) })) { res in
            XCTAssertEqual(res.status, .ok)
            let list = try res.content.decode(FileIndexDTO.self)
            XCTAssertEqual(list.files.count, 1)
            XCTAssertEqual(list.files.first?.id, nestedFileID)
            XCTAssertTrue(list.files.first?.isFavorite ?? false)
        }
    }

    func testRevokingShareRemovesFromRecipientFavorites() async throws {
        let file = FileMetadata(
            filename: "temporary_share.txt",
            contentType: "text/plain",
            size: 20,
            isDirectory: false,
            ownerID: ownerID,
            isShared: true
        )
        try await file.save(on: app.db)
        let fileID = try file.requireID()

        let share = InternalShare(
            fileID: fileID,
            granteeType: .user,
            granteeUserID: collaboratorID,
            role: .viewer,
            createdBy: ownerID
        )
        try await share.save(on: app.db)

        let bobHeaders = try await makeAuthHeader(for: collaborator)

        try await app.test(.POST, "api/files/\(fileID)/favorite", headers: HTTPHeaders(bobHeaders.map { ($0.key, $0.value) })) { res in
            XCTAssertEqual(res.status, .ok)
        }

        try await app.test(.GET, "api/files/favorites", headers: HTTPHeaders(bobHeaders.map { ($0.key, $0.value) })) { res in
            XCTAssertEqual(res.status, .ok)
            let list = try res.content.decode(FileIndexDTO.self)
            XCTAssertEqual(list.files.count, 1)
        }

        try await share.delete(on: app.db)

        try await app.test(.GET, "api/files/favorites", headers: HTTPHeaders(bobHeaders.map { ($0.key, $0.value) })) { res in
            XCTAssertEqual(res.status, .ok)
            let list = try res.content.decode(FileIndexDTO.self)
            XCTAssertEqual(list.files.count, 0)
        }
    }
}
