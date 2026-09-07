import XCTest
import Vapor
import Fluent
import FluentSQLiteDriver
import SQLKit
@testable import FynnCloudServer

final class SyncLogTests: XCTestCase {
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
        app.migrations.add(CreateInternalShares())
        app.migrations.add(DropOAuthCodes())
        app.migrations.add(CreateUserFavorites())
        app.migrations.add(DropMultipartUploadSessions())
        app.migrations.add(AddFavoritesAndSharesToSyncTriggers())
        app.migrations.add(DropSyncTriggersMigration())

        try! app.autoMigrate().wait()
        try await TestRedis.configure(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        app = nil
    }

    func testSyncLogModelAndDeltaResponse() async throws {
        let user = User(username: "syncuser", email: "sync@test.local", passwordHash: "dummy")
        try await user.save(on: app.db)
        let userID = try user.requireID()

        let fileID = UUID()
        let parentID = UUID()

        let log = SyncLog(
            userID: userID,
            fileID: fileID,
            seq: 1,
            eventType: .create,
            contentUpdated: true,
            filename: "Document.pdf",
            isDirectory: false,
            size: 1024,
            hash: "abc123hash",
            parentID: parentID,
            lastModified: Date(),
            oldFilename: nil,
            oldParentID: nil
        )
        try await log.save(on: app.db)

        let fetched = try await SyncLog.query(on: app.db)
            .filter(\.$user.$id == userID)
            .first()

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.eventType, .create)
        XCTAssertEqual(fetched?.filename, "Document.pdf")
        XCTAssertEqual(fetched?.size, 1024)
        XCTAssertEqual(fetched?.hash, "abc123hash")
        XCTAssertEqual(fetched?.parentID, parentID)
        XCTAssertEqual(fetched?.contentUpdated, true)
    }

    func testSyncLogServiceEmit() async throws {
        let user = User(username: "serviceuser", email: "service@test.local", passwordHash: "dummy")
        try await user.save(on: app.db)
        let userID = try user.requireID()

        let service = SyncLogService()
        let fileID = UUID()

        try await service.emit(
            on: app.db,
            userID: userID,
            fileID: fileID,
            eventType: .create,
            contentUpdated: true,
            filename: "TestDoc.txt",
            isDirectory: false,
            size: 512
        )

        try await service.emit(
            on: app.db,
            userID: userID,
            fileID: fileID,
            eventType: .rename,
            contentUpdated: false,
            filename: "NewTestDoc.txt",
            oldFilename: "TestDoc.txt"
        )

        let logs = try await SyncLog.query(on: app.db)
            .filter(\.$user.$id == userID)
            .sort(\.$seq, .ascending)
            .all()

        XCTAssertEqual(logs.count, 2)
        XCTAssertEqual(logs[0].eventType, .create)
        XCTAssertEqual(logs[0].filename, "TestDoc.txt")
        XCTAssertEqual(logs[0].seq, 1)

        XCTAssertEqual(logs[1].eventType, .rename)
        XCTAssertEqual(logs[1].filename, "NewTestDoc.txt")
        XCTAssertEqual(logs[1].oldFilename, "TestDoc.txt")
        XCTAssertEqual(logs[1].seq, 2)
    }

    func testSyncLogServiceFavoriteAndShare() async throws {
        let owner = User(username: "shareowner", email: "owner@test.local", passwordHash: "dummy")
        try await owner.save(on: app.db)
        let ownerID = try owner.requireID()

        let recipient = User(username: "sharerecipient", email: "recip@test.local", passwordHash: "dummy")
        try await recipient.save(on: app.db)
        let recipientID = try recipient.requireID()

        let file = FileMetadata(
            filename: "SharedFolder",
            contentType: "directory",
            size: 0,
            isDirectory: true,
            parentID: nil,
            ownerID: ownerID
        )
        try await file.save(on: app.db)

        let service = SyncLogService()

        // Test Favorite
        try await service.emitFavorite(on: app.db, userID: ownerID, file: file, isFavorite: true)
        var ownerLogs = try await SyncLog.query(on: app.db).filter(\.$user.$id == ownerID).all()
        XCTAssertEqual(ownerLogs.count, 1)
        XCTAssertEqual(ownerLogs[0].eventType, .favorite)

        // Test Internal Share
        let share = InternalShare(
            fileID: try file.requireID(),
            granteeType: .user,
            granteeUserID: recipientID,
            role: .viewer,
            createdBy: ownerID
        )
        try await share.save(on: app.db)

        try await service.emitInternalShare(on: app.db, share: share, file: file, eventType: .share)

        ownerLogs = try await SyncLog.query(on: app.db).filter(\.$user.$id == ownerID).sort(\.$seq, .ascending).all()
        XCTAssertEqual(ownerLogs.count, 2)
        XCTAssertEqual(ownerLogs[1].eventType, .share)

        let recipientLogs = try await SyncLog.query(on: app.db).filter(\.$user.$id == recipientID).all()
        XCTAssertEqual(recipientLogs.count, 1)
        XCTAssertEqual(recipientLogs[0].eventType, .create)
        XCTAssertNil(recipientLogs[0].parentID) // Placed in virtual "Shared with me" root

        // Test Unshare
        try await service.emitInternalShare(on: app.db, share: share, file: file, eventType: .unshare)

        let recipientLogsAfterUnshare = try await SyncLog.query(on: app.db)
            .filter(\.$user.$id == recipientID)
            .sort(\.$seq, .ascending)
            .all()
        XCTAssertEqual(recipientLogsAfterUnshare.count, 2)
        XCTAssertEqual(recipientLogsAfterUnshare[1].eventType, .delete)
    }

    func testPerFileActivityQuery() async throws {
        let user = User(username: "activityuser", email: "activity@test.local", passwordHash: "dummy")
        user.displayName = "Activity Tester"
        try await user.save(on: app.db)
        let userID = try user.requireID()

        let fileID = UUID()
        let service = SyncLogService()

        // 1. Emit create
        try await service.emit(
            on: app.db,
            userID: userID,
            fileID: fileID,
            eventType: .create,
            contentUpdated: true,
            filename: "Report.docx",
            isDirectory: false,
            size: 2048,
            hash: "hash_v1"
        )

        // 2. Emit rename
        try await service.emit(
            on: app.db,
            userID: userID,
            fileID: fileID,
            eventType: .rename,
            contentUpdated: false,
            filename: "Final_Report.docx",
            oldFilename: "Report.docx"
        )

        // 3. Emit modify
        try await service.emit(
            on: app.db,
            userID: userID,
            fileID: fileID,
            eventType: .modify,
            contentUpdated: true,
            filename: "Final_Report.docx",
            size: 4096,
            hash: "hash_v2"
        )

        // Query by fileID and eager-load user
        let logs = try await SyncLog.query(on: app.db)
            .with(\.$user)
            .filter(\.$file.$id == fileID)
            .sort(\.$createdAt, .descending)
            .all()

        XCTAssertEqual(logs.count, 3)
        XCTAssertEqual(logs[0].eventType, .modify)
        XCTAssertEqual(logs[0].size, 4096)
        XCTAssertEqual(logs[0].$user.value?.displayName, "Activity Tester")

        XCTAssertEqual(logs[1].eventType, .rename)
        XCTAssertEqual(logs[1].filename, "Final_Report.docx")
        XCTAssertEqual(logs[1].oldFilename, "Report.docx")

        XCTAssertEqual(logs[2].eventType, .create)
        XCTAssertEqual(logs[2].filename, "Report.docx")
        XCTAssertEqual(logs[2].size, 2048)
    }
}
