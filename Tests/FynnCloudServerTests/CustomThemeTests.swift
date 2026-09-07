import Fluent
import FluentSQLiteDriver
import Vapor
import VaporTesting
import XCTest

@testable import FynnCloudServer

final class CustomThemeTests: XCTestCase {

    override func tearDown() {
        unsetenv("PRIMARY_COLOR")
        super.tearDown()
    }

    func testAppConfigCustomPrimaryColor() async throws {
        let app = try await Application.make(.testing)
        defer {
            Task { try? await app.asyncShutdown() }
        }

        app.databases.use(.sqlite(.memory), as: .sqlite)
        try await TestRedis.configure(app)
        app.settings = SettingsService(database: app.db, redis: app.redis, logger: app.logger)
        setenv("PRIMARY_COLOR", "#8C5CF6", 1)
        let resolved = try await app.settings.get(AppSettings.PrimaryColor.self)
        XCTAssertEqual(resolved, "#8C5CF6")
    }

    func testMetaControllerPrimaryColorValidation() async throws {
        let app = try await Application.make(.testing)
        defer {
            Task { try? await app.asyncShutdown() }
        }

        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateAppSettings())
        try await app.autoMigrate()

        try await TestRedis.configure(app)

        app.settings = SettingsService(database: app.db, redis: app.redis, logger: app.logger)
        app.config = try ServerConfig.load(for: app)
        try app.register(collection: MetaController())

        try await app.testing().test(.GET, "api/info") { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertTrue(res.body.string.contains("primaryColor"))
        }
    }
}
