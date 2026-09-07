import Fluent
import Vapor

/// Implements the WOPI host protocol consumed by a WOPI compatible docserver, plus an authenticated
/// bootstrap endpoint the UI uses to open the editor.
///
/// Security model:
/// - Every `/wopi` call is authenticated by a short-lived, per-file/per-user access token (`WopiAccessToken`)
///   that EuroOffice or any other compatible wopi ediotr echoes back on each request; ownership is re-validated against the database.
/// - Writes are gated by WOPI locks (Redis) to prevent concurrent-edit data loss.
/// - Only the file owner receives a writable token (owner-only editing, v1).
struct WopiController: RouteCollection {
    /// File extensions EuroOffice can open. Anything else is rejected before a token is issued.
    static let supportedExtensions: Set<String> = [
        "docx", "doc", "odt", "txt", "md",
        "xlsx", "xls", "ods",
        "pptx", "ppt", "odp",
    ]

    func boot(routes: any RoutesBuilder) throws {
        // Authenticated bootstrap endpoint (uses the app's normal user session).
        let appProtected = routes.grouped("api", "files")
            .grouped(UserPayloadAuthenticator(), UserPayload.guardMiddleware())
        appProtected.get(":fileID", "editor", use: editorInfo)

        // WOPI host endpoints (called by EuroOffice in WOPI mode, authenticated by the access_token query param).
        // Kept under /api so they ride the existing reverse-proxy route (no dedicated /wopi location).
        let wopi = routes.grouped("api", "wopi")
            .grouped(WopiTokenAuthenticator(), WopiAccessToken.guardMiddleware())
        wopi.get("files", ":id", use: checkFileInfo)
        wopi.get("files", ":id", "contents", use: getFile)
        wopi.on(.POST, "files", ":id", "contents", body: .stream, use: putFile)
        wopi.post("files", ":id", use: fileOperation)
    }

    // MARK: - Bootstrap (UI)

    /// Issues an editor session for the current user to open a file.
    func editorInfo(req: Request) async throws -> EditorBootstrap {
        let userID = try req.auth.require(UserPayload.self).getID()
        let fileID = try req.parameters.require("fileID", as: UUID.self)

        let access = try await req.fileAccess.validateAccess(
            fileID: fileID, userID: userID, required: .read)

        return try await Self.makeEditorBootstrap(
            req: req,
            metadata: access.file,
            ownerID: access.ownerID,
            userID: userID,
            canWrite: access.permissions.canWrite,
            userFriendlyName: nil,  // user name is resolved from the DB below
            shareLinkID: nil
        )
    }

