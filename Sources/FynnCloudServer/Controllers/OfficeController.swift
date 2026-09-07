import Fluent
import Vapor


/// Server-to-server endpoints for the native EuroOffice (DocsAPI) integration:
/// the document server downloads the file from `/api/office/download` and posts edit status to
/// `/api/office/callback`. Both are authenticated by the app-signed, file-scoped token embedded in
/// the URL (`WopiAccessToken`); the callback additionally verifies the document server's own JWT.
struct OfficeController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let office = routes.grouped("api", "office")
        office.get("download", use: download)
        office.on(.POST, "callback", body: .collect(maxSize: "16mb"), use: callback)
    }

    // MARK: - Download (document server pulls the file)

    func download(req: Request) async throws -> Response {
        let token = try await verifiedToken(req: req)
        guard
            let metadata = try await FileMetadata.query(on: req.db)
                .filter(\.$id == token.fileID)
                .filter(\.$owner.$id == token.effectiveOwnerID)
                .first()
        else {
            throw Abort(.notFound)
        }
        return try await req.fileService.getPreauthorizedFileResponse(
            for: try metadata.requireID(), ownerID: token.effectiveOwnerID)
    }

    // MARK: - Callback (document server reports edit status / triggers save)

    func callback(req: Request) async throws -> OfficeCallbackResponse {
        let token = try await verifiedToken(req: req)
        let body = try req.content.decode(OfficeCallbackRequest.self)

        // When JWT is enabled the authoritative status/url live inside the document server's signed token.
        let status: Int
        let downloadURL: String?
        let secret = (try? await req.application.settings.get(AppSettings.EuroOfficeJwtSecret.self)) ?? ""
        if !secret.isEmpty {
            guard let signed = body.token else {
                throw Abort(.forbidden, reason: "Missing document server token.")
            }
            let payload = try await req.euroOfficeService(jwtSecret: secret).verifyCallback(signed)
            status = payload.status ?? -1
            downloadURL = payload.url
        } else {
            status = body.status ?? -1
            downloadURL = body.url
        }

        switch status {
        // 1 = user connected, 4 = closed with no changes: nothing to persist.
        case 1, 4:
            return OfficeCallbackResponse(error: 0)

        // 2 = ready to save (all users left), 6 = force-save while still editing.
        case 2, 6:
            try await save(req: req, token: token, downloadURL: downloadURL)
            return OfficeCallbackResponse(error: 0)

        // 3 = save error, 7 = force-save error.
        case 3, 7:
            req.logger.error(
                "EuroOffice reported a save error",
                metadata: ["fileID": .string(token.fileID.uuidString), "status": .string("\(status)")])
            return OfficeCallbackResponse(error: 0)

        default:
            return OfficeCallbackResponse(error: 0)
        }
    }

    // MARK: - Helpers

    /// Downloads the edited document from the document server and writes it back to storage.
    private func save(req: Request, token: WopiAccessToken, downloadURL: String?) async throws {
        guard token.canWrite else {
            req.logger.warning(
                "Ignoring EuroOffice save for read-only session",
                metadata: ["fileID": .string(token.fileID.uuidString)])
            return
        }
        guard let downloadURL else {
            throw Abort(.badRequest, reason: "Callback did not include a document URL.")
        }
        let uri = URI(string: downloadURL)

        // Re-validate share-scoped sessions so link revocation/expiry is enforced at save time.
        if let shareLinkID = token.shareLinkID {
            try await validateShareScopedAccess(
                req: req, shareLinkID: shareLinkID, fileID: token.fileID)
        }

        let metadata = try await FileMetadata.query(on: req.db)
            .filter(\.$id == token.fileID)
            .filter(\.$owner.$id == token.effectiveOwnerID)
            .first()
        guard let metadata else { throw Abort(.notFound) }

        let response = try await req.client.get(uri)
        guard response.status == .ok, let buffer = response.body else {
            throw Abort(.badGateway, reason: "Could not fetch the edited document.")
        }

        _ = try await req.fileService.updateFromData(
            fileID: token.fileID,
            buffer: buffer,
            contentType: metadata.contentType,
            userID: token.effectiveOwnerID,
            lastModified: Int64(Date().timeIntervalSince1970 * 1000)
        )

        req.logger.info(
            "EuroOffice save persisted",
            metadata: [
                "fileID": .string(token.fileID.uuidString),
                "ownerID": .string(token.effectiveOwnerID.uuidString),
                "shareLinkID": .string(token.shareLinkID?.uuidString ?? "-"),
            ])
    }

    /// Verifies the app-signed file token carried in the `token` query parameter.
    private func verifiedToken(req: Request) async throws -> WopiAccessToken {
        guard let raw = try? req.query.get(String.self, at: "token"), !raw.isEmpty else {
            throw Abort(.unauthorized, reason: "Missing token.")
        }
        guard let payload = try? await req.jwt.verify(raw, as: WopiAccessToken.self) else {
            throw Abort(.unauthorized, reason: "Invalid or expired token.")
        }
        return payload
    }

    /// Re-checks a share-scoped session against the current share-link state (mirrors WopiController).
    private func validateShareScopedAccess(req: Request, shareLinkID: UUID, fileID: UUID) async throws {
        guard let link = try await ShareLink.find(shareLinkID, on: req.db) else {
            throw Abort(.forbidden, reason: "This share link no longer exists.")
        }
        if link.isExpired {
            throw Abort(.gone, reason: "This share link has expired.")
        }
        if link.linkType != .collaborative {
            throw Abort(.forbidden, reason: "This share link does not permit editing.")
        }
        if fileID != link.$file.id {
            guard let file = try await FileMetadata.find(fileID, on: req.db),
                file.ancestorIDs.contains(link.$file.id)
            else {
                throw Abort(.forbidden, reason: "File is outside the shared scope.")
            }
        }
    }
}
