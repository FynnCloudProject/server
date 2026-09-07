import Fluent
import FluentSQL
import SQLKit
import Vapor

struct ShareController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let api = routes.grouped("api", "share")
        let publicShare = api.grouped(RateLimitMiddleware(category: .share))

        // Public endpoints - accessed by share link recipients
        publicShare.get(":token", use: getSharedContent)
        publicShare.get(":token", "download", use: downloadSharedFile)
        publicShare.get(":token", "thumbnail", use: thumbnailSharedFile)
        publicShare.get(":token", "browse", ":fileID", use: browseSharedFolder)
        publicShare.get(":token", "download", ":fileID", use: downloadSharedChild)
        publicShare.get(":token", "thumbnail", ":fileID", use: thumbnailSharedChild)
        publicShare.get(":token", "search", use: searchSharedContent)
        publicShare.post(":token", "unlock", use: unlockShareLink)
        publicShare.get(":token", "editor", ":fileID", use: shareEditorInfo)
        publicShare.post(":token", "upload", "initiate", use: initiateShareUpload)
        publicShare.post(":token", "upload", use: initiateShareUpload)

        // Authenticated endpoints - manage share links and internal shares
        let protected = routes.grouped("api", "files")
            .grouped(UserPayloadAuthenticator(), UserPayload.guardMiddleware())

        protected.post(":fileID", "share", use: createShareLink)
        protected.get(":fileID", "shares", use: listShareLinks)
        protected.delete(":fileID", "shares", ":linkID", use: revokeShareLink)

        protected.get(":fileID", "internal-shares", use: listInternalShares)
        protected.post(":fileID", "internal-shares", use: createInternalShare)
        protected.put(":fileID", "internal-shares", ":shareID", use: updateInternalShare)
        protected.delete(":fileID", "internal-shares", ":shareID", use: revokeInternalShare)

        let sharesApi = routes.grouped("api", "shares")
            .grouped(UserPayloadAuthenticator(), UserPayload.guardMiddleware())
        sharesApi.get("recipients", use: searchRecipients)
    }

    // MARK: - Public Endpoints

    /// Get metadata for a shared file or folder (includes children if folder)
    func getSharedContent(req: Request) async throws -> ShareContentDTO {
        let link = try await resolveShareLink(req: req)
        let file = try await FileMetadata.query(on: req.db)
            .filter(\.$id == link.$file.id)
            .first()

        guard let file else {
            throw Abort(.notFound)
        }

        var children: [SharedFileDTO]? = nil
        if file.isDirectory && link.linkType.allowsView {
            let items = try await FileMetadata.query(on: req.db)
                .filter(\.$parent.$id == file.id!)
                .filter(\.$deletedAt == nil)
                .sort(\.$isDirectory, .descending)
                .sort(\.$filename, .ascending)
                .all()
            children = items.map { SharedFileDTO(from: $0) }
        }

        return ShareContentDTO(
            file: SharedFileDTO(from: file),
            children: children,
            linkType: link.linkType,
            expiresAt: link.expiresAt
        )
    }

    /// Download a shared file directly
    func downloadSharedFile(req: Request) async throws -> Response {
        let link = try await resolveShareLink(req: req)
        guard link.linkType.allowsView else {
            throw Abort(.forbidden, reason: "Viewing files is not permitted for this share link.")
        }
        let file = try await FileMetadata.query(on: req.db)
            .filter(\.$id == link.$file.id)
            .first()

        guard let file, !file.isDirectory else {
            throw Abort(.badRequest, reason: "Cannot download a directory.")
        }

        let etag = FileService.etag(for: file)
        if let ifNoneMatch = req.headers.first(name: .ifNoneMatch), ifNoneMatch == etag {
            return FileService.notModifiedResponse(etag: etag)
        }

        let response = try await req.fileService.getPreauthorizedFileResponse(
            for: file.id!, ownerID: file.$owner.id, range: req.headers.range)
        let isInline = req.query[String.self, at: "inline"] == "true"
            || req.query[String.self, at: "disposition"] == "inline"
        FileService.applyDownloadHeaders(
            to: response, file: file, etag: etag, isInline: isInline)
        return response
    }

    /// Get thumbnail for a shared file
    func thumbnailSharedFile(req: Request) async throws -> Response {
        let link = try await resolveShareLink(req: req)
        guard link.linkType.allowsView else {
            throw Abort(.forbidden, reason: "Viewing files is not permitted for this share link.")
        }
        guard let file = try await FileMetadata.query(on: req.db)
            .filter(\.$id == link.$file.id)
            .first(), !file.isDirectory
        else {
            throw Abort(.badRequest, reason: "Cannot get thumbnail for a directory.")
        }

        guard file.hasThumbnail else {
            GenerateThumbnailJob.dispatchIfNeeded(for: file, req: req)
            throw Abort(.notFound, reason: "No thumbnail available")
        }

        do {
            let response = try await req.storageService.thumbnailResponse(
                fileID: file.id!, userID: file.$owner.id)
            response.apply(.derived, contentType: "image/jpeg")
            return response
        } catch {
            GenerateThumbnailJob.dispatchIfNeeded(for: file, req: req)
            if file.hasThumbnail {
                file.hasThumbnail = false
                try? await file.save(on: req.db)
            }
            throw error
        }
    }

    /// Browse into a subfolder of a shared folder
    func browseSharedFolder(req: Request) async throws -> ShareContentDTO {
        let link = try await resolveShareLink(req: req)
        guard link.linkType.allowsView else {
            throw Abort(.forbidden, reason: "Viewing files is not permitted for this share link.")
        }
        let fileID = try req.parameters.require("fileID", as: UUID.self)

        // Verify the requested file is a descendant of the shared root
        try await verifyDescendant(fileID: fileID, sharedRootID: link.$file.id, db: req.db)

        guard let file = try await FileMetadata.find(fileID, on: req.db),
            file.isDirectory
        else {
            throw Abort(.notFound)
        }

        let items = try await FileMetadata.query(on: req.db)
            .filter(\.$parent.$id == fileID)
            .filter(\.$deletedAt == nil)
            .sort(\.$isDirectory, .descending)
            .sort(\.$filename, .ascending)
            .all()

        return ShareContentDTO(
            file: SharedFileDTO(from: file),
            children: items.map { SharedFileDTO(from: $0) },
            linkType: link.linkType,
            expiresAt: link.expiresAt
        )
    }

    /// Download a file inside a shared folder
    func downloadSharedChild(req: Request) async throws -> Response {
        let link = try await resolveShareLink(req: req)
        guard link.linkType.allowsView else {
            throw Abort(.forbidden, reason: "Viewing files is not permitted for this share link.")
        }
        let fileID = try req.parameters.require("fileID", as: UUID.self)

        // Verify descent from shared root
        try await verifyDescendant(fileID: fileID, sharedRootID: link.$file.id, db: req.db)

        guard let file = try await FileMetadata.find(fileID, on: req.db),
            !file.isDirectory
        else {
            throw Abort(.badRequest, reason: "Cannot download a directory.")
        }

        let etag = FileService.etag(for: file)
        if let ifNoneMatch = req.headers.first(name: .ifNoneMatch), ifNoneMatch == etag {
            return FileService.notModifiedResponse(etag: etag)
        }

        let response = try await req.fileService.getPreauthorizedFileResponse(
            for: file.id!, ownerID: file.$owner.id, range: req.headers.range)
        let isInline = req.query[String.self, at: "inline"] == "true"
            || req.query[String.self, at: "disposition"] == "inline"
        FileService.applyDownloadHeaders(
            to: response, file: file, etag: etag, isInline: isInline)
        return response
    }

    /// Get thumbnail for a file inside a shared folder
    func thumbnailSharedChild(req: Request) async throws -> Response {
        let link = try await resolveShareLink(req: req)
        guard link.linkType.allowsView else {
            throw Abort(.forbidden, reason: "Viewing files is not permitted for this share link.")
        }
        let fileID = try req.parameters.require("fileID", as: UUID.self)

        // Verify descent from shared root
        try await verifyDescendant(fileID: fileID, sharedRootID: link.$file.id, db: req.db)

        guard let file = try await FileMetadata.find(fileID, on: req.db),
            !file.isDirectory
        else {
            throw Abort(.badRequest, reason: "Cannot get thumbnail for a directory.")
        }

        guard file.hasThumbnail else {
            GenerateThumbnailJob.dispatchIfNeeded(for: file, req: req)
            throw Abort(.notFound, reason: "No thumbnail available")
        }

        do {
            let response = try await req.storageService.thumbnailResponse(
                fileID: file.id!, userID: file.$owner.id)
            response.apply(.derived, contentType: "image/jpeg")
            return response
        } catch {
            GenerateThumbnailJob.dispatchIfNeeded(for: file, req: req)
            if file.hasThumbnail {
                file.hasThumbnail = false
                try? await file.save(on: req.db)
            }
            throw error
        }
    }

    /// Search for files/folders inside a shared folder (recursively)
    func searchSharedContent(req: Request) async throws -> [SharedFileDTO] {
        let link = try await resolveShareLink(req: req)
        guard link.linkType.allowsView else {
            throw Abort(.forbidden, reason: "Viewing files is not permitted for this share link.")
        }
        
        let query = try req.query.get(String.self, at: "q").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return []
        }
        
        let matches: [FileMetadata]
        if let sql = req.db as? any SQLDatabase, sql.dialect.name == "postgresql" {
            matches = try await FileMetadata.query(on: req.db)
                .filter(\.$deletedAt == nil)
                .filter(\.$filename, .custom("ILIKE"), "%\(query)%")
                .filter(\.$ancestorIDs, .custom("@>"), [link.$file.id])
                .all()
        } else {
            let allMatches = try await FileMetadata.query(on: req.db)
                .filter(\.$deletedAt == nil)
                .filter(\.$filename, .custom("LIKE"), "%\(query)%")
                .all()
            matches = allMatches.filter { $0.ancestorIDs.contains(link.$file.id) }
        }
            
        return matches.map { SharedFileDTO(from: $0) }
    }

    /// Initiate an upload to a shared link (returns UploadSessionToken JWT)
    func initiateShareUpload(req: Request) async throws -> InitiateMultipartResponse {
        let link = try await resolveShareLink(req: req)
        guard link.linkType.allowsUpload else {
            throw Abort(.forbidden, reason: "Uploads are not permitted for this share link.")
        }

        guard let sharedFile = try await FileMetadata.query(on: req.db)
            .filter(\.$id == link.$file.id)
            .first()
        else {
            throw Abort(.notFound)
        }

        guard sharedFile.isDirectory else {
            throw Abort(.badRequest, reason: "Uploads are only allowed to shared folders.")
        }

        let input = try req.content.decode(InitiateMultipartInput.self)
        let ownerID = sharedFile.$owner.id

        let targetParentID: UUID?
        if let requestedParentID = input.parentID {
            let targetFolder = try await verifyDescendant(fileID: requestedParentID, sharedRootID: sharedFile.id!, db: req.db)
            guard targetFolder.isDirectory else {
                throw Abort(.badRequest, reason: "Target parent must be a directory.")
            }
            targetParentID = requestedParentID
        } else {
            targetParentID = sharedFile.id
        }

        let session = try await req.fileUploads.initiateMultipartUpload(
            filename: input.filename,
            contentType: input.contentType,
            totalSize: input.totalSize,
            parentID: targetParentID,
            lastModified: input.lastModified,
            userID: ownerID,
            maxChunkSize: Int64(req.application.config.maxChunkSize.value)
        )

        let token = UploadSessionToken(
            exp: .init(value: Date().addingTimeInterval(86400)),
            iat: .init(value: Date()),
            sessionID: session.sessionID,
            fileID: session.fileID,
            uploadID: session.uploadID,
            userID: ownerID,
            filename: session.filename,
            contentType: session.contentType,
            totalSize: session.totalSize,
            maxChunkSize: session.maxChunkSize,
            parentID: session.parentID,
            lastModified: session.lastModified,
            isUpdate: session.isUpdate,
            reservationID: session.reservationID
        )

        let jwtToken = try await req.jwt.sign(token)

        req.logger.info(
            "Share upload initiated",
            metadata: [
                "shareToken": .string(link.token),
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

    /// Issue an anonymous, share-scoped editor session for an editable (collaborative) share link.
    func shareEditorInfo(req: Request) async throws -> EditorBootstrap {
        let link = try await resolveShareLink(req: req)
        guard link.linkType == .collaborative else {
            throw Abort(.forbidden, reason: "This share link does not permit editing.")
        }
        let fileID = try req.parameters.require("fileID", as: UUID.self)

        // The file must be the shared root itself or a descendant of it.
        let file = try await verifyDescendant(fileID: fileID, sharedRootID: link.$file.id, db: req.db)
        guard !file.isDirectory else {
            throw Abort(.badRequest, reason: "Folders cannot be opened in the editor.")
        }

        let rawName = req.query[String.self, at: "guestName"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let guestName = rawName.isEmpty ? "Guest" : "Guest (\(String(rawName.prefix(47))))"

        return try await WopiController.makeEditorBootstrap(
            req: req,
            metadata: file,
            ownerID: file.$owner.id,
            userID: UUID(),  // pseudonymous per-session identity for co-editing presence
            canWrite: true,
            userFriendlyName: guestName,
            shareLinkID: link.id
        )
    }

    // MARK: - Authenticated Endpoints

    /// Create a new share link for a file/folder
    func createShareLink(req: Request) async throws -> ShareLinkDTO {
        let userID = try req.auth.require(UserPayload.self).getID()
        let fileID = try req.parameters.require("fileID", as: UUID.self)

        let input: CreateShareLinkInput?
        if req.body.data != nil && (req.body.data?.readableBytes ?? 0) > 0 {
            input = try req.content.decode(CreateShareLinkInput.self)
        } else {
            input = nil
        }

        return try await Self.createLink(
            fileID: fileID, userID: userID, linkType: input?.linkType ?? .viewOnly,
            expiresAt: input?.expiresAt, password: input?.password,
            db: req.db, syncLogService: req.syncLogService
        )
    }

    /// Shared by the `POST /api/files/:fileID/share` endpoint and the AI assistant's
    /// `create_share_link` tool, so both paths enforce the exact same ownership/type rules.
    static func createLink(
        fileID: UUID, userID: UUID, linkType: ShareLinkType, expiresAt: Date?, password: String?,
        db: any Database, syncLogService: SyncLogService
    ) async throws -> ShareLinkDTO {
        // Verify ownership and fetch file metadata
        guard
            let targetFile = try await FileMetadata.query(on: db)
                .filter(\.$id == fileID)
                .filter(\.$owner.$id == userID)
                .first()
        else {
            throw Abort(.notFound)
        }

        // File-drop targets a folder to receive uploads; collaborative on a single file means "editable".
        if !targetFile.isDirectory && linkType == .fileDrop {
            throw Abort(.badRequest, reason: "File drop share links are only allowed for folders.")
        }

        // Generate a cryptographically random token (22 URL-safe chars ≈ 128 bits)
        let tokenData = [UInt8].random(count: 16)
        let token = Data(tokenData).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        var passwordHash: String? = nil
        if let password, !password.isEmpty {
            passwordHash = try Bcrypt.hash(password)
        }

        let link = ShareLink(
            token: token,
            fileID: fileID,
            createdBy: userID,
            expiresAt: expiresAt,
            passwordHash: passwordHash,
            linkType: linkType
        )
        try await link.save(on: db)

        targetFile.isShared = true
        try await targetFile.save(on: db)
        await syncLogService.emitPublicShare(on: db, link: link, file: targetFile, isRevoke: false)

        return ShareLinkDTO(from: link)
    }

    /// List all active share links for a file
    func listShareLinks(req: Request) async throws -> [ShareLinkDTO] {
        let userID = try req.auth.require(UserPayload.self).getID()
        let fileID = try req.parameters.require("fileID", as: UUID.self)

        let links = try await ShareLink.query(on: req.db)
            .filter(\.$file.$id == fileID)
            .filter(\.$creator.$id == userID)
            .sort(\.$createdAt, .descending)
            .all()

        return links.map { ShareLinkDTO(from: $0) }
    }

    /// Revoke (delete) a share link
    func revokeShareLink(req: Request) async throws -> HTTPStatus {
        let userID = try req.auth.require(UserPayload.self).getID()
        let fileID = try req.parameters.require("fileID", as: UUID.self)
        let linkID = try req.parameters.require("linkID", as: UUID.self)

        try await Self.revokeLink(fileID: fileID, linkID: linkID, userID: userID, db: req.db, syncLogService: req.syncLogService)

        return .noContent
    }

    /// Shared by the `DELETE /api/files/:fileID/shares/:linkID` endpoint and the AI assistant's
    /// `revoke_share_link` tool.
    static func revokeLink(
        fileID: UUID, linkID: UUID, userID: UUID, db: any Database, syncLogService: SyncLogService
    ) async throws {
        guard
            let link = try await ShareLink.query(on: db)
                .filter(\.$id == linkID)
                .filter(\.$file.$id == fileID)
                .filter(\.$creator.$id == userID)
                .first()
        else {
            throw Abort(.notFound)
        }

        if let file = try await FileMetadata.find(fileID, on: db) {
            await syncLogService.emitPublicShare(on: db, link: link, file: file, isRevoke: true)
        }

        try await link.delete(on: db)

        // If no more share links or internal shares exist for this file, unmark it
        let linkRemaining = try await ShareLink.query(on: db)
            .filter(\.$file.$id == fileID)
            .count()
        let internalRemaining = try await InternalShare.query(on: db)
            .filter(\.$file.$id == fileID)
            .count()
        if linkRemaining == 0 && internalRemaining == 0 {
            if let file = try await FileMetadata.find(fileID, on: db) {
                file.isShared = false
                try await file.save(on: db)
            }
        }
    }

    // MARK: - Internal Sharing Endpoints

    /// List all internal shares for a file
    func listInternalShares(req: Request) async throws -> [InternalShareDTO] {
        let userID = try req.auth.require(UserPayload.self).getID()
        let fileID = try req.parameters.require("fileID", as: UUID.self)

        _ = try await req.fileAccess.validateAccess(fileID: fileID, userID: userID, required: .share)

        let shares = try await InternalShare.query(on: req.db)
            .filter(\.$file.$id == fileID)
            .with(\.$granteeUser)
            .with(\.$granteeGroup)
            .sort(\.$createdAt, .descending)
            .all()

        return shares.map { InternalShareDTO(from: $0) }
    }

    /// Create or update an internal share for a user or group
    func createInternalShare(req: Request) async throws -> InternalShareDTO {
        let userID = try req.auth.require(UserPayload.self).getID()
        let fileID = try req.parameters.require("fileID", as: UUID.self)
        let input = try req.content.decode(CreateInternalShareInput.self)

        _ = try await req.fileAccess.validateAccess(fileID: fileID, userID: userID, required: .share)

        let role = input.role ?? .viewer

        switch input.granteeType {
        case .user:
            guard let targetUserID = input.granteeUserID else {
                throw Abort(.badRequest, reason: "granteeUserID is required for user shares.")
            }
            guard targetUserID != userID else {
                throw Abort(.badRequest, reason: "You cannot share a file with yourself.")
            }
            guard (try await User.find(targetUserID, on: req.db)) != nil else {
                throw Abort(.notFound, reason: "Grantee user not found.")
            }

            if let existing = try await InternalShare.query(on: req.db)
                .filter(\.$file.$id == fileID)
                .filter(\.$granteeType == .user)
                .filter(\.$granteeUser.$id == targetUserID)
                .with(\.$granteeUser)
                .with(\.$granteeGroup)
                .first() {
                existing.role = role
                try await existing.save(on: req.db)

                if let file = try await FileMetadata.find(fileID, on: req.db) {
                    file.isShared = true
                    try await file.save(on: req.db)
                    await req.syncLogService.emitInternalShare(on: req.db, share: existing, file: file, eventType: .share)
                }

                return InternalShareDTO(from: existing)
            }

            let share = InternalShare(
                fileID: fileID,
                granteeType: .user,
                granteeUserID: targetUserID,
                role: role,
                createdBy: userID
            )
            try await share.save(on: req.db)

            if let file = try await FileMetadata.find(fileID, on: req.db) {
                file.isShared = true
                try await file.save(on: req.db)
                await req.syncLogService.emitInternalShare(on: req.db, share: share, file: file, eventType: .share)
            }

            guard let reloaded = try await InternalShare.query(on: req.db)
                .filter(\.$id == share.requireID())
                .with(\.$granteeUser)
                .with(\.$granteeGroup)
                .first() else {
                throw Abort(.internalServerError)
            }
            return InternalShareDTO(from: reloaded)

        case .group:
            guard let targetGroupID = input.granteeGroupID else {
                throw Abort(.badRequest, reason: "granteeGroupID is required for group shares.")
            }
            guard (try await Group.find(targetGroupID, on: req.db)) != nil else {
                throw Abort(.notFound, reason: "Grantee group not found.")
            }

            if let existing = try await InternalShare.query(on: req.db)
                .filter(\.$file.$id == fileID)
                .filter(\.$granteeType == .group)
                .filter(\.$granteeGroup.$id == targetGroupID)
                .with(\.$granteeUser)
                .with(\.$granteeGroup)
                .first() {
                existing.role = role
                try await existing.save(on: req.db)

                if let file = try await FileMetadata.find(fileID, on: req.db) {
                    file.isShared = true
                    try await file.save(on: req.db)
                    await req.syncLogService.emitInternalShare(on: req.db, share: existing, file: file, eventType: .share)
                }

                return InternalShareDTO(from: existing)
            }

            let share = InternalShare(
                fileID: fileID,
                granteeType: .group,
                granteeGroupID: targetGroupID,
                role: role,
                createdBy: userID
            )
            try await share.save(on: req.db)

            if let file = try await FileMetadata.find(fileID, on: req.db) {
                file.isShared = true
                try await file.save(on: req.db)
                await req.syncLogService.emitInternalShare(on: req.db, share: share, file: file, eventType: .share)
            }

            guard let reloaded = try await InternalShare.query(on: req.db)
                .filter(\.$id == share.requireID())
                .with(\.$granteeUser)
                .with(\.$granteeGroup)
                .first() else {
                throw Abort(.internalServerError)
            }
            return InternalShareDTO(from: reloaded)
        }
    }

    /// Update the role on an existing internal share
    func updateInternalShare(req: Request) async throws -> InternalShareDTO {
        let userID = try req.auth.require(UserPayload.self).getID()
        let fileID = try req.parameters.require("fileID", as: UUID.self)
        let shareID = try req.parameters.require("shareID", as: UUID.self)
        let input = try req.content.decode(UpdateInternalShareInput.self)

        _ = try await req.fileAccess.validateAccess(fileID: fileID, userID: userID, required: .share)

        guard let share = try await InternalShare.query(on: req.db)
            .filter(\.$id == shareID)
            .filter(\.$file.$id == fileID)
            .with(\.$granteeUser)
            .with(\.$granteeGroup)
            .first() else {
            throw Abort(.notFound, reason: "Share not found.")
        }

        share.role = input.role
        try await share.save(on: req.db)

        if let file = try await FileMetadata.find(fileID, on: req.db) {
            file.isShared = true
            try await file.save(on: req.db)
            await req.syncLogService.emitInternalShare(on: req.db, share: share, file: file, eventType: .modify)
        }

        return InternalShareDTO(from: share)
    }

    /// Revoke (delete) an internal share
    func revokeInternalShare(req: Request) async throws -> HTTPStatus {
        let userID = try req.auth.require(UserPayload.self).getID()
        let fileID = try req.parameters.require("fileID", as: UUID.self)
        let shareID = try req.parameters.require("shareID", as: UUID.self)

        _ = try await req.fileAccess.validateAccess(fileID: fileID, userID: userID, required: .share)

        guard let share = try await InternalShare.query(on: req.db)
            .filter(\.$id == shareID)
            .filter(\.$file.$id == fileID)
            .first() else {
            throw Abort(.notFound, reason: "Share not found.")
        }

        if let file = try await FileMetadata.find(fileID, on: req.db) {
            await req.syncLogService.emitInternalShare(on: req.db, share: share, file: file, eventType: .unshare)
        }

        try await share.delete(on: req.db)

        let internalRemaining = try await InternalShare.query(on: req.db).filter(\.$file.$id == fileID).count()
        let linkRemaining = try await ShareLink.query(on: req.db).filter(\.$file.$id == fileID).count()

        if internalRemaining == 0 && linkRemaining == 0 {
            if let file = try await FileMetadata.find(fileID, on: req.db) {
                file.isShared = false
                try await file.save(on: req.db)
            }
        }

        return .noContent
    }

    /// Search users and groups that can be selected as share recipients
    func searchRecipients(req: Request) async throws -> [ShareRecipientDTO] {
        let userID = try req.auth.require(UserPayload.self).getID()
        let query = (try? req.query.get(String.self, at: "q"))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !query.isEmpty else {
            return []
        }

        let pattern = "%\(query)%"

        let users = try await User.query(on: req.db)
            .filter(\.$id != userID)
            .group(.or) { orGroup in
                orGroup.filter(\.$username, .custom("ILIKE"), pattern)
                orGroup.filter(\.$displayName, .custom("ILIKE"), pattern)
            }
            .limit(10)
            .all()

        let groups = try await Group.query(on: req.db)
            .group(.or) { orGroup in
                orGroup.filter(\.$name, .custom("ILIKE"), pattern)
                orGroup.filter(\.$systemKey, .custom("ILIKE"), pattern)
            }
            .limit(10)
            .all()

        var results: [ShareRecipientDTO] = []
        for u in users {
            if let uID = u.id {
                results.append(ShareRecipientDTO(
                    id: uID.uuidString,
                    name: u.username,
                    displayName: u.displayName,
                    type: .user,
                    avatarUpdatedAt: u.avatarUpdatedAt
                ))
            }
        }
        for g in groups {
            if let gID = g.id {
                results.append(ShareRecipientDTO(
                    id: String(gID),
                    name: g.name,
                    displayName: nil,
                    type: .group,
                    avatarUpdatedAt: nil,
                    systemKey: g.systemKey
                ))
            }
        }

        return results
    }

    // MARK: - Helpers

    /// Resolve and validate a share link token from the URL
    private func resolveShareLink(req: Request) async throws -> ShareLink {
        let token = try req.parameters.require("token", as: String.self)

        guard
            let link = try await ShareLink.query(on: req.db)
                .filter(\.$token == token)
                .first()
        else {
            throw Abort(.notFound)
        }

        if link.isExpired {
            throw Abort(.gone, reason: "This share link has expired.")
        }

        if link.passwordHash != nil {
            let password = req.headers.first(name: .init("X-Share-Password"))
                ?? req.cookies["share_pwd_\(token)"]?.string
                ?? req.cookies["share_password"]?.string
                ?? req.query[String.self, at: "pwd"]
                ?? req.query[String.self, at: "password"]
                ?? ""
            guard try Bcrypt.verify(password, created: link.passwordHash!) else {
                throw Abort(.unauthorized, reason: "Invalid password.")
            }
        }

        return link
    }

    /// Verify password for a share link and set HttpOnly session cookie
    func unlockShareLink(req: Request) async throws -> Response {
        let token = try req.parameters.require("token", as: String.self)
        let input = try req.content.decode(UnlockShareInput.self)

        guard
            let link = try await ShareLink.query(on: req.db)
                .filter(\.$token == token)
                .first()
        else {
            throw Abort(.notFound)
        }

        if link.isExpired {
            throw Abort(.gone, reason: "This share link has expired.")
        }

        if let hash = link.passwordHash {
            guard try Bcrypt.verify(input.password, created: hash) else {
                throw Abort(.unauthorized, reason: "Invalid password.")
            }
        }

        let isProduction = req.application.environment == .production
        let response = Response(status: .ok)
        let cookieName = "share_pwd_\(token)"
        response.cookies[cookieName] = HTTPCookies.Value(
            string: input.password,
            expires: nil, // Session cookie (deleted when browser closes)
            maxAge: nil,
            domain: nil,
            path: "/",
            isSecure: isProduction,
            isHTTPOnly: true,
            sameSite: .lax
        )
        return response
    }

    /// Verify that fileID is a descendant of sharedRootID (prevents path traversal)
    @discardableResult
    private func verifyDescendant(fileID: UUID, sharedRootID: UUID, db: any Database)
        async throws -> FileMetadata
    {
        guard let file = try await FileMetadata.find(fileID, on: db) else {
            throw Abort(.notFound)
        }
        guard file.id == sharedRootID || file.ancestorIDs.contains(sharedRootID) else {
            throw Abort(.forbidden, reason: "Access denied.")
        }
        return file
    }
}

struct UnlockShareInput: Content {
    let password: String
}
