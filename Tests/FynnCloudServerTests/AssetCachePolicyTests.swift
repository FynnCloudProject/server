import Vapor
import XCTest

@testable import FynnCloudServer

/// Moving cache policy out of `StorageService` must not change a single byte of what clients see.
final class AssetCachePolicyTests: XCTestCase {
    func testDerivedAssetHeaders() {
        let response = Response(status: .ok)
        response.apply(.derived, contentType: "image/jpeg")

        XCTAssertEqual(response.headers.first(name: .contentType), "image/jpeg")
        XCTAssertEqual(response.headers.first(name: .cacheControl), "public, max-age=86400")
    }

    func testVersionedImmutableAssetHeaders() {
        let response = Response(status: .ok)
        response.apply(.versionedImmutable, contentType: "image/svg+xml")

        XCTAssertEqual(response.headers.first(name: .contentType), "image/svg+xml")
        XCTAssertEqual(
            response.headers.first(name: .cacheControl), "public, max-age=31536000, immutable")
    }

    func testPolicyReplacesAnyHeaderTheProviderAlreadySet() {
        let response = Response(status: .ok)
        response.headers.replaceOrAdd(name: .contentType, value: "application/octet-stream")
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")

        response.apply(.derived, contentType: "image/jpeg")

        XCTAssertEqual(response.headers[.contentType].count, 1)
        XCTAssertEqual(response.headers[.cacheControl], ["public, max-age=86400"])
    }
}
