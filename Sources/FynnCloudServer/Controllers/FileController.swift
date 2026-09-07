import Fluent
import Vapor

struct FileController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let api = routes.grouped("api", "files")
        let protected = api.grouped(UserPayloadAuthenticator(), UserPayload.guardMiddleware())

        protected.get(use: index)
        protected.get("recent", use: recent)
        protected.get("favorites", use: favorites)
        protected.get("shared", use: shared)
        protected.get("shared-with-others", use: sharedWithOthers)
        protected.get("trash", use: trash)
        protected.get("all", use: all)
        protected.get("search", use: search)
        protected.get(":fileID", use: show)

        protected.post("multipart", "initiate", use: initiateMultipartUpload)
        let jwtProtected = api.grouped(
            UploadSessionAuthenticator(), UploadSessionToken.guardMiddleware())
        jwtProtected.on(
            .PUT, "multipart", ":sessionID", "part", ":partNumber", body: .stream, use: uploadPart)
        jwtProtected.post("multipart", ":sessionID", "complete", use: completeMultipartUpload)
        jwtProtected.delete("multipart", ":sessionID", "abort", use: abortMultipartUpload)

        protected.post("create-directory", use: createDirectory)
        protected.post("create-file", use: createFile)

        protected.patch(":fileID", use: rename)
        protected.post(":fileID", "favorite", use: toggleFavorite)

        protected.get(":fileID", "download", use: download)
        protected.get(":fileID", "thumbnail", use: thumbnail)
        protected.get(":fileID", "activity", use: activity)

        // Everything that acts on a set of files takes an id array, a single file being `[id]`.
        protected.post("move", use: moveMany)
        protected.post("restore", use: restoreMany)
        protected.post("trash", use: trashMany)
        protected.post("permanent-delete", use: permanentDeleteMany)
    }

    /// Bulk endpoints take an id array; duplicates are collapsed so a file is never processed twice.
    private func uniqueIDs(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// Paging and ordering shared by every listing view.
    private struct ListingQuery {
        let window: PageRequest
        let sortBy: String?
        let sortDirection: DatabaseQuery.Sort.Direction?
    }

    /// Omitting `limit` deliberately returns the WHOLE listing in one response - the web client's
    /// "select all" depends on that.
    private func listingQuery(_ req: Request) -> ListingQuery {
        ListingQuery(
            window: PageRequest(
                page: try? req.query.get(Int.self, at: "page"),
                limit: try? req.query.get(Int.self, at: "limit")),
            sortBy: try? req.query.get(String.self, at: "sortBy"),
            sortDirection: parseSortDirection(try? req.query.get(String.self, at: "sortDirection"))
        )
    }

    private func parseSortDirection(_ raw: String?) -> DatabaseQuery.Sort.Direction? {
        switch raw {
        case "asc": return .ascending
        case "desc": return .descending
        default: return nil
        }
    }

    func index(req: Request) async throws -> FileIndexDTO {
        let userID = try req.auth.require(UserPayload.self).getID()
        let parentID = try? req.query.get(UUID.self, at: "parentID")
        let q = listingQuery(req)
        return try await req.fileListing.list(
            filter: .folder(id: parentID), userID: userID, window: q.window,
            sortBy: q.sortBy, sortDirection: q.sortDirection)
    }

    func all(req: Request) async throws -> FileIndexDTO {
        let userID = try req.auth.require(UserPayload.self).getID()
        let q = listingQuery(req)
        return try await req.fileListing.list(
            filter: .all, userID: userID, window: q.window,
            sortBy: q.sortBy, sortDirection: q.sortDirection)
    }

    func show(req: Request) async throws -> FileIndexItemDTO {
        let userID = try req.auth.require(UserPayload.self).getID()
        let fileID = try req.parameters.require("fileID", as: UUID.self)
        return try await req.fileListing.itemDTO(fileID: fileID, userID: userID)
    }

    func activity(req: Request) async throws -> ActivityResponse {
        let userID = try req.auth.require(UserPayload.self).getID()
        let fileID = try req.parameters.require("fileID", as: UUID.self)
        let params = try req.query.decode(ActivityRequest.self)

        return try await SyncController.fetchActivity(
            db: req.db,
            fileAccess: req.fileAccess,
            userID: userID,
            fileID: fileID,
            page: params.page ?? 1,
            limit: params.limit ?? 30
        )
    }

    func favorites(req: Request) async throws -> FileIndexDTO {
        let userID = try req.auth.require(UserPayload.self).getID()
        let q = listingQuery(req)
        return try await req.fileListing.list(
            filter: .favorites, userID: userID, window: q.window,
            sortBy: q.sortBy, sortDirection: q.sortDirection)
    }

    func trash(req: Request) async throws -> FileIndexDTO {
        let userID = try req.auth.require(UserPayload.self).getID()
        let parentID = try? req.query.get(UUID.self, at: "parentID")
        let q = listingQuery(req)
        return try await req.fileListing.list(
            filter: .trash(parentID: parentID), userID: userID, window: q.window,
            sortBy: q.sortBy, sortDirection: q.sortDirection)
    }

    func recent(req: Request) async throws -> FileIndexDTO {
        let userID = try req.auth.require(UserPayload.self).getID()
        let q = listingQuery(req)
        return try await req.fileListing.list(
            filter: .recent, userID: userID, window: q.window,
            sortBy: q.sortBy, sortDirection: q.sortDirection)
    }

    func shared(req: Request) async throws -> FileIndexDTO {
        let userID = try req.auth.require(UserPayload.self).getID()
        let q = listingQuery(req)
        return try await req.fileListing.list(
            filter: .shared, userID: userID, window: q.window,
            sortBy: q.sortBy, sortDirection: q.sortDirection)
    }

    func sharedWithOthers(req: Request) async throws -> FileIndexDTO {
        let userID = try req.auth.require(UserPayload.self).getID()
        let q = listingQuery(req)
        return try await req.fileListing.list(
            filter: .sharedWithOthers, userID: userID, window: q.window,
            sortBy: q.sortBy, sortDirection: q.sortDirection)
    }

    /// Results are relevance-ranked, so `sortBy`/`sortDirection` are not accepted here - clients
    /// present search results as unsortable.
    func search(req: Request) async throws -> FileIndexDTO {
        let userID = try req.auth.require(UserPayload.self).getID()
        let query = try req.query.get(String.self, at: "q")
        let mode = (try? req.query.get(String.self, at: "mode"))
            .flatMap(FileSearchService.SearchMode.init(rawValue:))

        let searchService = await req.fileSearchAsync()
        return try await searchService.search(
            query: query,
            userID: userID,
            window: listingQuery(req).window,
            mode: mode
        )
    }

    // The bulk handlers walk the ids one at a time: a folder and its own children can be in the
    // same batch, and restore resolves name collisions against the destination folder, so these
    // must not overlap. They always answer 200 - a batch has one outcome per id, not one status
    // code.

    /// Runs `action` for every distinct id, collecting per-id outcomes instead of failing the batch.
    private func runBulk<Result>(
        req: Request,
        ids: [UUID],
        action: String,
        treatMissingAsSuccess: Bool = false,
        perform: (UUID) async throws -> Result
    ) async -> (succeeded: [Result], missing: [UUID], failed: [UUID]) {
        var succeeded: [Result] = []
        var missing: [UUID] = []
        var failed: [UUID] = []

        for id in uniqueIDs(ids) {
            do {
                succeeded.append(try await perform(id))
            } catch {
                if treatMissingAsSuccess, await isAlreadyGone(req: req, id: id, error: error) {
                    missing.append(id)
                } else {
                    failed.append(id)
                    logBulkFailure(req: req, id: id, action: action, error: error)
                }
            }
        }

        return (succeeded, missing, failed)
    }

    func trashMany(req: Request) async throws -> BulkFileResultDTO {
        let userID = try req.auth.require(UserPayload.self).getID()
        let ids = try req.content.decode(FileIDsInput.self).ids

        let outcome = await runBulk(
            req: req, ids: ids, action: "move_to_trash", treatMissingAsSuccess: true
        ) { id in
            try await req.fileService.moveToTrash(fileID: id, userID: userID)
            return id
        }

        return BulkFileResultDTO(
            succeeded: outcome.succeeded + outcome.missing, failed: outcome.failed)
    }

    func permanentDeleteMany(req: Request) async throws -> BulkFileResultDTO {
        let userID = try req.auth.require(UserPayload.self).getID()
        let ids = try req.content.decode(FileIDsInput.self).ids

        let outcome = await runBulk(
            req: req, ids: ids, action: "permanent_delete", treatMissingAsSuccess: true
        ) { id in
            try await req.fileService.deleteRecursive(fileID: id, userID: userID)
            return id
        }

        return BulkFileResultDTO(
            succeeded: outcome.succeeded + outcome.missing, failed: outcome.failed)
    }

    /// Deleting is idempotent, so an id that no longer exists counts as done. A file that merely
    /// isn't visible to this user also raises 404, and that one has to stay a failure.
    private func isAlreadyGone(req: Request, id: UUID, error: any Error) async -> Bool {
        guard let abort = error as? any AbortError, abort.status == .notFound else { return false }
        guard let stillExists = try? await req.fileAccess.exists(fileID: id) else { return false }
        return !stillExists
    }

    private func logBulkFailure(req: Request, id: UUID, action: String, error: any Error) {
        req.logger.warning(
            "Bulk file operation failed",
            metadata: [
                "fileID": .string(id.uuidString),
                "action": .string(action),
                "error": .string(String(describing: error)),
            ])
    }

    /// Embeddings power semantic search; a failure to enqueue must not fail the write itself.
    private func dispatchEmbeddingJob(req: Request, fileID: UUID) async {
        let isEnabled =
            (try? await req.application.settings.get(AppSettings.EmbeddingEnabled.self)) ?? true
        guard isEnabled else { return }

        do {
            try await req.queue.dispatch(
                ProcessFileEmbeddingJob.self, FileEmbeddingPayload(fileID: fileID))
        } catch {
            req.logger(subsystem: .embedding).error(
                "Failed to dispatch embedding job",
                metadata: [
                    "file_id": .stringConvertible(fileID),
                    "error": .string("\(error)"),
                ]
            )
        }
    }

    func createDirectory(req: Request) async throws -> FileIndexItemDTO {
        let userID = try req.auth.require(UserPayload.self).getID()
        let data = try req.content.decode(CreateDirData.self)

        let metadata = try await req.fileService.createDirectory(
            name: data.name, parentID: data.parentID, userID: userID)

        req.logger.info(
            "Directory created",
            metadata: [
                "fileID": .string(metadata.id?.uuidString ?? ""),
                "userID": .string(userID.uuidString),
                "name": .string(data.name),
                "action": "create_directory",
            ])

        if let fileID = metadata.id {
            await dispatchEmbeddingJob(req: req, fileID: fileID)
        }

        return try await req.fileListing.itemDTOs(for: [metadata], userID: userID)[0]
    }

    func createFile(req: Request) async throws -> FileIndexItemDTO {
        let userID = try req.auth.require(UserPayload.self).getID()
        let data = try req.content.decode(CreateFileData.self)

        let metadata = try await req.fileService.createFile(
            name: data.name, type: data.type, parentID: data.parentID, userID: userID)

        req.logger.info(
            "File created",
            metadata: [
                "fileID": .string(metadata.id?.uuidString ?? ""),
                "userID": .string(userID.uuidString),
                "name": .string(data.name),
                "type": .string(data.type.rawValue),
                "action": "create_file",
            ])

        if let fileID = metadata.id {
            await dispatchEmbeddingJob(req: req, fileID: fileID)
        }

        return try await req.fileListing.itemDTOs(for: [metadata], userID: userID)[0]
    }

    func moveMany(req: Request) async throws -> BulkFileItemsResultDTO {
        let userID = try req.auth.require(UserPayload.self).getID()
        let input = try req.content.decode(MoveFilesInput.self)

        let outcome = await runBulk(req: req, ids: input.ids, action: "move_file") { id in
            try await req.fileService.move(
                fileID: id, newParentID: input.parentID, userID: userID)
        }

        return BulkFileItemsResultDTO(
            succeeded: try await req.fileListing.itemDTOs(for: outcome.succeeded, userID: userID),
            failed: outcome.failed)
    }

    func rename(req: Request) async throws -> FileIndexItemDTO {
        let userID = try req.auth.require(UserPayload.self).getID()
        let fileID = try req.parameters.require("fileID", as: UUID.self)

        let input = try req.content.decode(RenameInput.self)

        let metadata = try await req.fileService.rename(
            fileID: fileID,
            newName: input.name,
            userID: userID
        )

        req.logger.info(
            "File renamed",
            metadata: [
                "fileID": .string(fileID.uuidString),
                "userID": .string(userID.uuidString),
                "newName": .string(input.name),
                "action": "rename_file",
            ])

        GenerateThumbnailJob.dispatchIfNeeded(for: metadata, req: req)

        return try await req.fileListing.itemDTOs(for: [metadata], userID: userID)[0]
    }

    func download(req: Request) async throws -> Response {
        let userID = try req.auth.require(UserPayload.self).getID()
        let fileID = try req.parameters.require("fileID", as: UUID.self)
        let isInline =
            req.query[String.self, at: "inline"] == "true"
            || req.query[String.self, at: "disposition"] == "inline"
        return try await req.fileService.getDownloadResponse(
            fileID: fileID,
            userID: userID,
            range: req.headers.range,
            ifNoneMatch: req.headers.first(name: .ifNoneMatch),
            isInline: isInline
        )
    }

    func thumbnail(req: Request) async throws -> Response {
        let userID = try req.auth.require(UserPayload.self).getID()
        let fileID = try req.parameters.require("fileID", as: UUID.self)

        switch try await req.fileService.getThumbnail(fileID: fileID, userID: userID) {
        case .available(let response):
            response.apply(.derived, contentType: "image/jpeg")
            return response
        case .needsGeneration(let file):
            GenerateThumbnailJob.dispatchIfNeeded(for: file, req: req)
            throw Abort(.notFound, reason: "No thumbnail available")
        }
    }

    func restoreMany(req: Request) async throws -> BulkFileItemsResultDTO {
        let userID = try req.auth.require(UserPayload.self).getID()
        let ids = try req.content.decode(FileIDsInput.self).ids

        let outcome = await runBulk(req: req, ids: ids, action: "restore_file") { id in
            try await req.fileService.restore(fileID: id, userID: userID)
        }

        return BulkFileItemsResultDTO(
            succeeded: try await req.fileListing.itemDTOs(for: outcome.succeeded, userID: userID),
            failed: outcome.failed)
    }

    func toggleFavorite(req: Request) async throws -> FileIndexItemDTO {
        let userID = try req.auth.require(UserPayload.self).getID()
        let fileID = try req.parameters.require("fileID", as: UUID.self)

        // Absent in both body and query means "flip whatever it is now".
        let desired =
            (try? req.content.decode(ToggleFavoriteInput.self))?.isFavorite
            ?? (try? req.query.get(String.self, at: "value")).flatMap(Bool.init)

        return try await req.fileListing.setFavorite(
            fileID: fileID, userID: userID, isFavorite: desired)
    }

    // MARK: - Multipart Upload Handlers

    func initiateMultipartUpload(req: Request) async throws -> InitiateMultipartResponse {
        let userID = try req.auth.require(UserPayload.self).getID()
        let input = try req.content.decode(InitiateMultipartInput.self)

        let session = try await req.fileUploads.initiateMultipartUpload(
            fileID: input.fileID,
            filename: input.filename,
            contentType: input.contentType,
            totalSize: input.totalSize,
            parentID: input.parentID,
            lastModified: input.lastModified,
            createdAt: input.createdAt,
            userID: userID,
            maxChunkSize: Int64(req.application.config.maxChunkSize.value)
        )

        let token = UploadSessionToken(
            exp: .init(value: Date().addingTimeInterval(UploadRules.sessionTTL)),
            iat: .init(value: Date()),
            sessionID: session.sessionID,
            fileID: session.fileID,
            uploadID: session.uploadID,
            userID: session.userID,
            filename: session.filename,
            contentType: session.contentType,
            totalSize: session.totalSize,
            maxChunkSize: session.maxChunkSize,
            parentID: session.parentID,
            lastModified: session.lastModified,
            createdAt: session.createdAt,
            isUpdate: session.isUpdate,
            reservationID: session.reservationID
        )

        let jwtToken = try await req.jwt.sign(token)

        req.logger.info(
            "Multipart upload initiated",
            metadata: [
                "sessionID": .string(session.sessionID.uuidString),
                "filename": .string(input.filename),
            ]
        )

        return InitiateMultipartResponse(
            sessionID: session.sessionID,
            fileID: session.fileID,
            uploadID: session.uploadID,
            maxChunkSize: session.maxChunkSize,
            token: jwtToken
        )
    }

    func uploadPart(req: Request) async throws -> UploadPartResponse {
        let token = try req.auth.require(UploadSessionToken.self)

        let sessionID = try req.parameters.require("sessionID", as: UUID.self)
        let partNumber = try req.parameters.require("partNumber", as: Int.self)

        guard sessionID == token.sessionID else {
            throw Abort(.forbidden, reason: "Session ID mismatch")
        }

        guard let contentLength = req.headers.first(name: .contentLength).flatMap(Int64.init),
            contentLength > 0
        else {
            throw Abort(.lengthRequired, reason: "Content-Length header required")
        }

        guard contentLength <= token.maxChunkSize else {
            throw Abort(.badRequest, reason: "Chunk size exceeds maximum allowed")
        }

        let completedPart = try await req.fileUploads.uploadPart(
            fileID: token.fileID,
            uploadID: token.uploadID,
            partNumber: partNumber,
            userID: token.userID,
            stream: req.body,
            size: contentLength
        )

        req.logger.debug(
            "Part uploaded",
            metadata: [
                "sessionID": .string(sessionID.uuidString),
                "partNumber": .string("\(partNumber)"),
                "etag": .string(completedPart.etag),
            ]
        )

        return UploadPartResponse(
            partNumber: completedPart.partNumber,
            etag: completedPart.etag,
            size: completedPart.size
        )
    }

    func completeMultipartUpload(req: Request) async throws -> FileIndexItemDTO {
        let token = try req.auth.require(UploadSessionToken.self)
        let sessionID = try req.parameters.require("sessionID", as: UUID.self)

        guard sessionID == token.sessionID else {
            throw Abort(.forbidden, reason: "Session ID mismatch")
        }

        let input = try req.content.decode(CompleteMultipartInput.self)

        let parts = input.parts.map { dto in
            CompletedPart(partNumber: dto.partNumber, etag: dto.etag, size: dto.size)
        }

        let metadata = try await req.fileUploads.completeMultipartUpload(
            sessionID: token.sessionID,
            fileID: token.fileID,
            uploadID: token.uploadID,
            userID: token.userID,
            filename: token.filename,
            contentType: token.contentType,
            totalSize: token.totalSize,
            parentID: token.parentID,
            lastModified: token.lastModified,
            createdAt: token.createdAt,
            isUpdate: token.isUpdate ?? false,
            reservationID: token.reservationID,
            parts: parts
        )

        req.logger.info(
            "Multipart upload completed",
            metadata: [
                "sessionID": .string(sessionID.uuidString),
                "fileID": .string(metadata.id?.uuidString ?? ""),
            ]
        )

        if let fileID = metadata.id {
            await dispatchEmbeddingJob(req: req, fileID: fileID)
            GenerateThumbnailJob.dispatchIfNeeded(
                fileID: fileID, contentType: token.contentType, req: req)
        }

        return try await req.fileListing.itemDTOs(for: [metadata], userID: token.userID)[0]
    }

    func abortMultipartUpload(req: Request) async throws -> HTTPStatus {
        let token = try req.auth.require(UploadSessionToken.self)

        try await req.fileUploads.abortMultipartUpload(
            fileID: token.fileID,
            uploadID: token.uploadID,
            sessionID: token.sessionID,
            totalSize: token.totalSize,
            userID: token.userID,
            reservationID: token.reservationID
        )

        req.logger.info(
            "Multipart upload aborted",
            metadata: [
                "sessionID": .string(token.sessionID.uuidString),
                "fileID": .string(token.fileID.uuidString),
            ]
        )

        return .noContent
    }
}