    /// Validates that a file is editable and builds an editor session for it. Shared by the
    /// authenticated owner bootstrap and the anonymous share-link bootstrap. Branches on the
    /// configured integration mode (native EuroOffice DocsAPI vs. WOPI host protocol).
    static func makeEditorBootstrap(
        req: Request,
        metadata: FileMetadata,
        ownerID: UUID,
        userID: UUID,
        canWrite: Bool,
        userFriendlyName: String?,
        shareLinkID: UUID?
    ) async throws -> EditorBootstrap {
        guard !metadata.isDirectory else {
            throw Abort(.badRequest, reason: "Folders cannot be opened in the editor.")
        }

        let ext = fileExtension(metadata.filename)
        guard supportedExtensions.contains(ext) else {
            throw Abort(
                .unsupportedMediaType, reason: "This file type cannot be opened in the editor.")
        }

        let documentServerURL = try await req.application.settings.get(
            AppSettings.DocumentServerURL.self
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !documentServerURL.isEmpty else {
            throw Abort(.serviceUnavailable, reason: "Document editing is not configured.")
        }

        let fileID = try metadata.requireID()
        let ttl = Date().addingTimeInterval(10 * 60 * 60)  // 10h editing session
        // App-signed, file-scoped token echoed on WOPI calls / embedded in the native download+callback URLs.
        let token = WopiAccessToken(
            exp: .init(value: ttl),
            iat: .init(value: Date()),
            fileID: fileID,
            userID: userID,
            canWrite: canWrite,
            ownerID: ownerID,
            shareLinkID: shareLinkID,
            userFriendlyName: userFriendlyName
        )
        let accessToken = try await req.jwt.sign(token)

        let provider =
            (try? await req.application.settings.get(AppSettings.OfficeProvider.self))
            ?? .eurooffice
        let publicBaseURL = await Self.resolvedWopiPublicURL(req: req)
        let normalizedBase =
            publicBaseURL.hasSuffix("/") ? String(publicBaseURL.dropLast()) : publicBaseURL

        if provider == .wopi {
            let wopiSrc = "\(normalizedBase)/api/wopi/files/\(fileID.uuidString)"
            let editorUrl = try await req.wopiService.editorURL(
                forExtension: ext,
                preferWrite: canWrite,
                euroOfficeBaseURL: documentServerURL,
                wopiSrc: wopiSrc
            )
            return .wopi(
                fileName: metadata.filename,
                editorUrl: editorUrl,
                accessToken: accessToken,
                accessTokenTtl: Int64(ttl.timeIntervalSince1970 * 1000)
            )
        }

        // Native EuroOffice DocsAPI mode.
        let friendlyName: String
        var avatarURL: String? = nil
        if let userFriendlyName, !userFriendlyName.isEmpty {
            friendlyName = userFriendlyName  // anonymous share guest - no avatar
        } else {
            let user = try await User.find(userID, on: req.db)
            friendlyName = user?.displayName ?? user?.username ?? "User"
            if let updatedAt = user?.avatarUpdatedAt {
                let v = Int(updatedAt.timeIntervalSince1970 * 1000)
                avatarURL = "\(normalizedBase)/api/user/\(userID.uuidString)/avatar?v=\(v)"
            }
        }
        let version =
            metadata.hash
            ?? String(
                Int((metadata.updatedAt ?? metadata.createdAt ?? Date()).timeIntervalSince1970))

        let secret =
            (try? await req.application.settings.get(AppSettings.EuroOfficeJwtSecret.self)) ?? ""
        let config = try await req.euroOfficeService(jwtSecret: secret).buildConfig(
            fileID: fileID,
            fileName: metadata.filename,
            ext: ext,
            version: version,
            canWrite: canWrite,
            userID: userID,
            userFriendlyName: friendlyName,
            userAvatarURL: avatarURL,
            fileToken: accessToken,
            publicBaseURL: publicBaseURL
        )

        let normalizedServer =
            documentServerURL.hasSuffix("/")
            ? String(documentServerURL.dropLast()) : documentServerURL
        return .native(
            fileName: metadata.filename,
            documentServerApiUrl: "\(normalizedServer)/web-apps/apps/api/documents/api.js",
            config: config
        )
    }

    // MARK: - WOPI: CheckFileInfo

    func checkFileInfo(req: Request) async throws -> WopiCheckFileInfo {
        let token = try req.auth.require(WopiAccessToken.self)
        let metadata = try await authorizedFile(req: req, token: token)

        let friendlyName: String
        if let name = token.userFriendlyName, !name.isEmpty {
            friendlyName = name  // anonymous share guest
        } else {
            let user = try await User.find(token.userID, on: req.db)
            friendlyName = user?.displayName ?? user?.username ?? "User"
        }
        let version =
            metadata.hash
            ?? String(
                Int((metadata.updatedAt ?? metadata.createdAt ?? Date()).timeIntervalSince1970))

        let lastMod = metadata.lastModified ?? metadata.updatedAt ?? metadata.createdAt ?? Date()
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return WopiCheckFileInfo(
            baseFileName: metadata.filename,
            size: metadata.size,
            version: version,
            lastModifiedTime: isoFormatter.string(from: lastMod),
            ownerId: token.effectiveOwnerID.uuidString,
            userId: token.userID.uuidString,
            userFriendlyName: friendlyName,
            userCanWrite: token.canWrite,
            readOnly: !token.canWrite,
            userCanNotWriteRelative: true,  // "Save As" / PutRelativeFile not supported (v1)
            supportsLocks: true,
            supportsGetLock: true,
            supportsUpdate: true,
            closePostMessage: true,
            // Must be the exact origin of the window hosting the editor iframe (the FynnCloud UI),
            // which is same-origin as the public WOPI host URL. FRONTEND_URL is unreliable here.
            postMessageOrigin: await Self.resolvedWopiPublicURL(req: req)
        )
    }

    // MARK: - WOPI: GetFile

    func getFile(req: Request) async throws -> Response {
        let token = try req.auth.require(WopiAccessToken.self)
        let metadata = try await authorizedFile(req: req, token: token)
        return try await req.fileService.getFileResponse(
            for: try metadata.requireID(), userID: token.effectiveOwnerID)
    }

    // MARK: - WOPI: PutFile

    func putFile(req: Request) async throws -> Response {
        let token = try req.auth.require(WopiAccessToken.self)
        guard token.canWrite else {
            throw Abort(.forbidden, reason: "This session is read-only.")
        }
        let metadata = try await authorizedFile(req: req, token: token)
        let fileID = try metadata.requireID()

        let requestLock = req.headers.first(name: "X-WOPI-Lock")
        let currentLock = try await req.wopiService.currentLock(fileID: fileID)

        // Lock enforcement: reject writes that don't hold the current lock (prevents lost updates).
        if let currentLock {
            guard requestLock == currentLock else {
                return lockConflict(currentLock: currentLock)
            }
        } else if metadata.size > 0 {
            // Non-empty file must be locked before it can be overwritten.
            return lockConflict(currentLock: "")
        }

        guard let contentLength = req.headers.first(name: .contentLength).flatMap(Int64.init) else {
            throw Abort(.lengthRequired)
        }

        _ = try await req.fileService.update(
            fileID: fileID,
            stream: req.body,
            claimedSize: contentLength,
            contentType: metadata.contentType,
            userID: token.effectiveOwnerID,
            // Stamp the save time so the DB field, CheckFileInfo.LastModifiedTime, and the UI all reflect the edit.
            lastModified: Int64(Date().timeIntervalSince1970 * 1000)
        )

        if currentLock != nil {
            try await req.wopiService.refreshLock(fileID: fileID)
        }

        req.logger.info(
            "WOPI PutFile saved",
            metadata: [
                "fileID": .string(fileID.uuidString),
                "ownerID": .string(token.effectiveOwnerID.uuidString),
                "editorID": .string(token.userID.uuidString),
                "shareLinkID": .string(token.shareLinkID?.uuidString ?? "-"),
            ])

        let response = Response(status: .ok)
        if let lock = requestLock ?? currentLock {
            response.headers.replaceOrAdd(name: "X-WOPI-Lock", value: lock)
        }
        return response
    }

    // MARK: - WOPI: Lock operations

    func fileOperation(req: Request) async throws -> Response {
        let token = try req.auth.require(WopiAccessToken.self)
        let metadata = try await authorizedFile(req: req, token: token)
        let fileID = try metadata.requireID()

        let override = req.headers.first(name: "X-WOPI-Override") ?? ""
        let requestLock = req.headers.first(name: "X-WOPI-Lock") ?? ""
        let oldLock = req.headers.first(name: "X-WOPI-OldLock")
        let current = try await req.wopiService.currentLock(fileID: fileID)

        switch override {
        case "GET_LOCK":
            let response = Response(status: .ok)
            response.headers.replaceOrAdd(name: "X-WOPI-Lock", value: current ?? "")
            return response

        case "LOCK":
            // A LOCK carrying X-WOPI-OldLock is an UnlockAndRelock.
            if let oldLock {
                return try await unlockAndRelock(
                    req: req, fileID: fileID, newLock: requestLock, oldLock: oldLock,
                    current: current)
            }
            guard token.canWrite else { throw Abort(.forbidden) }
            if let current, current == requestLock {
                try await req.wopiService.refreshLock(fileID: fileID)
                return okWithLock(requestLock)
            }
            // Take over any existing (possibly stale) lock: EuroOffice serializes editing per
            // document, so a differing lock means a prior session ended without unlocking.
            try await req.wopiService.setLock(fileID: fileID, lock: requestLock)
            return okWithLock(requestLock)

        case "UNLOCK":
            guard let current else { return lockConflict(currentLock: "") }
            guard current == requestLock else { return lockConflict(currentLock: current) }
            try await req.wopiService.deleteLock(fileID: fileID)
            return okWithLock(requestLock)

        case "REFRESH_LOCK":
            guard let current else { return lockConflict(currentLock: "") }
            guard current == requestLock else { return lockConflict(currentLock: current) }
            try await req.wopiService.refreshLock(fileID: fileID)
            return okWithLock(requestLock)

        case "UNLOCK_AND_RELOCK":
            return try await unlockAndRelock(
                req: req, fileID: fileID, newLock: requestLock, oldLock: oldLock ?? "",
                current: current)

        default:
            throw Abort(.notImplemented, reason: "Unsupported WOPI operation: \(override)")
        }
    }

    // MARK: - Helpers

    private func unlockAndRelock(
        req: Request, fileID: UUID, newLock: String, oldLock: String, current: String?
    ) async throws -> Response {
        guard let current else { return lockConflict(currentLock: "") }
        guard current == oldLock else { return lockConflict(currentLock: current) }
        try await req.wopiService.setLock(fileID: fileID, lock: newLock)
        return okWithLock(newLock)
    }

    /// Resolves the file for a WOPI request while enforcing token/path binding and ownership.
    private func authorizedFile(req: Request, token: WopiAccessToken) async throws -> FileMetadata {
        let pathID = try req.parameters.require("id", as: UUID.self)
        guard pathID == token.fileID else {
            throw Abort(.forbidden, reason: "Token does not match the requested file.")
        }
        guard
            let metadata = try await FileMetadata.query(on: req.db)
                .filter(\.$id == pathID)
                .filter(\.$owner.$id == token.effectiveOwnerID)
                .first()
        else {
            throw Abort(.notFound)
        }
        // Share-scoped sessions re-validate the link on every call so revocation/expiry takes effect
        // immediately, despite the long-lived (10h) access token.
        if let shareLinkID = token.shareLinkID {
            try await validateShareScopedAccess(
                req: req, shareLinkID: shareLinkID, fileID: pathID, canWrite: token.canWrite)
        }
        return metadata
    }

    /// Re-checks a share-scoped WOPI session against the current share-link state.
    private func validateShareScopedAccess(
        req: Request, shareLinkID: UUID, fileID: UUID, canWrite: Bool
    ) async throws {
        guard let link = try await ShareLink.find(shareLinkID, on: req.db) else {
            throw Abort(.forbidden, reason: "This share link no longer exists.")
        }
        if link.isExpired {
            throw Abort(.gone, reason: "This share link has expired.")
        }
        // Editing requires a collaborative link; a downgraded link revokes write access.
        if canWrite && link.linkType != .collaborative {
            throw Abort(.forbidden, reason: "This share link does not permit editing.")
        }
        // The file must be the shared root itself or a descendant of it.
        if fileID != link.$file.id {
            guard let file = try await FileMetadata.find(fileID, on: req.db),
                file.ancestorIDs.contains(link.$file.id)
            else {
                throw Abort(.forbidden, reason: "File is outside the shared scope.")
            }
        }
    }

    private func okWithLock(_ lock: String) -> Response {
        let response = Response(status: .ok)
        response.headers.replaceOrAdd(name: "X-WOPI-Lock", value: lock)
        return response
    }

    private func lockConflict(currentLock: String) -> Response {
        let response = Response(status: .conflict)
        response.headers.replaceOrAdd(name: "X-WOPI-Lock", value: currentLock)
        return response
    }

    static func fileExtension(_ filename: String) -> String {
        (filename as NSString).pathExtension.lowercased()
    }

    static func resolvedWopiPublicURL(req: Request) async -> String {
        let configured =
            (try? await req.application.settings.get(AppSettings.WopiPublicURL.self))
            ?? AppSettings.WopiPublicURL.defaultValue
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty ? trimmed : req.application.config.frontendURL
    }
}
