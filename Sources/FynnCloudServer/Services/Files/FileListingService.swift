import Fluent
import FluentSQL
import SQLKit
import Vapor

/// The read side of the file tree: every listing view, its breadcrumbs, and the per-viewer DTOs
/// those views (and the single-item endpoints) are rendered into.
struct FileListingService: Sendable {
    let context: FileServiceContext

    init(_ context: FileServiceContext) { self.context = context }

    private var db: any Database { context.db }
    private var logger: Logger { context.logger }
    private var syncLogService: SyncLogService { context.syncLog }
    private var accessService: FileAccessService { FileAccessService(context) }

    enum FileFilter: Equatable {
        case folder(id: UUID?)
        case all
        case favorites
        case recent
        case trash(parentID: UUID?)
        case shared
        case sharedWithOthers
    }

    /// The sort keys the listing engine understands, and the single mapping from each to the SQL
    /// expression that orders by it. Anything else falls back to the view's default order instead
    /// of being silently reinterpreted as a filename sort.
    ///
    /// `COALESCE` guards the nullable timestamp columns so rows never bubble to the top of a
    /// descending sort just because the column is NULL.
    enum SortKey: String, CaseIterable, Sendable {
        case name, size, lastModified, updatedAt, createdAt, uploadedAt, deletedAt

        /// `qualifier` prefixes the column names for queries that alias `file_metadata` (e.g. `f.`).
        func sqlExpression(qualifier: String = "") -> String {
            func column(_ name: String) -> String {
                qualifier.isEmpty ? "\"\(name)\"" : "\(qualifier)\(name)"
            }
            switch self {
            case .name: return "LOWER(\(column("filename")))"
            case .size: return column("size")
            case .lastModified:
                return "COALESCE(\(column("last_modified")), \(column("updated_at")), \(column("created_at")))"
            case .updatedAt: return "COALESCE(\(column("updated_at")), \(column("created_at")))"
            case .createdAt:
                return "COALESCE(\(column("created_at")), \(column("uploaded_at")), \(column("updated_at")))"
            case .uploadedAt: return "COALESCE(\(column("uploaded_at")), \(column("created_at")))"
            case .deletedAt: return column("deleted_at")
            }
        }
    }

    // MARK: - Retrieval Logic

    /// What a view contributes to a listing, before sorting and pagination.
    private struct ListingScope {
        var query: QueryBuilder<FileMetadata>
        var parentID: UUID? = nil
        var breadcrumbs: [Breadcrumb] = []
        var defaultPermissions: FilePermissionsDTO = .owner()
        var roleByFileID: [UUID: InternalShareRole] = [:]
    }

    /// Most views narrow a query; empty share/favourite lists and the trash root answer directly.
    private enum ListingPlan {
        case query(ListingScope)
        case ready(FileIndexDTO)
    }

    /// The unified engine for all file listing views (Root, Subfolders, Favorites, etc.)
    /// `window.limit == nil` returns all results.
    /// Pass `sortBy` and `sortDirection` to override the default sort order.
    func list(
        filter: FileFilter,
        userID: UUID,
        window: PageRequest = .unlimited,
        sortBy: String? = nil,
        sortDirection: DatabaseQuery.Sort.Direction? = nil
    ) async throws -> FileIndexDTO {
        let sortBy = sortBy.flatMap(SortKey.init(rawValue:))

        let scope: ListingScope
        switch try await plan(
            filter: filter, userID: userID, window: window,
            sortBy: sortBy, sortDirection: sortDirection)
        {
        case .ready(let dto): return dto
        case .query(let planned): scope = planned
        }

        let totalCount = window.limit != nil ? try await scope.query.count() : 0
        applyCustomSort(to: scope.query, sortBy: sortBy, sortDirection: sortDirection)

        return try await buildIndex(
            scope: scope, filter: filter, userID: userID,
            window: window, totalCount: totalCount)
    }

