import XCTest
import Fluent
import FluentSQLiteDriver
import Vapor
@testable import FynnCloudServer

final class FileRestoreTests: XCTestCase {
    var app: Application!
    
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
        
        try await app.autoMigrate()
        app.config = try ServerConfig.load(for: app)
    }
    
    override func tearDown() async throws {
        try await app.asyncShutdown()
    }
    
    func testFileRestore() async throws {
        let db = app.db
        let userID = UUID()
        
        let user = User(id: userID, username: "testuser", email: "test@test.com", passwordHash: "hash")
        try await user.save(on: db)
        
        let mockProvider = TestStorage.createLocalProvider()
        let storageService = StorageService(provider: mockProvider, eventLoop: app.eventLoopGroup.next())
        let service = FileService(
            FileServiceContext(
                db: db, logger: app.logger,
                storage: storageService, redis: try await TestRedis.configure(app)))
        
        let folderA = FileMetadata(id: UUID(), filename: "Folder A", contentType: "directory", size: 0, isDirectory: true, parentID: nil, ownerID: userID)
        try await folderA.save(on: db)
        
        let fileB = FileMetadata(id: UUID(), filename: "File B.txt", contentType: "text/plain", size: 100, isDirectory: false, parentID: try folderA.requireID(), ownerID: userID)
        try await fileB.save(on: db)
        
        try await service.moveToTrash(fileID: try folderA.requireID(), userID: userID)
        
        let folderADel = try await FileMetadata.query(on: db).withDeleted().filter(\.$id == folderA.requireID()).first()
        let fileBDel = try await FileMetadata.query(on: db).withDeleted().filter(\.$id == fileB.requireID()).first()
        
        XCTAssertNotNil(folderADel?.deletedAt)
        XCTAssertNotNil(fileBDel?.deletedAt)
        XCTAssertEqual(folderADel?.trashGroupID, fileBDel?.trashGroupID)
        XCTAssertEqual(fileBDel?.originalParentID, try folderA.requireID())
        
        let restoredFolder = try await service.restore(fileID: try folderA.requireID(), userID: userID)
        XCTAssertNil(restoredFolder.deletedAt)
        XCTAssertNil(restoredFolder.trashGroupID)
        
        let folderAFromDB = try await FileMetadata.query(on: db).filter(\.$id == folderA.requireID()).first()
        XCTAssertNotNil(folderAFromDB)
        XCTAssertNil(folderAFromDB?.deletedAt)
        
        let fileBAfter = try await FileMetadata.query(on: db).filter(\.$id == fileB.requireID()).first()
        XCTAssertNotNil(fileBAfter)
        XCTAssertNil(fileBAfter?.deletedAt)
        XCTAssertNil(fileBAfter?.trashGroupID)
        XCTAssertEqual(fileBAfter?.$parent.id, try folderA.requireID())
    }

    func testRestoreChildOfDeletedParent() async throws {
        let db = app.db
        let userID = UUID()
        
        let user = User(id: userID, username: "testuser", email: "test@test.com", passwordHash: "hash")
        try await user.save(on: db)
        
        let mockProvider = TestStorage.createLocalProvider()
        let storageService = StorageService(provider: mockProvider, eventLoop: app.eventLoopGroup.next())
        let service = FileService(
            FileServiceContext(
                db: db, logger: app.logger,
                storage: storageService, redis: try await TestRedis.configure(app)))
        
        let folderA = FileMetadata(id: UUID(), filename: "Folder A", contentType: "directory", size: 0, isDirectory: true, parentID: nil, ownerID: userID)
        try await folderA.save(on: db)
        
        let fileB = FileMetadata(id: UUID(), filename: "File B.txt", contentType: "text/plain", size: 100, isDirectory: false, parentID: try folderA.requireID(), ownerID: userID)
        try await fileB.save(on: db)
        
        try await service.moveToTrash(fileID: try folderA.requireID(), userID: userID)
        
        let restoredFile = try await service.restore(fileID: try fileB.requireID(), userID: userID)
        
        XCTAssertNil(restoredFile.deletedAt)
        XCTAssertNil(restoredFile.trashGroupID)
        XCTAssertNil(restoredFile.$parent.id)
    }

    func testRestoreNameConflict() async throws {
        let db = app.db
        let userID = UUID()
        
        let user = User(id: userID, username: "testuser", email: "test@test.com", passwordHash: "hash")
        try await user.save(on: db)
        
        let mockProvider = TestStorage.createLocalProvider()
        let storageService = StorageService(provider: mockProvider, eventLoop: app.eventLoopGroup.next())
        let service = FileService(
            FileServiceContext(
                db: db, logger: app.logger,
                storage: storageService, redis: try await TestRedis.configure(app)))
        
        let fileB1 = FileMetadata(id: UUID(), filename: "File B.txt", contentType: "text/plain", size: 100, isDirectory: false, parentID: nil, ownerID: userID)
        try await fileB1.save(on: db)
        
        let fileB2 = FileMetadata(id: UUID(), filename: "File B.txt", contentType: "text/plain", size: 200, isDirectory: false, parentID: nil, ownerID: userID)
        try await fileB2.save(on: db)
        
        try await service.moveToTrash(fileID: try fileB2.requireID(), userID: userID)
        
        let restoredFile = try await service.restore(fileID: try fileB2.requireID(), userID: userID)
        
        XCTAssertNil(restoredFile.deletedAt)
        XCTAssertEqual(restoredFile.filename, "File B (restored).txt")
    }

    func testFileDownloadCaching() async throws {
        let db = app.db
        let userID = UUID()
        
        let user = User(id: userID, username: "cachinguser", email: "cache@test.com", passwordHash: "hash")
        try await user.save(on: db)
        
        let fileID = UUID()
        let file = FileMetadata(
            id: fileID,
            filename: "cachedFile.txt",
            contentType: "text/plain",
            size: 1234,
            isDirectory: false,
            parentID: nil,
            ownerID: userID,
            hash: "mockhash123"
        )
        try await file.save(on: db)
        
        let mockProvider = MockStorageProvider()
        app.fileStorage = mockProvider
        
        let req1 = Request(application: app, method: .GET, url: "/api/files/\(fileID.uuidString)/download", on: app.eventLoopGroup.next())
        let userPayload = UserPayload(
            subject: .init(value: userID.uuidString),
            expiration: .init(value: Date().addingTimeInterval(3600)),
            grantID: UUID(),
            jti: .init(value: UUID().uuidString)
        )
        req1.auth.login(userPayload)
        req1.parameters.set("fileID", to: fileID.uuidString)
        
        let fileController = FileController()
        let response1 = try await fileController.download(req: req1)
        
        XCTAssertEqual(response1.status, .ok)
        XCTAssertEqual(response1.headers.first(name: .eTag), "\"mockhash123\"")
        XCTAssertEqual(response1.headers.first(name: .cacheControl), "no-cache")
        
        let req2 = Request(application: app, method: .GET, url: "/api/files/\(fileID.uuidString)/download", on: app.eventLoopGroup.next())
        req2.auth.login(userPayload)
        req2.parameters.set("fileID", to: fileID.uuidString)
        req2.headers.add(name: .ifNoneMatch, value: "\"mockhash123\"")
        
        let response2 = try await fileController.download(req: req2)
        XCTAssertEqual(response2.status, .notModified)
        XCTAssertEqual(response2.headers.first(name: .eTag), "\"mockhash123\"")
        XCTAssertEqual(response2.headers.first(name: .cacheControl), "no-cache")
        
        let req3 = Request(application: app, method: .GET, url: "/api/files/\(fileID.uuidString)/download", on: app.eventLoopGroup.next())
        req3.auth.login(userPayload)
        req3.parameters.set("fileID", to: fileID.uuidString)
        req3.headers.add(name: .ifNoneMatch, value: "\"oldhash456\"")
        
        let response3 = try await fileController.download(req: req3)
        XCTAssertEqual(response3.status, .ok)
        XCTAssertEqual(response3.headers.first(name: .eTag), "\"mockhash123\"")
    }
}
