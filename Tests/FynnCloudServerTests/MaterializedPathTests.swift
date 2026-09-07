import XCTest
import Vapor
import Fluent
import FluentSQLiteDriver
import SQLKit
@testable import FynnCloudServer

final class MaterializedPathTests: XCTestCase {
    var app: Application!
    var userID: UUID!

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
        app.migrations.add(DropOAuthCodes())
        app.migrations.add(DropMultipartUploadSessions())
        try! app.autoMigrate().wait()
        app.config = try ServerConfig.load(for: app)

        let tier = StorageTier(name: "Test Tier", limitBytes: 10_000_000)
        try await tier.save(on: app.db)

        let user = User(
            username: "pathuser",
            email: "path@example.com",
            passwordHash: "hash",
            tierID: try tier.requireID()
        )
        try await user.save(on: app.db)
        userID = try user.requireID()
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
    }

    private func makeFileService() async throws -> FileService {
        let mockProvider = TestStorage.createLocalProvider()
        let eventLoop = app.eventLoopGroup.next()
        let storageService = StorageService(
            provider: mockProvider,
            eventLoop: eventLoop
        )
        return FileService(
            FileServiceContext(
                db: app.db,
                logger: app.logger,
                storage: storageService,
                redis: try await TestRedis.configure(app)
            )
        )
    }

    func testAncestorIDsOnCreation() async throws {
        let service = try await makeFileService()

        let parentNil: UUID? = nil
        let folderA = try await service.createDirectory(name: "Folder A", parentID: parentNil, userID: userID)
        let folderAID = try folderA.requireID()
        XCTAssertEqual(folderA.ancestorIDs, [])

        let folderB = try await service.createDirectory(name: "Folder B", parentID: folderAID, userID: userID)
        let folderBID = try folderB.requireID()
        XCTAssertEqual(folderB.ancestorIDs, [folderAID])

        let fileC = FileMetadata(
            filename: "fileC.txt",
            contentType: "text/plain",
            size: 11,
            parentID: folderBID,
            ownerID: userID,
            ancestorIDs: [folderAID, folderBID]
        )
        try await fileC.save(on: app.db)
        XCTAssertEqual(fileC.ancestorIDs, [folderAID, folderBID])
    }

    func testShareLinkLookupLogic() async throws {
        let service = try await makeFileService()
        let parentNil: UUID? = nil

        let folderA = try await service.createDirectory(name: "Shared Folder", parentID: parentNil, userID: userID)
        let folderAID = try folderA.requireID()

        let folderB = try await service.createDirectory(name: "Subfolder B", parentID: folderAID, userID: userID)
        let folderBID = try folderB.requireID()

        let shareLink = ShareLink(
            token: "test-token-123",
            fileID: folderAID,
            createdBy: userID
        )
        try await shareLink.save(on: app.db)

        // Swift evaluation test: file.id == shareLink.fileID || file.ancestorIDs.contains(shareLink.fileID)
        XCTAssertTrue(folderB.id == shareLink.$file.id || folderB.ancestorIDs.contains(shareLink.$file.id))

        // Database evaluation test
        let matchedFiles: [FileMetadata]
        if let sql = app.db as? any SQLDatabase, sql.dialect.name == "postgresql" {
            matchedFiles = try await FileMetadata.query(on: app.db)
                .filter(\.$deletedAt == nil)
                .filter(\.$ancestorIDs, .custom("@>"), [shareLink.$file.id])
                .all()
        } else {
            let allFiles = try await FileMetadata.query(on: app.db)
                .filter(\.$deletedAt == nil)
                .all()
            matchedFiles = allFiles.filter { $0.ancestorIDs.contains(shareLink.$file.id) }
        }

        XCTAssertEqual(matchedFiles.count, 1)
        XCTAssertEqual(matchedFiles.first?.id, folderBID)
    }

    func testShareLinkTypePermissions() async throws {
        let service = try await makeFileService()
        let parentNil: UUID? = nil

        let folder = try await service.createDirectory(name: "Drop Folder", parentID: parentNil, userID: userID)
        let folderID = try folder.requireID()

        let viewOnlyLink = ShareLink(token: "view-123", fileID: folderID, createdBy: userID, linkType: .viewOnly)
        XCTAssertFalse(viewOnlyLink.linkType.allowsUpload)
        XCTAssertTrue(viewOnlyLink.linkType.allowsView)

        let fileDropLink = ShareLink(token: "drop-123", fileID: folderID, createdBy: userID, linkType: .fileDrop)
        XCTAssertTrue(fileDropLink.linkType.allowsUpload)
        XCTAssertFalse(fileDropLink.linkType.allowsView)

        let collabLink = ShareLink(token: "collab-123", fileID: folderID, createdBy: userID, linkType: .collaborative)
        XCTAssertTrue(collabLink.linkType.allowsUpload)
        XCTAssertTrue(collabLink.linkType.allowsView)
    }

    func testFolderMoveService() async throws {
        let service = try await makeFileService()
        let parentNil: UUID? = nil

        let folder1 = try await service.createDirectory(name: "Folder 1", parentID: parentNil, userID: userID)
        let folder1ID = try folder1.requireID()

        let folder2 = try await service.createDirectory(name: "Folder 2", parentID: folder1ID, userID: userID)
        let folder2ID = try folder2.requireID()

        let file3 = FileMetadata(
            filename: "file3.txt",
            contentType: "text/plain",
            size: 7,
            parentID: folder2ID,
            ownerID: userID,
            ancestorIDs: [folder1ID, folder2ID]
        )
        try await file3.save(on: app.db)
        let file3ID = try file3.requireID()

        XCTAssertEqual(folder2.ancestorIDs, [folder1ID])
        XCTAssertEqual(file3.ancestorIDs, [folder1ID, folder2ID])

        let folder4 = try await service.createDirectory(name: "Folder 4", parentID: parentNil, userID: userID)
        let folder4ID = try folder4.requireID()

        _ = try await service.move(fileID: folder2ID, newParentID: folder4ID, userID: userID)

        guard let updatedFolder2 = try await FileMetadata.find(folder2ID, on: app.db),
              let updatedFile3 = try await FileMetadata.find(file3ID, on: app.db) else {
            XCTFail("Could not refetch files after move")
            return
        }

        XCTAssertEqual(updatedFolder2.$parent.id, folder4ID)
        XCTAssertEqual(updatedFolder2.ancestorIDs, [folder4ID])
        XCTAssertEqual(updatedFile3.ancestorIDs, [folder4ID, folder2ID])

        // Test cycle prevention (cannot move Folder 4 into Folder 2)
        do {
            _ = try await service.move(fileID: folder4ID, newParentID: folder2ID, userID: userID)
            XCTFail("Should have thrown error when attempting cycle move")
        } catch {
        }
    }
}
