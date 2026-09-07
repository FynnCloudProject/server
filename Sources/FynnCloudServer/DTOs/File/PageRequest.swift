import Foundation

/// A validated page window. Clamping happens here rather than at the controller because the
/// listing and search services are also reachable from WebDAV and background jobs, and an
/// unchecked `limit` traps `Range.init` (`0..<-5`) instead of returning a 400.
///
/// `limit == nil` means "return the whole listing" - the web client's "select all" depends on
/// that contract.
struct PageRequest: Sendable, Equatable {
    static let maxLimit = 100

    let page: Int
    let limit: Int?

    init(page: Int? = nil, limit: Int? = nil) {
        self.page = max(1, page ?? 1)
        self.limit = limit.map { min(max($0, 1), Self.maxLimit) }
    }

    /// Zero for an unlimited request: there is nothing to skip when the whole set is returned.
    var offset: Int { (page - 1) * (limit ?? 0) }

    /// The whole listing in one response.
    static let unlimited = PageRequest()
}
