import Fluent
import FluentSQL
import SQLKit
import Vapor
@preconcurrency import Redis

/// The collaborators every service in the file subsystem needs. Passing one context around keeps
/// each service's initialiser from growing a parameter every time a dependency is added.
struct FileServiceContext: @unchecked Sendable {
    let db: any Database
    let logger: Logger
    let storage: StorageService
    let redis: any RedisClient
    let embedding: EmbeddingService?
    let semanticSearchThreshold: Double
    let syncLog: SyncLogService

    init(
        db: any Database,
        logger: Logger,
        storage: StorageService,
        redis: any RedisClient,
        embedding: EmbeddingService? = nil,
        semanticSearchThreshold: Double = 0.75,
        syncLog: SyncLogService = SyncLogService()
    ) {
        self.db = db
        self.logger = logger
        self.storage = storage
        self.redis = redis
        self.embedding = embedding
        self.semanticSearchThreshold = semanticSearchThreshold
        self.syncLog = syncLog
    }

    /// Recursive CTEs, array operators and atomic counter updates cannot be expressed in Fluent.
    /// Skipping them silently would corrupt quota and trash state, so an unsupported database is
    /// an error rather than a no-op.
    func requireSQL(_ database: (any Database)? = nil) throws -> any SQLDatabase {
        guard let sql = (database ?? db) as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "This operation requires a SQL database.")
                .localized(LocalizationKeys.Error.Http.Generic)
        }
        return sql
    }
}

/// The context is the composition root for the file subsystem: every service is derived from it,
/// so callers name the capability they need rather than reaching for one catch-all object.
extension FileServiceContext {
    var access: FileAccessService { FileAccessService(self) }
    var files: FileService { FileService(self) }
    var listing: FileListingService { FileListingService(self) }
    var search: FileSearchService { FileSearchService(self) }
    var uploads: MultipartUploadService { MultipartUploadService(self) }
    var quota: QuotaService { QuotaService(self) }
}

/// Limits and conversions shared by the single-request and multipart upload paths.
enum UploadRules {
    /// Lifetime of a multipart upload session and of the Redis quota lease that backs it.
    static let sessionTTL: TimeInterval = 24 * 60 * 60

    /// S3-compatible multipart uploads cap the number of parts per object.
    static let maxParts = 10_000

    /// Slack allowed between the size a client declares and the bytes actually stored, to absorb
    /// transfer-encoding overhead without failing the upload.
    static let sizeTolerance: Int64 = 1024 * 1024

    /// A streamed body can run slightly past its declared size; cut it off beyond this.
    static func maxAllowedSize(claiming claimedSize: Int64) -> Int64 {
        claimedSize + Swift.max(claimedSize / 20, sizeTolerance)
    }

    /// Client-supplied timestamps arrive as epoch milliseconds.
    static func date(fromEpochMilliseconds milliseconds: Int64?) -> Date? {
        milliseconds.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
    }
}

/// Filename collision rules, shared by every path that puts a new name into a folder.
enum FileNaming {
    /// Restoring gives up after this many collision-avoiding suffixes rather than looping forever.
    private static let maxDisambiguationAttempts = 100

    static func ensureUnique(
        name: String, parentID: UUID?, ownerID: UUID, on db: any Database
    ) async throws {
        let taken = try await FileMetadata.query(on: db)
            .filter(\.$owner.$id == ownerID)
            .filter(\.$parent.$id == parentID)
            .filter(\.$filename == name)
            .filter(\.$deletedAt == nil)
            .count() > 0

        if taken {
            throw Abort(
                .conflict,
                reason: "A file or folder with the name '\(name)' already exists in this directory."
            ).localized(LocalizationKeys.Error.Upload.NameConflict, params: ["name": name])
        }
    }

    /// A non-colliding variant of `name` inside `parentID`, used when restoring from trash where
    /// failing on a conflict would strand the item.
    static func available(
        basedOn name: String,
        isDirectory: Bool,
        parentID: UUID?,
        ownerID: UUID,
        excluding fileID: UUID,
        on db: any Database
    ) async throws -> String {
        var candidate = name
        for attempt in 0...maxDisambiguationAttempts {
            let taken = try await FileMetadata.query(on: db)
                .filter(\.$owner.$id == ownerID)
                .filter(\.$parent.$id == parentID)
                .filter(\.$filename == candidate)
                .filter(\.$id != fileID)
                .count() > 0
            if !taken { return candidate }

            let suffix = attempt == 0 ? " (restored)" : " (restored \(attempt + 1))"
            candidate = insertingSuffix(suffix, into: name, beforeExtension: !isDirectory)
        }
        throw Abort(.conflict, reason: "Could not find a free name for '\(name)'.")
            .localized(LocalizationKeys.Error.Files.RestoreFailed)
    }

    private static func insertingSuffix(
        _ suffix: String, into name: String, beforeExtension: Bool
    ) -> String {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard beforeExtension, parts.count > 1 else { return name + suffix }
        return parts.dropLast().joined(separator: ".") + suffix + "." + parts[parts.count - 1]
    }
}
