import Fluent
import FluentSQLiteDriver
import Vapor
import VaporTesting
import XCTest

@testable import FynnCloudServer

final class SettingsServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        unsetenv("APP_NAME")
        unsetenv("PRIMARY_COLOR")
    }

    override func tearDown() {
        unsetenv("APP_NAME")
        unsetenv("PRIMARY_COLOR")
        super.tearDown()
    }

    private func makeTestApp() async throws -> Application {
        let app = try await Application.make(.testing)
        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateAppSettings())
        try await app.autoMigrate()
        return app
    }

    func testCacheAndPersistence() async throws {
        let app = try await makeTestApp()
        defer {
            Task { try? await app.asyncShutdown() }
        }

        let service = SettingsService(database: app.db, redis: try await TestRedis.configure(app), ttl: 60.0, logger: app.logger)

        let initial = try await service.get(AppSettings.AppName.self)
        XCTAssertEqual(initial, "FynnCloud")

        try await service.setGuarded(AppSettings.AppName.self, value: "CustomCloud")
        let updated = try await service.get(AppSettings.AppName.self)
        XCTAssertEqual(updated, "CustomCloud")

        // Modify database record directly to verify in-memory cache hit
        let record = try await AppSetting.find(AppSettings.AppName.key, on: app.db)!
        record.value = "DirectDBValue"
        try await record.save(on: app.db)

        let cached = try await service.get(AppSettings.AppName.self)
        XCTAssertEqual(cached, "CustomCloud")

        await service.clearCache()
        let reloaded = try await service.get(AppSettings.AppName.self)
        XCTAssertEqual(reloaded, "DirectDBValue")
    }

    func testTTLExpiration() async throws {
        let app = try await makeTestApp()
        defer {
            Task { try? await app.asyncShutdown() }
        }

        let service = SettingsService(database: app.db, redis: try await TestRedis.configure(app), ttl: 0.1, logger: app.logger)

        try await service.setGuarded(AppSettings.AppName.self, value: "InitialVal")
        let cached = try await service.get(AppSettings.AppName.self)
        XCTAssertEqual(cached, "InitialVal")

        let record = try await AppSetting.find(AppSettings.AppName.key, on: app.db)!
        record.value = "NewDBValAfterTTL"
        try await record.save(on: app.db)

        let stillCached = try await service.get(AppSettings.AppName.self)
        XCTAssertEqual(stillCached, "InitialVal")

        try await Task.sleep(nanoseconds: 150_000_000)

        let expiredReload = try await service.get(AppSettings.AppName.self)
        XCTAssertEqual(expiredReload, "NewDBValAfterTTL")
    }

    func testConcurrentLoadCoalescing() async throws {
        let app = try await makeTestApp()
        defer {
            Task { try? await app.asyncShutdown() }
        }

        let service = SettingsService(database: app.db, redis: try await TestRedis.configure(app), ttl: 60.0, logger: app.logger)

        try await service.setGuarded(AppSettings.AppName.self, value: "CoalesceCloud")
        await service.clearCache()

        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await service.get(AppSettings.AppName.self)
                }
            }

            for try await result in group {
                XCTAssertEqual(result, "CoalesceCloud")
            }
        }
    }

    func testWriteDoesNotExtendCacheTTL() async throws {
        let app = try await makeTestApp()
        defer {
            Task { try? await app.asyncShutdown() }
        }

        let service = SettingsService(database: app.db, redis: try await TestRedis.configure(app), ttl: 0.3, logger: app.logger)

        try await service.setGuarded(AppSettings.AppName.self, value: "Initial")

        // Another replica changes a setting and its invalidation message is lost; the TTL is the
        // only backstop left.
        let record = try await AppSetting.find(AppSettings.AppName.key, on: app.db)!
        record.value = "FromOtherReplica"
        try await record.save(on: app.db)

        // Steady local write traffic on an unrelated key must not keep deferring that backstop.
        for _ in 0..<5 {
            try await Task.sleep(nanoseconds: 120_000_000)
            try await service.setGuarded(AppSettings.PrimaryColor.self, value: "#123456")
        }

        let observed = try await service.get(AppSettings.AppName.self)
        XCTAssertEqual(observed, "FromOtherReplica")
    }
}
