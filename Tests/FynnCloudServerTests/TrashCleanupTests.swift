import XCTest
import Fluent
import FluentSQLiteDriver
import SQLKit
import Vapor
@testable import FynnCloudServer

final class TrashCleanupTests: XCTestCase {
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
    
    func testTrashCleanupDeletesExpiredFile() async throws {
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
        
        let expiredFileID = UUID()
        let expiredFile = FileMetadata(id: expiredFileID, filename: "expired.txt", contentType: "text/plain", size: 100, isDirectory: false, parentID: nil, ownerID: userID)
        try await expiredFile.save(on: db)
        try await service.moveToTrash(fileID: expiredFileID, userID: userID)
        
        let thirtyOneDaysAgo = Date().addingTimeInterval(-31 * 86400)
        let sql = db as! any SQLDatabase
        try await sql.raw("UPDATE file_metadata SET deleted_at = \(bind: thirtyOneDaysAgo) WHERE id = \(bind: expiredFileID)").run()
        
        let recentFileID = UUID()
        let recentFile = FileMetadata(id: recentFileID, filename: "recent.txt", contentType: "text/plain", size: 100, isDirectory: false, parentID: nil, ownerID: userID)
        try await recentFile.save(on: db)
        try await service.moveToTrash(fileID: recentFileID, userID: userID)
        
        let tenDaysAgo = Date().addingTimeInterval(-10 * 86400)
        try await sql.raw("UPDATE file_metadata SET deleted_at = \(bind: tenDaysAgo) WHERE id = \(bind: recentFileID)").run()
        
        await service.cleanupExpiredTrash(days: 30)
        
        let expiredInDB = try await FileMetadata.query(on: db).withDeleted().filter(\.$id == expiredFileID).first()
        XCTAssertNil(expiredInDB, "Expired file should be permanently deleted from database")
        
        let recentInDB = try await FileMetadata.query(on: db).withDeleted().filter(\.$id == recentFileID).first()
        XCTAssertNotNil(recentInDB, "Recent trash item should not be deleted")
    }
    
    func testTrashCleanupDeletesExpiredFolderWithChildren() async throws {
        let db = app.db
        let userID = UUID()
        
        let user = User(id: userID, username: "folderuser", email: "folder@test.com", passwordHash: "hash")
        try await user.save(on: db)
        
        let mockProvider = TestStorage.createLocalProvider()
        let storageService = StorageService(provider: mockProvider, eventLoop: app.eventLoopGroup.next())
        let service = FileService(
            FileServiceContext(
                db: db, logger: app.logger,
                storage: storageService, redis: try await TestRedis.configure(app)))
        
        let folderID = UUID()
        let folder = FileMetadata(id: folderID, filename: "OldFolder", contentType: "directory", size: 0, isDirectory: true, parentID: nil, ownerID: userID)
        try await folder.save(on: db)
        
        let childID = UUID()
        let child = FileMetadata(id: childID, filename: "child.png", contentType: "image/png", size: 500, isDirectory: false, parentID: folderID, ownerID: userID)
        try await child.save(on: db)
        
        try await service.moveToTrash(fileID: folderID, userID: userID)
        
        let thirtyFiveDaysAgo = Date().addingTimeInterval(-35 * 86400)
        let sql = db as! any SQLDatabase
        try await sql.raw("UPDATE file_metadata SET deleted_at = \(bind: thirtyFiveDaysAgo) WHERE id = \(bind: folderID) OR id = \(bind: childID)").run()
        
        await service.cleanupExpiredTrash(days: 30)
        
        let folderCheck = try await FileMetadata.query(on: db).withDeleted().filter(\.$id == folderID).first()
        let childCheck = try await FileMetadata.query(on: db).withDeleted().filter(\.$id == childID).first()
        
        XCTAssertNil(folderCheck, "Expired folder should be permanently deleted")
        XCTAssertNil(childCheck, "Child of expired folder should be permanently deleted")
    }
}
