import Fluent
import FluentSQLiteDriver
import NIOCore
@preconcurrency import Redis
import SQLKit
import Vapor
import XCTest

@testable import FynnCloudServer

/// Regression guards for the two-tier quota model: the durable counter only ever moves at commit
/// with the real byte count, and admission is atomic.
final class QuotaAccountingTests: XCTestCase {
    var app: Application!
    var files: FileServiceContext!
    var userID: UUID!
    var saveRecorder: SaveRecorder!

    /// Reports a fixed stored size (so claimed-vs-actual drift is reproducible) and records
    /// whether any bytes were handed to the provider at all.
    actor SaveRecorder {
        private(set) var saveCount = 0
        var reportedSize: Int64 = 0

        func record() { saveCount += 1 }
        func setReportedSize(_ size: Int64) { reportedSize = size }
    }

    struct RecordingProvider: FileStorageProvider {
        let recorder: SaveRecorder

        func save(stream: Request.Body, key: String, maxSize: Int64, on eventLoop: any EventLoop)
            async throws -> StorageSaveResult
        {
            await recorder.record()
            return StorageSaveResult(size: await recorder.reportedSize, hash: "hash")
        }
        func save(buffer: ByteBuffer, key: String, contentType: String) async throws {
            await recorder.record()
        }
        func getResponse(key: String, range: HTTPHeaders.Range?, on eventLoop: any EventLoop)
            async throws -> Response
        {
            Response(status: .ok)
        }
        func downloadToFile(key: String, path: String, on eventLoop: any EventLoop) async throws {}
        func delete(key: String) async throws {}
        func exists(key: String) async throws -> Bool { true }
        func copy(sourceKey: String, destinationKey: String) async throws {}
        func initiateMultipartUpload(key: String) async throws -> String { "uploadid" }
        func uploadPart(
            key: String, uploadID: String, partNumber: Int, stream: Request.Body, maxSize: Int64,
            on eventLoop: any EventLoop
        ) async throws -> CompletedPart {
            CompletedPart(partNumber: partNumber, etag: "part", size: 0)
        }
        func completeMultipartUpload(key: String, uploadID: String, parts: [CompletedPart])
            async throws -> MultipartCompletionResult
        {
            MultipartCompletionResult(hash: "hash", size: parts.reduce(0) { $0 + $1.size })
        }
        func abortMultipartUpload(key: String, uploadID: String) async throws {}
        func deleteUserData(userID: UUID) async throws {}
    }

    override func setUp() async throws {
        app = try await Application.make(.testing)
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
        app.migrations.add(CreateInternalShares())
        try await app.autoMigrate()

        app.config = try ServerConfig.load(for: app)
        let redis = try await TestRedis.configure(app)

        let tier = StorageTier(name: "QuotaAccountingTier", limitBytes: 10_000_000)
        try await tier.save(on: app.db)
        userID = UUID()
        try await User(
            id: userID,
            username: "quotaaccounting",
            email: "quota-accounting@test.com",
            passwordHash: "hash",
            tierID: try tier.requireID()
        ).save(on: app.db)

        saveRecorder = SaveRecorder()
        files = FileServiceContext(
            db: app.db,
            logger: app.logger,
            storage: StorageService(
                provider: RecordingProvider(recorder: saveRecorder),
                eventLoop: app.eventLoopGroup.next()),
            redis: redis)
    }

    override func tearDown() async throws {
        await files.quota.releaseAll(userID: userID)
        try await app.asyncShutdown()
    }

    private func emptyBody() -> Request.Body {
        Request(application: app, on: app.eventLoopGroup.next()).body
    }

    private func committedUsage() async throws -> Int64 {
        try await User.find(userID, on: app.db)?.currentStorageUsage ?? -1
    }

    /// Claiming slightly more than is stored used to leak the difference into the durable counter
    /// whenever it stayed under the 1 MB tolerance.
    func testUploadCommitsActualSizeNotClaimedSize() async throws {
        await saveRecorder.setReportedSize(1_000)

        var expected: Int64 = 0
        for index in 0..<5 {
            _ = try await files.files.upload(
                filename: "drift-\(index).bin",
                stream: emptyBody(),
                claimedSize: 1_500,
                contentType: "application/octet-stream",
                parentID: nil,
                userID: userID)
            expected += 1_000
        }

        let usage = try await committedUsage()
        XCTAssertEqual(usage, expected, "Usage must equal the bytes actually stored")

        let sizes = try await FileMetadata.query(on: app.db)
            .filter(\.$owner.$id == userID).all().reduce(Int64(0)) { $0 + $1.size }
        XCTAssertEqual(usage, sizes)
    }