    private func plan(
        filter: FileFilter,
        userID: UUID,
        window: PageRequest,
        sortBy: SortKey?,
        sortDirection: DatabaseQuery.Sort.Direction?
    ) async throws -> ListingPlan {
        let query = FileMetadata.query(on: db)
        let useDefaultSort = sortBy == nil

        switch filter {
        case .all:
            query.filter(\.$owner.$id == userID).filter(\.$deletedAt == nil)
            if useDefaultSort { query.sort(\.$updatedAt, .descending) }
            return .query(ListingScope(query: query, breadcrumbs: [Breadcrumb.allFiles]))

        case .folder(let id):
            var scope = ListingScope(query: query, parentID: id)
            if let id = id {
                let access = try await accessService.validateAccess(fileID: id, userID: userID, required: .read)
                scope.defaultPermissions = FilePermissionsDTO(
                    permissions: access.permissions, isOwner: access.isOwner)
                if !access.isOwner {
                    query.with(\.$owner)
                }
                query.filter(\.$parent.$id == id).filter(\.$deletedAt == nil)
            } else {
                query.filter(\.$owner.$id == userID).filter(\.$parent.$id == nil).filter(\.$deletedAt == nil)
            }
            if useDefaultSort { query.sort(\.$isDirectory, .descending).sort(\.$filename, .ascending) }
            scope.breadcrumbs = try await getBreadcrumbs(for: id, userID: userID)
            return .query(scope)

        case .favorites:
            return try await favoritesPlan(query: query, userID: userID, useDefaultSort: useDefaultSort)

        case .recent:
            query.filter(\.$owner.$id == userID).filter(\.$deletedAt == nil).filter(\.$isDirectory == false)
            if useDefaultSort { query.sort(\.$updatedAt, .descending) }
            return .query(ListingScope(query: query, breadcrumbs: [Breadcrumb.recent]))

        case .shared:
            return try await sharedPlan(query: query, userID: userID, useDefaultSort: useDefaultSort)

        case .sharedWithOthers:
            return try await sharedWithOthersPlan(query: query, userID: userID, useDefaultSort: useDefaultSort)

        case .trash(let folderID):
            return try await trashPlan(
                query: query, folderID: folderID, userID: userID, useDefaultSort: useDefaultSort,
                window: window, sortBy: sortBy, sortDirection: sortDirection)
        }
    }

    private func favoritesPlan(
        query: QueryBuilder<FileMetadata>, userID: UUID, useDefaultSort: Bool
    ) async throws -> ListingPlan {
        let breadcrumbs = [Breadcrumb.favorites]
        let empty = FileIndexDTO(
            files: [], parentID: nil, breadcrumbs: breadcrumbs, totalCount: 0, hasMore: false)

        query.with(\.$owner)
        let favoriteFileIDs = try await UserFavorite.query(on: db)
            .filter(\.$user.$id == userID)
            .all()
            .map { $0.$file.id }

        if favoriteFileIDs.isEmpty { return .ready(empty) }

        let candidateFiles = try await FileMetadata.query(on: db)
            .filter(\.$id ~~ favoriteFileIDs)
            .filter(\.$deletedAt == nil)
            .all()

        let roleByFileID = try await accessService.sharedRoles(for: candidateFiles, userID: userID)
        let accessibleFileIDs = candidateFiles.compactMap { file -> UUID? in
            guard let fileID = file.id else { return nil }
            return file.$owner.id == userID || roleByFileID[fileID] != nil ? fileID : nil
        }

        if accessibleFileIDs.isEmpty { return .ready(empty) }

        query.filter(\.$id ~~ accessibleFileIDs).filter(\.$deletedAt == nil)
        if useDefaultSort { query.sort(\.$updatedAt, .descending) }
        return .query(ListingScope(
            query: query, breadcrumbs: breadcrumbs, roleByFileID: roleByFileID))
    }

