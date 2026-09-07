import Vapor

/// HTTP caching for the assets the server generates or stores on an admin's behalf. This is a
/// transport concern, so it lives with the response rather than in `StorageService`.
enum AssetCachePolicy: Sendable {
    /// Server-generated JPEGs keyed by a stable id (thumbnails, avatars).
    case derived

    /// Content whose URL is versioned by the caller. Only safe where every consumer cache-busts -
    /// branding assets are fetched with `?v=<updatedAt>`. A consumer that omits the query pins a
    /// stale asset for a year.
    case versionedImmutable

    fileprivate var cacheControlValue: String {
        switch self {
        case .derived: return "public, max-age=\(24 * 60 * 60)"
        case .versionedImmutable: return "public, max-age=31536000, immutable"
        }
    }
}

extension Response {
    func apply(_ policy: AssetCachePolicy, contentType: String?) {
        if let contentType {
            headers.replaceOrAdd(name: .contentType, value: contentType)
        }
        headers.replaceOrAdd(name: .cacheControl, value: policy.cacheControlValue)
    }
}