    /// A shrinking update must lower usage, never raise it.
    func testShrinkingUpdateLowersUsage() async throws {
        await saveRecorder.setReportedSize(5_000)
        let file = try await files.files.upload(
            filename: "shrink.bin",
            stream: emptyBody(),
            claimedSize: 5_000,
            contentType: "application/octet-stream",
            parentID: nil,
            userID: userID)
        do {
            let usage = try await committedUsage()
            XCTAssertEqual(usage, 5_000)
        }

        await saveRecorder.setReportedSize(1_000)
        _ = try await files.files.update(
            fileID: try file.requireID(),
            stream: emptyBody(),
            claimedSize: 1_000,
            contentType: "application/octet-stream",
            userID: userID)

        let committed = try await committedUsage()
        XCTAssertEqual(committed, 1_000)
        let usage = try await files.quota.usage(for: userID)
        XCTAssertEqual(usage.pending, 0)
    }

    /// The old implementation wrote the stream first and only then checked the quota, leaving new
    /// bytes on disk with the old size recorded.
    func testUpdateRejectsBeforeWritingToStorage() async throws {
        await saveRecorder.setReportedSize(100)
        let file = try await files.files.upload(
            filename: "reject.bin",
            stream: emptyBody(),
            claimedSize: 100,
            contentType: "application/octet-stream",
            parentID: nil,
            userID: userID)

        let savesBefore = await saveRecorder.saveCount

        do {
            _ = try await files.files.update(
                fileID: try file.requireID(),
                stream: emptyBody(),
                claimedSize: 50_000_000,
                contentType: "application/octet-stream",
                userID: userID)
            XCTFail("Expected the update to be rejected on quota")
        } catch let abort as any AbortError {
            XCTAssertEqual(abort.status, .payloadTooLarge)
        }

        let savesAfter = await saveRecorder.saveCount
        XCTAssertEqual(savesAfter, savesBefore, "No bytes may reach the provider after a rejection")
        let committed = try await committedUsage()
        XCTAssertEqual(committed, 100)
    }

