import Fluent
import FluentSQL
import SQLKit
import Vapor

/// Answers "may this user do X to this file", and resolves share grants for whole batches.
struct FileAccessService: Sendable {
    let context: FileServiceContext

    init(_ context: FileServiceContext) { self.context = context }

    private var db: any Database { context.db }

    func exists(fileID: UUID) async throws -> Bool {
        try await FileMetadata.query(on: db)
            .withDeleted()
            .filter(\.$id == fileID)
            .count() > 0
    }

    /// Recursive and atomic statements below cannot be expressed in Fluent. Skipping them silently
    struct FileAccessContext: Sendable {
        let file: FileMetadata
        let isOwner: Bool
        let permissions: FilePermissions
        let ownerID: UUID

        var canRead: Bool { permissions.canRead }
        var canWrite: Bool { permissions.canWrite }
        var canDelete: Bool { permissions.canDelete }
        var canShare: Bool { permissions.canShare }
        var canManage: Bool { permissions.canManage }
    }

    func validateAccess(
        fileID: UUID,
        userID: UUID,
        required: FilePermissions = .read,
        on specificDB: (any Database)? = nil
    ) async throws -> FileAccessContext {
        let activeDB = specificDB ?? self.db
        guard
            let item = try await FileMetadata.query(on: activeDB)
                .withDeleted()
                .filter(\.$id == fileID)
                .first()
        else {
            throw Abort(.notFound).localized(LocalizationKeys.Error.Http.Generic)
        }

        let ownerID = item.$owner.id
        if ownerID == userID {
            return FileAccessContext(
                file: item,
                isOwner: true,
                permissions: .all,
                ownerID: userID
            )
        }

        if item.deletedAt != nil {
            throw Abort(.notFound).localized(LocalizationKeys.Error.Http.Generic)
        }

        let shares = try await matchingShares(
            fileIDs: [fileID] + item.ancestorIDs, userID: userID, on: activeDB)

        guard let highestRole = shares.map(\.role).max() else {
            throw Abort(.notFound).localized(LocalizationKeys.Error.Http.Generic)
        }

        guard highestRole.permissions.contains(required) else {
            throw Abort(.forbidden).localized(LocalizationKeys.Error.Http.Unauthorized)
        }

        return FileAccessContext(
            file: item,
            isOwner: false,
            permissions: highestRole.permissions,
            ownerID: ownerID
        )
    }

    @discardableResult
    func validateOwnership(fileID: UUID, userID: UUID, on specificDB: (any Database)? = nil)
        async throws -> FileMetadata
    {
        let access = try await validateAccess(fileID: fileID, userID: userID, required: .manage, on: specificDB)
        guard access.isOwner else {
            throw Abort(.forbidden).localized(LocalizationKeys.Error.Http.Unauthorized)
        }
        return access.file
    }
    /// Subset of `fileIDs` the user may read, resolved in one pass.
    func visibleFileIDs(among fileIDs: [UUID], userID: UUID) async throws -> Set<UUID> {
        guard !fileIDs.isEmpty else { return [] }
        let files = try await FileMetadata.query(on: db)
            .filter(\.$id ~~ fileIDs)
            .filter(\.$deletedAt == nil)
            .all()
        let roleByFileID = try await sharedRoles(for: files, userID: userID)
        return Set(files.compactMap { file -> UUID? in
            guard let fileID = file.id else { return nil }
            return file.$owner.id == userID || roleByFileID[fileID] != nil ? fileID : nil
        })
    }

    /// Highest share role each of `files` is reachable with, resolved for the whole set in one
    /// query. Files the caller owns are omitted; ownership is checked separately.
    func sharedRoles(
        for files: [FileMetadata], userID: UUID
    ) async throws -> [UUID: InternalShareRole] {
        var ancestryByFile: [UUID: [UUID]] = [:]
        var shareTargets = Set<UUID>()
        for file in files {
            guard let fileID = file.id, file.$owner.id != userID else { continue }
            let ancestry = [fileID] + file.ancestorIDs
            ancestryByFile[fileID] = ancestry
            shareTargets.formUnion(ancestry)
        }
        guard !shareTargets.isEmpty else { return [:] }

        let shares = try await matchingShares(fileIDs: Array(shareTargets), userID: userID)
        var roleByTarget: [UUID: InternalShareRole] = [:]
        for share in shares {
            let target = share.$file.id
            roleByTarget[target] = Swift.max(roleByTarget[target] ?? share.role, share.role)
        }

        return ancestryByFile.compactMapValues { ancestry in
            ancestry.compactMap { roleByTarget[$0] }.max()
        }
    }

    /// Shares granting `userID` access to any of `fileIDs`, directly or through one of their groups.
    /// Passing `nil` for `fileIDs` returns every share that reaches the user.
    func matchingShares(
        fileIDs: [UUID]?, userID: UUID, on specificDB: (any Database)? = nil
    ) async throws -> [InternalShare] {
        if let fileIDs, fileIDs.isEmpty { return [] }
        let activeDB = specificDB ?? self.db
        let groupIDs = try await UserService.getEffectiveGroupIDs(for: userID, on: activeDB)

        let query = InternalShare.query(on: activeDB)
        if let fileIDs { query.filter(\.$file.$id ~~ fileIDs) }
        return try await query
            .group(.or) { orGroup in
                orGroup.filter(\.$granteeUser.$id == userID)
                if !groupIDs.isEmpty {
                    orGroup.filter(\.$granteeGroup.$id ~~ groupIDs)
                }
            }
            .all()
    }
}
