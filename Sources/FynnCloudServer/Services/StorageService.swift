import Vapor

struct StorageService: Sendable {
    /// Objects are fanned out into 256 buckets by the first two characters of their UUID so no
    /// single directory ends up with every file in it.
    private static let shardPrefixLength = 2

    /// How long an abandoned multipart chunk directory may linger before the sweeper removes it.
    static let orphanedChunkRetention: TimeInterval = 48 * 60 * 60

    let provider: any FileStorageProvider
    let eventLoop: any EventLoop

    init(provider: any FileStorageProvider, eventLoop: any EventLoop) {
        self.provider = provider
        self.eventLoop = eventLoop
    }

    // MARK: - Key Helpers

    private func shard(_ id: UUID) -> String {
        String(id.uuidString.prefix(Self.shardPrefixLength))
    }

    func fileKey(id: UUID, userID: UUID) -> String {
        "\(userID.uuidString)/\(shard(id))/\(id.uuidString)"
    }

    func avatarKey(userID: UUID) -> String {
        "\(userID.uuidString)/_system/avatar.jpg"
    }

    func thumbnailKey(fileID: UUID, userID: UUID) -> String {
        "\(userID.uuidString)/_system/thumbnails/\(shard(fileID))/\(fileID.uuidString)"
    }

    // MARK: - Core Storage Operations

    func save(
        stream: Request.Body,
        id: UUID,
        userID: UUID,
        maxSize: Int64
    ) async throws -> StorageSaveResult {
        try await provider.save(
            stream: stream,
            key: fileKey(id: id, userID: userID),
            maxSize: maxSize,
            on: eventLoop
        )
    }

    func getFileResponse(for id: UUID, userID: UUID, range: HTTPHeaders.Range? = nil) async throws -> Response {
        try await provider.getResponse(key: fileKey(id: id, userID: userID), range: range, on: eventLoop)
    }

    /// Overwrites a stored file from an in-memory buffer (used by the native editor save callback).
    func saveFileBuffer(id: UUID, userID: UUID, buffer: ByteBuffer, contentType: String) async throws {
        try await provider.save(buffer: buffer, key: fileKey(id: id, userID: userID), contentType: contentType)
    }

    /// Streams the stored file directly to a local path without buffering it in memory.
    func downloadToFile(for id: UUID, userID: UUID, path: String) async throws {
        try await provider.downloadToFile(key: fileKey(id: id, userID: userID), path: path, on: eventLoop)
    }

    func delete(id: UUID, userID: UUID) async throws {
        try await provider.delete(key: fileKey(id: id, userID: userID))
    }

    func exists(id: UUID, userID: UUID) async throws -> Bool {
        try await provider.exists(key: fileKey(id: id, userID: userID))
    }

    func copy(sourceID: UUID, destID: UUID, sourceUserID: UUID, destUserID: UUID) async throws {
        try await provider.copy(
            sourceKey: fileKey(id: sourceID, userID: sourceUserID),
            destinationKey: fileKey(id: destID, userID: destUserID)
        )
    }

    func copy(sourceID: UUID, destID: UUID, userID: UUID) async throws {
        try await copy(sourceID: sourceID, destID: destID, sourceUserID: userID, destUserID: userID)
    }

    // MARK: - Multipart Upload Operations

    func initiateMultipartUpload(id: UUID, userID: UUID) async throws -> String {
        try await provider.initiateMultipartUpload(key: fileKey(id: id, userID: userID))
    }

    func uploadPart(
        id: UUID,
        userID: UUID,
        uploadID: String,
        partNumber: Int,
        stream: Request.Body,
        maxSize: Int64
    ) async throws -> CompletedPart {
        try await provider.uploadPart(
            key: fileKey(id: id, userID: userID),
            uploadID: uploadID,
            partNumber: partNumber,
            stream: stream,
            maxSize: maxSize,
            on: eventLoop
        )
    }

    func completeMultipartUpload(
        id: UUID,
        userID: UUID,
        uploadID: String,
        parts: [CompletedPart]
    ) async throws -> MultipartCompletionResult {
        try await provider.completeMultipartUpload(
            key: fileKey(id: id, userID: userID),
            uploadID: uploadID,
            parts: parts
        )
    }

    func abortMultipartUpload(id: UUID, userID: UUID, uploadID: String) async throws {
        try await provider.abortMultipartUpload(key: fileKey(id: id, userID: userID), uploadID: uploadID)
    }

    func cleanupOrphanedChunkDirectories(
        olderThan: TimeInterval = StorageService.orphanedChunkRetention
    ) async {
        await provider.cleanupOrphanedChunkDirectories(olderThan: olderThan)
    }

    // MARK: - Thumbnail Operations

    func storeThumbnail(fileID: UUID, userID: UUID, buffer: ByteBuffer) async throws {
        try await provider.save(buffer: buffer, key: thumbnailKey(fileID: fileID, userID: userID), contentType: "image/jpeg")
    }

    func thumbnailResponse(fileID: UUID, userID: UUID) async throws -> Response {
        try await provider.getResponse(
            key: thumbnailKey(fileID: fileID, userID: userID), range: nil, on: eventLoop)
    }

    func deleteThumbnail(fileID: UUID, userID: UUID) async throws {
        try await provider.delete(key: thumbnailKey(fileID: fileID, userID: userID))
    }

    // MARK: - Avatar Operations

    func storeAvatar(userID: UUID, buffer: ByteBuffer) async throws {
        try await provider.save(buffer: buffer, key: avatarKey(userID: userID), contentType: "image/jpeg")
    }

    func avatarResponse(userID: UUID) async throws -> Response {
        try await provider.getResponse(key: avatarKey(userID: userID), range: nil, on: eventLoop)
    }

    func deleteAvatar(userID: UUID) async throws {
        try await provider.delete(key: avatarKey(userID: userID))
    }

    func avatarExists(userID: UUID) async throws -> Bool {
        try await provider.exists(key: avatarKey(userID: userID))
    }

    // MARK: - Branding Operations

    /// Named rather than keyed, so no caller can hand `StorageService` an arbitrary storage key.
    enum BrandingAsset: Sendable {
        case logo
        case icon

        fileprivate var key: String {
            switch self {
            case .logo: return "_system/branding/logo"
            case .icon: return "_system/branding/icon"
            }
        }
    }

    func storeBrandingAsset(
        _ asset: BrandingAsset, buffer: ByteBuffer, contentType: String
    ) async throws {
        try await provider.save(buffer: buffer, key: asset.key, contentType: contentType)
    }

    func brandingAssetResponse(_ asset: BrandingAsset) async throws -> Response {
        try await provider.getResponse(key: asset.key, range: nil, on: eventLoop)
    }

    func deleteBrandingAsset(_ asset: BrandingAsset) async throws {
        try await provider.delete(key: asset.key)
    }

    func brandingAssetExists(_ asset: BrandingAsset) async throws -> Bool {
        try await provider.exists(key: asset.key)
    }

    // MARK: - User Data Cleanup

    func deleteUserData(userID: UUID) async throws {
        try await provider.deleteUserData(userID: userID)
    }
}
