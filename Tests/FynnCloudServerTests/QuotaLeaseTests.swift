import XCTest
import Fluent
import FluentSQLiteDriver
import SQLKit
import Vapor
@preconcurrency import Redis
@testable import FynnCloudServer

final class QuotaLeaseTests: XCTestCase {
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
        app.migrations.add(AddAllUsersGroup())
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
        try await TestRedis.configure(app)
        app.http.server.configuration.port = 0
        try routes(app)
        try await app.startup()
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
    }

    func testQuotaLeaseAndMultipartLifecycle() async throws {
        let db = app.db
        let userID = UUID()

        let tier = StorageTier(name: "TestTier", limitBytes: 1000)
        try await tier.save(on: db)
        let tierID = try tier.requireID()

        let user = User(
            id: userID,
            username: "quotauser",
            email: "quota@test.com",
            passwordHash: "hash",
            tierID: tierID
        )
        try await user.save(on: db)

        let mockProvider = MockStorageProvider()
        let eventLoop = app.eventLoopGroup.next()
        let storageService = StorageService(provider: mockProvider, eventLoop: eventLoop)
        let dummyRequest = Request(application: app, on: eventLoop)
        let files = FileServiceContext(
            db: db,
            logger: app.logger,
            storage: storageService,
            redis: dummyRequest.redis
        )

        // 1. Initiate 400 bytes upload
        let session = try await files.uploads.initiateMultipartUpload(
            filename: "upload1.txt",
            contentType: "text/plain",
            totalSize: 400,
            parentID: nil,
            lastModified: nil,
            userID: userID,
            maxChunkSize: Int64(app.config.maxChunkSize.value)
        )

        // Verify DB current_storage_usage is still 0 (not mutated at initiation)
        let userAfterInitiate = try await User.find(userID, on: db)
        XCTAssertEqual(userAfterInitiate?.currentStorageUsage, 0, "DB current_storage_usage should not be incremented at initiation")

        // 2. Reserving 700 more bytes must fail: 0 committed + 400 pending + 700 > 1000.
        do {
            _ = try await files.quota.reserve(
                bytes: 700, for: .upload(fileID: UUID()), userID: userID)
            XCTFail("Should have thrown quota exceeded error")
        } catch let abort as AbortError {
            XCTAssertEqual(abort.status, .payloadTooLarge)
        }

        // 3. Complete the 400 bytes upload
        let completedPart = CompletedPart(partNumber: 1, etag: "hash1", size: 400)
        _ = try await files.uploads.completeMultipartUpload(
            sessionID: session.sessionID,
            fileID: session.fileID,
            uploadID: session.uploadID,
            userID: userID,
            filename: session.filename,
            contentType: "text/plain",
            totalSize: 400,
            parentID: nil,
            lastModified: nil,
            reservationID: session.reservationID,
            parts: [completedPart]
        )

        // Verify DB current_storage_usage is now 400
        let userAfterComplete = try await User.find(userID, on: db)
        XCTAssertEqual(userAfterComplete?.currentStorageUsage, 400, "DB current_storage_usage should be committed upon completion")
        let usageAfterComplete = try await files.quota.usage(for: userID)
        XCTAssertEqual(usageAfterComplete.pending, 0, "The reservation must be released on commit")
    }

    /// A second upload started while the first is still in flight must be rejected, even though
    /// the quota endpoint still reports the pre-upload usage.
    func testSecondUploadRejectedWhileFirstIsStillInFlight() async throws {
        let db = app.db
        let userID = UUID()

        let tier = StorageTier(name: "TestTierInFlight", limitBytes: 1000)
        try await tier.save(on: db)

        let user = User(
            id: userID,
            username: "inflightuser",
            email: "inflight@test.com",
            passwordHash: "hash",
            tierID: try tier.requireID()
        )
        try await user.save(on: db)

        let eventLoop = app.eventLoopGroup.next()
        let files = FileServiceContext(
            db: db,
            logger: app.logger,
            storage: StorageService(provider: MockStorageProvider(), eventLoop: eventLoop),
            redis: Request(application: app, on: eventLoop).redis
        )

        _ = try await files.uploads.initiateMultipartUpload(
            filename: "first.bin",
            contentType: "application/octet-stream",
            totalSize: 600,
            parentID: nil,
            lastModified: nil,
            userID: userID,
            maxChunkSize: Int64(app.config.maxChunkSize.value)
        )

        // What the user is shown has not moved: nothing is stored yet.
        let usage = try await files.quota.usage(for: userID)
        XCTAssertEqual(usage.committed, 0)
        XCTAssertEqual(usage.pending, 600)

        // ...but the 600 bytes in flight are still spent, so this no longer fits.
        do {
            _ = try await files.uploads.initiateMultipartUpload(
                filename: "second.bin",
                contentType: "application/octet-stream",
                totalSize: 600,
                parentID: nil,
                lastModified: nil,
                userID: userID,
                maxChunkSize: Int64(app.config.maxChunkSize.value)
            )
            XCTFail("The second upload must not be admitted")
        } catch let abort as any AbortError {
            XCTAssertEqual(abort.status, .payloadTooLarge)
        }

        let after = try await files.quota.usage(for: userID)
        XCTAssertEqual(after.pending, 600, "The rejected upload must not leave a hold behind")
        XCTAssertEqual(after.committed, 0)
    }

    func testMultipartFileUpdate() async throws {
        let db = app.db
        let userID = UUID()

        let tier = StorageTier(name: "TestTierUpdate", limitBytes: 1000)
        try await tier.save(on: db)
        let tierID = try tier.requireID()

        let user = User(
            id: userID,
            username: "updateuser",
            email: "update@test.com",
            passwordHash: "hash",
            tierID: tierID
        )
        try await user.save(on: db)

        let mockProvider = MockStorageProvider()
        let eventLoop = app.eventLoopGroup.next()
        let storageService = StorageService(provider: mockProvider, eventLoop: eventLoop)
        let dummyRequest = Request(application: app, on: eventLoop)
        let files = FileServiceContext(
            db: db,
            logger: app.logger,
            storage: storageService,
            redis: dummyRequest.redis
        )

        // 1. Initial file upload: 200 bytes
        let createSession = try await files.uploads.initiateMultipartUpload(
            filename: "photo.png",
            contentType: "image/png",
            totalSize: 200,
            parentID: nil as UUID?,
            lastModified: nil as Int64?,
            userID: userID,
            maxChunkSize: Int64(app.config.maxChunkSize.value)
        )
        XCTAssertFalse(createSession.isUpdate)

        let part1 = CompletedPart(partNumber: 1, etag: "hash1", size: 200)
        let createdFile = try await files.uploads.completeMultipartUpload(
            sessionID: createSession.sessionID,
            fileID: createSession.fileID,
            uploadID: createSession.uploadID,
            userID: userID,
            filename: createSession.filename,
            contentType: "image/png",
            totalSize: 200,
            parentID: nil as UUID?,
            lastModified: nil as Int64?,
            isUpdate: false,
            reservationID: createSession.reservationID,
            parts: [part1]
        )
        XCTAssertEqual(createdFile.size, 200)

        let userAfterCreate = try await User.find(userID, on: db)
        XCTAssertEqual(userAfterCreate?.currentStorageUsage, 200)

        // 2. Update existing file via multipart: 500 bytes (delta = +300)
        let updateSession = try await files.uploads.initiateMultipartUpload(
            fileID: createdFile.id,
            filename: "photo.png",
            contentType: "image/png",
            totalSize: 500,
            parentID: nil as UUID?,
            lastModified: nil as Int64?,
            userID: userID,
            maxChunkSize: Int64(app.config.maxChunkSize.value)
        )
        XCTAssertTrue(updateSession.isUpdate)
        XCTAssertEqual(updateSession.fileID, createdFile.id)

        let partUpdate = CompletedPart(partNumber: 1, etag: "hash2", size: 500)
        let updatedFile = try await files.uploads.completeMultipartUpload(
            sessionID: updateSession.sessionID,
            fileID: updateSession.fileID,
            uploadID: updateSession.uploadID,
            userID: userID,
            filename: updateSession.filename,
            contentType: "image/png",
            totalSize: 500,
            parentID: nil as UUID?,
            lastModified: nil as Int64?,
            isUpdate: true,
            reservationID: updateSession.reservationID,
            parts: [partUpdate]
        )
        XCTAssertEqual(updatedFile.id, createdFile.id)
        XCTAssertEqual(updatedFile.size, 500)

        // Verify quota is updated to 500
        let userAfterUpdate = try await User.find(userID, on: db)
        XCTAssertEqual(userAfterUpdate?.currentStorageUsage, 500)

        // Verify SyncLog has .modify event
        let logs = try await SyncLog.query(on: db)
            .filter(\.$file.$id == createdFile.id!)
            .sort(\.$seq, .descending)
            .all()
        XCTAssertGreaterThanOrEqual(logs.count, 2)
        XCTAssertEqual(logs.first?.eventType, .modify)
        XCTAssertEqual(logs.first?.size, 500)
    }

    func testOrphanedChunkDirectoryCleanup() async throws {
        let localProvider = TestStorage.createLocalProvider()
        let fm = FileManager.default
        let storageDir = localProvider.storageDirectory

        let userID = UUID()
        let oldFileID = UUID()
        let oldUploadID = "old_upload_1"

        let oldChunkDirPath = "\(storageDir)\(userID.uuidString)/_system/chunks/\(oldFileID.uuidString)/\(oldUploadID)"
        try fm.createDirectory(atPath: oldChunkDirPath, withIntermediateDirectories: true)
        let dummyPartPath = "\(oldChunkDirPath)/part_1"
        try "chunk data".write(toFile: dummyPartPath, atomically: true, encoding: .utf8)

        // Set modification time of old chunk folder to 3 days ago
        let threeDaysAgo = Date().addingTimeInterval(-3 * 86400)
        try fm.setAttributes([.modificationDate: threeDaysAgo], ofItemAtPath: oldChunkDirPath)

        // Create fresh chunk folder
        let freshFileID = UUID()
        let freshUploadID = "fresh_upload_1"
        let freshChunkDirPath = "\(storageDir)\(userID.uuidString)/_system/chunks/\(freshFileID.uuidString)/\(freshUploadID)"
        try fm.createDirectory(atPath: freshChunkDirPath, withIntermediateDirectories: true)
        try "fresh chunk data".write(toFile: "\(freshChunkDirPath)/part_1", atomically: true, encoding: .utf8)

        // Run sweeper with 48h cutoff
        await localProvider.cleanupOrphanedChunkDirectories(olderThan: 48 * 3600)

        // Assert old folder deleted, fresh folder kept
        XCTAssertFalse(fm.fileExists(atPath: oldChunkDirPath), "Expired chunk folder should be deleted by sweeper")
        XCTAssertTrue(fm.fileExists(atPath: freshChunkDirPath), "Fresh chunk folder should not be deleted")
    }
}