    private func sharedPlan(
        query: QueryBuilder<FileMetadata>, userID: UUID, useDefaultSort: Bool
    ) async throws -> ListingPlan {
        let breadcrumbs = [Breadcrumb.sharedWithMe]

        query.with(\.$owner)
        let shares = try await accessService.matchingShares(fileIDs: nil, userID: userID)

        var roleByFileID: [UUID: InternalShareRole] = [:]
        for share in shares {
            let fileID = share.$file.id
            roleByFileID[fileID] = Swift.max(roleByFileID[fileID] ?? share.role, share.role)
        }

        let sharedFileIDs = Array(roleByFileID.keys)
        if sharedFileIDs.isEmpty {
            return .ready(FileIndexDTO(
                files: [], parentID: nil, breadcrumbs: breadcrumbs, totalCount: 0, hasMore: false))
        }

        query.filter(\.$id ~~ sharedFileIDs).filter(\.$deletedAt == nil).filter(\.$owner.$id != userID)
        if useDefaultSort { query.sort(\.$updatedAt, .descending) }
        return .query(ListingScope(
            query: query, breadcrumbs: breadcrumbs, roleByFileID: roleByFileID))
    }

    private func sharedWithOthersPlan(
        query: QueryBuilder<FileMetadata>, userID: UUID, useDefaultSort: Bool
    ) async throws -> ListingPlan {
        let userInternalShares = try await InternalShare.query(on: db)
            .filter(\.$creator.$id == userID)
            .all()
        let userShareLinks = try await ShareLink.query(on: db)
            .filter(\.$creator.$id == userID)
            .all()
        let createdShareFileIDs = Array(
            Set(userInternalShares.map { $0.$file.id } + userShareLinks.map { $0.$file.id }))

        query.group(.or) { orGroup in
            orGroup.group(.and) { andGroup in
                andGroup.filter(\.$owner.$id == userID)
                andGroup.filter(\.$isShared == true)
            }
            if !createdShareFileIDs.isEmpty {
                orGroup.filter(\.$id ~~ createdShareFileIDs)
            }
        }.filter(\.$deletedAt == nil)

        if useDefaultSort { query.sort(\.$updatedAt, .descending) }
        return .query(ListingScope(query: query, breadcrumbs: [Breadcrumb.sharedWithOthers]))
    }

    /// The trash root lists one entry per trashed item rather than per row, so it paginates the
    /// resolved roots itself instead of going through the shared query path.
    private func trashPlan(
        query: QueryBuilder<FileMetadata>,
        folderID: UUID?,
        userID: UUID,
        useDefaultSort: Bool,
        window: PageRequest,
        sortBy: SortKey?,
        sortDirection: DatabaseQuery.Sort.Direction?
    ) async throws -> ListingPlan {
        if let folderID = folderID {
            guard
                let folder = try await FileMetadata.query(on: db)
                    .withDeleted()
                    .filter(\.$id == folderID)
                    .filter(\.$owner.$id == userID)
                    .first(),
                let folderTrashGroupID = folder.trashGroupID
            else {
                throw Abort(.notFound).localized(LocalizationKeys.Error.Http.Generic)
            }

            query.withDeleted()
                .filter(\.$owner.$id == userID)
                .filter(\.$parent.$id == folderID)
                .filter(\.$trashGroupID == folderTrashGroupID)
            if useDefaultSort { query.sort(\.$isDirectory, .descending).sort(\.$filename, .ascending) }
            return .query(ListingScope(
                query: query,
                parentID: folderID,
                breadcrumbs: try await getBreadcrumbs(for: folderID, userID: userID, isTrash: true)))
        }

        let trashRoots = try await fetchTrashRoots(
            userID: userID, sortBy: sortBy, sortDirection: sortDirection)
        let breadcrumbs = [Breadcrumb.trash]
        logger.debug("Queried trash roots", metadata: ["user_id": .string(userID.uuidString)])

        guard let limit = window.limit else {
            return .ready(FileIndexDTO(
                files: trashRoots.map { FileIndexItemDTO(from: $0, permissions: .owner()) },
                parentID: nil,
                breadcrumbs: breadcrumbs,
                totalCount: trashRoots.count,
                hasMore: false))
        }

        let offset = window.offset
        let pageOfRoots = Array(trashRoots.dropFirst(offset).prefix(limit))
        return .ready(FileIndexDTO(
            files: pageOfRoots.map { FileIndexItemDTO(from: $0, permissions: .owner()) },
            parentID: nil,
            breadcrumbs: breadcrumbs,
            totalCount: trashRoots.count,
            hasMore: offset + pageOfRoots.count < trashRoots.count))
    }

