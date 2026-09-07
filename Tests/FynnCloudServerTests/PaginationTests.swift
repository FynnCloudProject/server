import Fluent
import FluentSQLiteDriver
import Vapor
import XCTest

@testable import FynnCloudServer

/// `limit=-5` used to reach `Range.init(0..<(-5))` and trap the process; `page=-1` produced a
/// negative SQL offset. Both are clamped at the boundary now.
final class PaginationTests: XCTestCase {
    var app: Application!
    var files: FileServiceContext!
    var userID: UUID!

    func testPageRequestClampsHostileInput() {
        XCTAssertEqual(PageRequest(page: 0, limit: nil).page, 1)
        XCTAssertEqual(PageRequest(page: -1, limit: nil).page, 1)
        XCTAssertEqual(PageRequest(page: nil, limit: -5).limit, 1)
        XCTAssertEqual(PageRequest(page: nil, limit: 0).limit, 1)
        XCTAssertEqual(PageRequest(page: nil, limit: 99_999).limit, PageRequest.maxLimit)
        XCTAssertEqual(PageRequest(page: -1, limit: -5).offset, 0)
    }

    func testOmittingLimitReturnsTheWholeListing() {
        XCTAssertNil(PageRequest.unlimited.limit)
        XCTAssertEqual(PageRequest.unlimited.offset, 0)
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
        app.migrations.add(CreateUserFavorites())
        try await app.autoMigrate()

        app.config = try ServerConfig.load(for: app)
        let redis = try await TestRedis.configure(app)

        userID = UUID()
        try await User(
            id: userID,
            username: "paginationuser",
            email: "pagination@test.com",
            passwordHash: "hash"
        ).save(on: app.db)

        for index in 0..<5 {
            try await FileMetadata(
                id: UUID(), filename: "file-\(index).txt", contentType: "text/plain",
                size: 10, isDirectory: false, parentID: nil, ownerID: userID
            ).save(on: app.db)
        }

        files = FileServiceContext(
            db: app.db,
            logger: app.logger,
            storage: StorageService(
                provider: MockStorageProvider(), eventLoop: app.eventLoopGroup.next()),
            redis: redis)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
    }

    func testHostileWindowsReturnASaneListing() async throws {
        let windows = [
            PageRequest(page: nil, limit: -5),
            PageRequest(page: nil, limit: 0),
            PageRequest(page: 0, limit: 10),
            PageRequest(page: -1, limit: 10),
            PageRequest(page: nil, limit: 99_999),
        ]

        for window in windows {
            let index = try await files.listing.list(
                filter: .all, userID: userID, window: window)
            XCTAssertGreaterThanOrEqual(index.files.count, 1)
            XCTAssertLessThanOrEqual(index.files.count, 5)
        }
    }

    func testUnlimitedWindowReturnsEverything() async throws {
        let index = try await files.listing.list(filter: .all, userID: userID)
        XCTAssertEqual(index.files.count, 5)
        XCTAssertFalse(index.hasMore)
    }
}