    /// Admission is a single round trip, so concurrent requests that each fit individually but not
    /// collectively cannot all be admitted.
    func testConcurrentReservationsCannotOvershootTheLimit() async throws {
        let limit = try await files.quota.usage(for: userID).limit
        let bytes = limit / 2  // Any two fit; three do not.

        let quota = files.quota
        let uid = userID!
        let admitted = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    ((try? await quota.reserve(
                        bytes: bytes, for: .upload(fileID: UUID()), userID: uid)) != nil)
                }
            }
            var count = 0
            for await success in group where success { count += 1 }
            return count
        }

        XCTAssertEqual(admitted, 2, "Exactly the reservations that fit may be admitted")
        let usage = try await files.quota.usage(for: userID)
        XCTAssertEqual(usage.pending, bytes * 2)
        let committed = try await committedUsage()
        XCTAssertEqual(committed, 0, "Reservations never touch the durable counter")
    }

    /// An orphaned hold is untraceable if the Redis field is an anonymous id, and two writes
    /// against the same file must not share a field or the second would replace the first.
    func testReservationFieldIdentifiesItsHolder() async throws {
        let fileID = UUID()
        let first = try await files.quota.reserve(
            bytes: 10, for: .update(fileID: fileID), userID: userID)
        let second = try await files.quota.reserve(
            bytes: 10, for: .update(fileID: fileID), userID: userID)

        XCTAssertTrue(first.id.hasPrefix("update:\(fileID.uuidString):"), first.id)
        XCTAssertNotEqual(first.id, second.id)

        let fields = try await app.redis.hgetall(
            from: QuotaService.pendingKey(userID: userID)
        ).get()
        XCTAssertEqual(Set(fields.keys), [first.id, second.id])

        let pending = try await files.quota.usage(for: userID).pending
        XCTAssertEqual(pending, 20, "Same-file reservations must add up, not collapse")
    }

    /// Holds expire individually. A single TTL on the whole hash would let a later long-lived
    /// reservation keep an abandoned one alive indefinitely on an active account.
    func testExpiryIsPerHoldNotPerUser() async throws {
        _ = try await files.quota.reserve(
            bytes: 1_000, for: .upload(fileID: UUID()), userID: userID, ttl: 1)
        let live = try await files.quota.reserve(
            bytes: 500, for: .upload(fileID: UUID()), userID: userID)

        try await Task.sleep(nanoseconds: 1_500_000_000)

        let pending = try await files.quota.usage(for: userID).pending
        XCTAssertEqual(pending, 500, "The abandoned hold must stop counting on its own expiry")

        // Pruning happens on the next admission, not on read.
        _ = try await files.quota.reserve(
            bytes: 1, for: .upload(fileID: UUID()), userID: userID)
        let fields = try await app.redis.hgetall(
            from: QuotaService.pendingKey(userID: userID)
        ).get()
        XCTAssertEqual(fields.count, 2, "The expired hold must be dropped from the hash")
        XCTAssertTrue(fields.keys.contains(live.id))
    }

    /// An in-flight reservation is an admission detail. The number the user sees must not move
    /// until bytes are actually stored, or an abandoned multipart session shows phantom usage.
    func testReportedUsageIgnoresInFlightReservations() async throws {
        let reservation = try await files.quota.reserve(
            bytes: 4_000, for: .multipart(sessionID: UUID()), userID: userID)

        let usage = try await files.quota.usage(for: userID)
        XCTAssertEqual(usage.pending, 4_000, "The hold is real for admission")
        XCTAssertEqual(usage.committed, 0, "...but invisible to the user until it commits")

        try await files.quota.commit(reservation, actualBytes: 4_000)
        let afterCommit = try await files.quota.usage(for: userID)
        XCTAssertEqual(afterCommit.committed, 4_000)
        XCTAssertEqual(afterCommit.pending, 0)
    }

    /// A session opened claiming a small `totalSize` must not be completable with parts that sum
    /// to far more than that - the declared size only sizes the quota hold at initiate, so an
    /// unreconciled assembly would let a client reserve little and store (and get committed) a lot.
    func testCompletionRejectsSizeFarBeyondDeclaredTotal() async throws {
        let session = try await files.uploads.initiateMultipartUpload(
            filename: "lied-about-size.bin",
            contentType: "application/octet-stream",
            totalSize: 100,
            parentID: nil,
            lastModified: nil,
            userID: userID,
            maxChunkSize: 10_000_000)

        let oversizedPart = CompletedPart(partNumber: 1, etag: "etag", size: 2_000_000)

        do {
            _ = try await files.uploads.completeMultipartUpload(
                sessionID: session.sessionID,
                fileID: session.fileID,
                uploadID: session.uploadID,
                userID: userID,
                filename: session.filename,
                contentType: session.contentType,
                totalSize: session.totalSize,
                parentID: session.parentID,
                lastModified: session.lastModified,
                reservationID: session.reservationID,
                parts: [oversizedPart])
            XCTFail("Expected the oversized completion to be rejected")
        } catch let abort as any AbortError {
            XCTAssertEqual(abort.status, .payloadTooLarge)
        }

        let fileCount = try await FileMetadata.query(on: app.db)
            .filter(\.$owner.$id == userID).count()
        XCTAssertEqual(fileCount, 0, "No metadata row may be created for a rejected completion")

        let committed = try await committedUsage()
        XCTAssertEqual(committed, 0, "Nothing may be committed for a rejected completion")
        let pending = try await files.quota.usage(for: userID).pending
        XCTAssertEqual(pending, 0, "The reservation must be released on rejection")
    }

    /// Expired holds are drained in bounded batches. Deleting them all at once would blow the Lua
    /// stack past ~8000 arguments and break every further admission for that user.
    func testPruningIsBoundedPerAdmission() async throws {
        // A live hold keeps the hash itself alive, so the stale ones survive to be pruned.
        _ = try await files.quota.reserve(bytes: 1, for: .upload(fileID: UUID()), userID: userID)
        for _ in 0..<150 {
            _ = try await files.quota.reserve(
                bytes: 1, for: .upload(fileID: UUID()), userID: userID, ttl: 1)
        }
        try await Task.sleep(nanoseconds: 1_500_000_000)

        let pendingWhileStale = try await files.quota.usage(for: userID).pending
        XCTAssertEqual(pendingWhileStale, 1, "Expired holds never count, pruned or not")

        _ = try await files.quota.reserve(
            bytes: 10, for: .upload(fileID: UUID()), userID: userID)

        // 1 live + (150 stale - 100 pruned) + 1 new.
        let fields = try await app.redis.hgetall(
            from: QuotaService.pendingKey(userID: userID)
        ).get()
        XCTAssertEqual(fields.count, 52)

        let pending = try await files.quota.usage(for: userID).pending
        XCTAssertEqual(pending, 11, "Leftover stale holds still must not be counted")
    }

    /// A server that dies mid-upload leaves a reservation behind; its expiry has to reclaim it.
    func testAbandonedReservationExpires() async throws {
        _ = try await files.quota.reserve(
            bytes: 1_000, for: .upload(fileID: UUID()), userID: userID, ttl: 1)
        let pendingBefore = try await files.quota.usage(for: userID).pending
        XCTAssertEqual(pendingBefore, 1_000)

        try await Task.sleep(nanoseconds: 1_500_000_000)

        let pendingAfter = try await files.quota.usage(for: userID).pending
        XCTAssertEqual(pendingAfter, 0)
        let committed = try await committedUsage()
        XCTAssertEqual(committed, 0, "The durable counter never moved")
    }
}