    private func applyCustomSort(
        to query: QueryBuilder<FileMetadata>,
        sortBy: SortKey?,
        sortDirection: DatabaseQuery.Sort.Direction?
    ) {
        guard let sortBy = sortBy else { return }
        let direction = Self.sqlDirection(sortDirection ?? .ascending)

        // Folders first, matching the default ordering of the folder views.
        query.sort(\.$isDirectory, .descending)
        query.sort(DatabaseQuery.Sort.custom(
            SQLRaw("\(sortBy.sqlExpression()) \(direction) NULLS LAST")))
        if sortBy != .name {
            query.sort(DatabaseQuery.Sort.custom(SQLRaw("LOWER(\"filename\") ASC")))
        }
    }

    private static func sqlDirection(_ direction: DatabaseQuery.Sort.Direction) -> String {
        if case .ascending = direction { return "ASC" }
        return "DESC"
    }

    private func buildIndex(
        scope: ListingScope,
        filter: FileFilter,
        userID: UUID,
        window: PageRequest,
        totalCount: Int
    ) async throws -> FileIndexDTO {
        let offset = window.offset
        if let limit = window.limit {
            scope.query.range(offset..<(offset + limit))
        }

        let files = try await scope.query.all()

        let fileIDs = files.compactMap { $0.id }
        let favorites = filter == .favorites
            ? Set(fileIDs)
            : try await favoriteIDs(among: fileIDs, userID: userID)

        logger.debug(
            "Queried files",
            metadata: [
                "user_id": .string(userID.uuidString),
                "parent_id": .string(scope.parentID?.uuidString ?? "root"),
            ]
        )

        return FileIndexDTO(
            files: files.map {
                itemDTO(for: $0, scope: scope, filter: filter, userID: userID, favorites: favorites)
            },
            parentID: scope.parentID,
            breadcrumbs: scope.breadcrumbs,
            totalCount: window.limit == nil ? files.count : totalCount,
            hasMore: window.limit == nil ? false : offset + files.count < totalCount
        )
    }

    private func itemDTO(
        for file: FileMetadata,
        scope: ListingScope,
        filter: FileFilter,
        userID: UUID,
        favorites: Set<UUID>
    ) -> FileIndexItemDTO {
        let isFav = file.id.map { favorites.contains($0) } ?? false

        let permissions: FilePermissionsDTO
        if let fileID = file.id, let role = scope.roleByFileID[fileID] {
            permissions = FilePermissionsDTO(permissions: role.permissions, isOwner: false)
        } else if file.$owner.id == userID {
            permissions = .owner()
        } else {
            permissions = scope.defaultPermissions
        }
        return FileIndexItemDTO(
            from: file, isFavorite: isFav, permissions: permissions,
            hidesParent: filter == .shared)
    }

