import XCTest
import Vapor
import VaporTesting
@testable import FynnCloudServer

final class RateLimitTests: XCTestCase {

    func testRateLimitMiddlewareHeadersAndThrottling() async throws {
        let app = try await Application.make(.testing)
        defer {
            Task { try? await app.asyncShutdown() }
        }

        setenv("RATE_LIMIT_ENABLED", "true", 1)
        setenv("RATE_LIMIT_AUTH", "2", 1)
        app.config = try ServerConfig.load(for: app)
        try await TestRedis.configure(app)

        let authGroup = app.grouped("api", "auth").grouped(RateLimitMiddleware(category: .auth))
        authGroup.post("test-login") { _ -> String in
            return "OK"
        }

        try await app.testing().test(.POST, "api/auth/test-login") { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.headers.first(name: "X-RateLimit-Limit"), "2")
            XCTAssertEqual(res.headers.first(name: "X-RateLimit-Remaining"), "1")
            XCTAssertNotNil(res.headers.first(name: "X-RateLimit-Reset"))
        }

        try await app.testing().test(.POST, "api/auth/test-login") { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.headers.first(name: "X-RateLimit-Limit"), "2")
            XCTAssertEqual(res.headers.first(name: "X-RateLimit-Remaining"), "0")
        }

        try await app.testing().test(.POST, "api/auth/test-login") { res async in
            XCTAssertEqual(res.status, .tooManyRequests)
            XCTAssertEqual(res.headers.first(name: "X-RateLimit-Limit"), "2")
            XCTAssertEqual(res.headers.first(name: "X-RateLimit-Remaining"), "0")
            XCTAssertNotNil(res.headers.first(name: "Retry-After"))
        }
    }

    override func tearDown() {
        unsetenv("RATE_LIMIT_ENABLED")
        unsetenv("RATE_LIMIT_AUTH")
        super.tearDown()
    }
}