    /// A single file rendered for one viewer: permissions, favourite state, and whether the parent
    /// folder is visible to them.
    func itemDTO(fileID: UUID, userID: UUID) async throws -> FileIndexItemDTO {
        let access = try await accessService.validateAccess(fileID: fileID, userID: userID, required: .read)
        let file = access.file
        try await file.$owner.load(on: db)

        let isFavorite = try await UserFavorite.exists(fileID: fileID, userID: userID, on: db)
        let permissions = FilePermissionsDTO(
            permissions: access.permissions, isOwner: access.isOwner)

        var hidesParent = false
        if !access.isOwner, let parentID = file.$parent.id {
            let parentAccess = try? await accessService.validateAccess(
                fileID: parentID, userID: userID, required: .read)
            hidesParent = parentAccess == nil
        }

        return FileIndexItemDTO(
            from: file, isFavorite: isFavorite, permissions: permissions, hidesParent: hidesParent)
    }

    /// Favourite state for a whole batch of files in one query.
    func favoriteIDs(among fileIDs: [UUID], userID: UUID) async throws -> Set<UUID> {
        try await UserFavorite.ids(among: fileIDs, userID: userID, on: db)
    }

    /// Sets, or with `isFavorite: nil` flips, the viewer's favourite marker for a file.
    func setFavorite(fileID: UUID, userID: UUID, isFavorite: Bool?) async throws -> FileIndexItemDTO {
        let access = try await accessService.validateAccess(fileID: fileID, userID: userID, required: .read)
        let file = access.file
        try await file.$owner.load(on: db)

        let existing = try await UserFavorite.query(on: db)
            .filter(\.$user.$id == userID)
            .filter(\.$file.$id == fileID)
            .first()
        let shouldBeFavorite = isFavorite ?? (existing == nil)

        if shouldBeFavorite, existing == nil {
            try await UserFavorite(userID: userID, fileID: fileID).save(on: db)
            await syncLogService.emitFavorite(on: db, userID: userID, file: file, isFavorite: true)
        } else if !shouldBeFavorite, let existing {
            try await existing.delete(on: db)
            await syncLogService.emitFavorite(on: db, userID: userID, file: file, isFavorite: false)
        }

        // The owner's own listings read the denormalised flag, so keep it in step.
        if access.isOwner, file.isFavorite != shouldBeFavorite {
            file.isFavorite = shouldBeFavorite
            try await file.save(on: db)
        }

        logger.info(
            "File favorite toggled",
            metadata: [
                "fileID": .string(fileID.uuidString),
                "userID": .string(userID.uuidString),
                "isFavorite": .string("\(shouldBeFavorite)"),
                "action": "toggle_favorite",
            ])

        return FileIndexItemDTO(
            from: file,
            isFavorite: shouldBeFavorite,
            permissions: FilePermissionsDTO(
                permissions: access.permissions, isOwner: access.isOwner))
    }

    /// Renders a batch of files for one viewer, resolving permissions and favourites with a fixed
    /// number of queries rather than one round trip per file.
    func itemDTOs(for files: [FileMetadata], userID: UUID) async throws -> [FileIndexItemDTO] {
        let fileIDs = files.compactMap { $0.id }
        guard !fileIDs.isEmpty else { return [] }

        let favorites = try await favoriteIDs(among: fileIDs, userID: userID)
        let roleByFileID = try await accessService.sharedRoles(for: files, userID: userID)

        let parentIDs = Array(Set(files.compactMap { file -> UUID? in
            file.$owner.id == userID ? nil : file.$parent.id
        }))
        let visibleParentIDs = try await accessService.visibleFileIDs(among: parentIDs, userID: userID)

        for file in files where file.$owner.value == nil {
            try await file.$owner.load(on: db)
        }

        return files.map { file in
            let fileID = file.id
            let isFavorite = fileID.map { favorites.contains($0) } ?? false
            let permissions: FilePermissionsDTO
            var hidesParent = false
            if file.$owner.id == userID {
                permissions = .owner()
            } else {
                // A file that reached this batch without a resolvable share is no longer readable.
                let role = fileID.flatMap { roleByFileID[$0] }
                permissions = FilePermissionsDTO(
                    permissions: role?.permissions ?? .none, isOwner: false)
                hidesParent = file.$parent.id.map { !visibleParentIDs.contains($0) } ?? false
            }
            return FileIndexItemDTO(
                from: file, isFavorite: isFavorite, permissions: permissions,
                hidesParent: hidesParent)
        }
    }

    private func getBreadcrumbs(
        for folderID: UUID?,
        userID: UUID,
        isTrash: Bool = false
    ) async throws -> [Breadcrumb] {
        let rootCrumb = isTrash ? Breadcrumb.trash : Breadcrumb.allFiles

        guard let folderID = folderID else {
            return [rootCrumb]
        }

        let folderQuery = FileMetadata.query(on: db)
            .filter(\.$id == folderID)
        if isTrash {
            folderQuery.filter(\.$owner.$id == userID).withDeleted()
        }

        guard let folder = try await folderQuery.first() else {
            return [rootCrumb]
        }

        let isSharedRoot = folder.$owner.id != userID
        let effectiveRootCrumb = isTrash ? rootCrumb : (isSharedRoot ? Breadcrumb.sharedWithMe : rootCrumb)

        let fullAncestryIDs = folder.ancestorIDs + [folderID]
        var visibleAncestryIDs = fullAncestryIDs

        if isSharedRoot {
            let shares = try await accessService.matchingShares(fileIDs: fullAncestryIDs, userID: userID)
            let sharedIDs = Set(shares.map { $0.$file.id })
            if let firstSharedIndex = fullAncestryIDs.firstIndex(where: { sharedIDs.contains($0) }) {
                visibleAncestryIDs = Array(fullAncestryIDs.suffix(from: firstSharedIndex))
            }
        }

        let ancestorQuery = FileMetadata.query(on: db)
            .filter(\.$id ~~ visibleAncestryIDs)
        if isTrash {
            ancestorQuery.filter(\.$owner.$id == userID).withDeleted()
        }

        let ancestorFiles = try await ancestorQuery.all()
        let fileMap = Dictionary(uniqueKeysWithValues: ancestorFiles.compactMap { f -> (UUID, FileMetadata)? in
            guard let id = f.id else { return nil }
            return (id, f)
        })

        var pathCrumbs: [Breadcrumb] = []
        for id in visibleAncestryIDs {
            guard let file = fileMap[id] else { continue }
            if isTrash && file.deletedAt == nil {
                continue
            }
            let crumbPath = isTrash ? "/trash/\(id.uuidString)" : "/files/\(id.uuidString)"
            pathCrumbs.append(Breadcrumb(name: file.filename, id: file.id, path: crumbPath))
        }

        return [effectiveRootCrumb] + pathCrumbs
    }

    private func fetchTrashRoots(
        userID: UUID,
        sortBy: SortKey? = nil,
        sortDirection: DatabaseQuery.Sort.Direction? = nil
    ) async throws -> [FileMetadata] {
        let sql = try context.requireSQL()

        let orderByClause: String
        if let sortBy {
            let direction = Self.sqlDirection(sortDirection ?? .descending)
            orderByClause =
                "ORDER BY f.is_directory DESC, \(sortBy.sqlExpression(qualifier: "f.")) \(direction) NULLS LAST, LOWER(f.filename) ASC"
        } else {
            orderByClause = "ORDER BY f.is_directory DESC, f.deleted_at DESC, LOWER(f.filename) ASC"
        }

        return try await sql.raw(
            """
            SELECT f.* FROM file_metadata f
            LEFT JOIN file_metadata p ON f.parent_id = p.id
            WHERE f.owner_id = \(bind: userID)
            AND f.deleted_at IS NOT NULL
            AND (
                f.parent_id IS NULL
                OR p.deleted_at IS NULL
                OR f.trash_group_id != p.trash_group_id
            )
            \(unsafeRaw: orderByClause)
            """
        ).all(decodingFluent: FileMetadata.self)
    }
}
