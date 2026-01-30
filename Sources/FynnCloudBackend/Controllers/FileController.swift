import Fluent
import Vapor

struct FileController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let api = routes.grouped("api", "files")
        let protected = api.grouped(UserPayloadAuthenticator(), UserPayload.guardMiddleware())

        // Enumerate
        protected.get(use: index)
        protected.get(":fileID", use: show)
        protected.get("recent", use: recent)
        protected.get("favorites", use: favorites)
        protected.get("shared", use: shared)
        protected.get("trash", use: trash)
        protected.get("all", use: all)

        // Upload
        protected.on(.PUT, body: .stream, use: upload)
        protected.on(.PUT, ":fileID", body: .stream, use: update)

        // Directory operations
        protected.post("create-directory", use: createDirectory)
        protected.post("move-file", use: moveFile)

        // Modify
        protected.patch(":fileID", use: rename)
        protected.post(":fileID", "favorite", use: toggleFavorite)
        protected.post(":fileID", "restore", use: restore)

        // Download
        protected.get(":fileID", "download", use: download)

        // Soft delete & permanent delete
        protected.delete(":fileID", use: delete)
        protected.delete(":fileID", "permanent-delete", use: permanentDelete)
    }

    // MARK: - Handlers

    func index(req: Request) async throws -> FileIndexDTO {
        let userID = try req.auth.require(UserPayload.self).getID()
        let parentID = try? req.query.get(UUID.self, at: "parentID")
        return try await req.storage.list(filter: .folder(id: parentID), userID: userID)
    }

    func all(req: Request) async throws -> FileIndexDTO {
        let userID = try req.auth.require(UserPayload.self).getID()
        return try await req.storage.list(filter: .all, userID: userID)
    }

    func show(req: Request) async throws -> FileMetadata {
        let userID = try req.auth.require(UserPayload.self).getID()
        let fileID = try req.parameters.require("fileID", as: UUID.self)
        return try await req.storage.getMetadata(for: fileID, userID: userID)
    }

    func favorites(req: Request) async throws -> FileIndexDTO {
        let userID = try req.auth.require(UserPayload.self).getID()
        return try await req.storage.list(filter: .favorites, userID: userID)
    }

    func trash(req: Request) async throws -> FileIndexDTO {
        let userID = try req.auth.require(UserPayload.self).getID()
        return try await req.storage.list(filter: .trash, userID: userID)
    }
    func recent(req: Request) async throws -> FileIndexDTO {
        let userID = try req.auth.require(UserPayload.self).getID()
        return try await req.storage.list(filter: .recent, userID: userID)
    }

    func shared(req: Request) async throws -> FileIndexDTO {
        let userID = try req.auth.require(UserPayload.self).getID()
        return try await req.storage.list(filter: .shared, userID: userID)
    }

    func permanentDelete(req: Request) async throws -> HTTPStatus {
        let userID = try req.auth.require(UserPayload.self).getID()
        let fileID = try req.parameters.require("fileID", as: UUID.self)

        try await req.storage.deleteRecursive(fileID: fileID, userID: userID)
        req.logger.info(
            "File permanently deleted",
            metadata: [
                "fileID": .string(fileID.uuidString),
                "userID": .string(userID.uuidString),
                "action": "permanent_delete",
            ])
        return .noContent
    }

    func upload(req: Request) async throws -> FileMetadata {
        let userID = try req.auth.require(UserPayload.self).getID()

        req.logger.info("Upload request query : \(req.url.query)")

        guard let contentLength = req.headers.first(name: .contentLength).flatMap(Int64.init),
            contentLength > 0
        else {
            throw Abort(.lengthRequired)
        }

        let metadata = try await req.storage.upload(
            filename: req.query[String.self, at: "filename"] ?? "unnamed",
            stream: req.body,
            size: contentLength,
            contentType: req.query[String.self, at: "contentType"] ?? "application/octet-stream",
            parentID: try? req.query.get(UUID.self, at: "parentID"),
            userID: userID,
            lastModified: req.query[Int64.self, at: "lastModified"]
        )

        req.logger.info(
            "File upload completed", metadata: ["fileID": .string(metadata.id?.uuidString ?? "")])
        return metadata
    }

    func createDirectory(req: Request) async throws -> FileMetadata {
        let userID = try req.auth.require(UserPayload.self).getID()
        let data = try req.content.decode(CreateDirData.self)

        let metadata = try await req.storage.createDirectory(
            name: data.name, parentID: data.parentID, userID: userID)

        req.logger.info(
            "Directory created",
            metadata: [
                "fileID": .string(metadata.id?.uuidString ?? ""),
                "userID": .string(userID.uuidString),
                "name": .string(data.name),
                "action": "create_directory",
            ])

        return metadata
    }

    func update(req: Request) async throws -> FileMetadata {
        let userID = try req.auth.require(UserPayload.self).getID()
        let fileID = try req.parameters.require("fileID", as: UUID.self)

        guard let size = req.query[Int64.self, at: "size"],
            let contentType = req.query[String.self, at: "contentType"],
            let lastModified = req.query[Int64.self, at: "lastModified"]
        else {
            throw Abort(.badRequest, reason: "Missing required query parameters")
        }

        let metadata = try await req.storage.update(
            fileID: fileID,
            stream: req.body,
            newSize: size,
            contentType: contentType,
            userID: userID,
            lastModified: lastModified
        )
        req.logger.info(
            "File updated",
            metadata: [
                "fileID": .string(fileID.uuidString),
                "userID": .string(userID.uuidString),
                "lastModified": .string(lastModified.description),
                "action": "update_file",
            ])

        return metadata
    }

    func moveFile(req: Request) async throws -> FileMetadata {
        let userID = try req.auth.require(UserPayload.self).getID()

        let input = try req.content.decode(MoveFileInput.self)

        let metadata = try await req.storage.move(
            fileID: input.fileID,
            newParentID: input.parentID,
            userID: userID
        )

        req.logger.info(
            "File moved",
            metadata: [
                "fileID": .string(input.fileID.uuidString),
                "userID": .string(userID.uuidString),
                "newParentID": .string(input.parentID?.uuidString ?? "root"),
                "action": "move_file",
            ])

        return metadata
    }

    func rename(req: Request) async throws -> FileMetadata {
        let userID = try req.auth.require(UserPayload.self).getID()
        let fileID = try req.parameters.require("fileID", as: UUID.self)

        let input = try req.content.decode(RenameInput.self)

        let metadata = try await req.storage.rename(
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

        return metadata
    }

    func download(req: Request) async throws -> Response {
        let userID = try req.auth.require(UserPayload.self).getID()
        let fileID = try req.parameters.require("fileID", as: UUID.self)

        let response = try await req.storage.getFileResponse(for: fileID, userID: userID)

        // Only attach headers if it's not a redirect (e.g., if streaming directly from provider)
        if ![.seeOther, .temporaryRedirect].contains(response.status) {
            if let metadata = try await FileMetadata.find(fileID, on: req.db) {
                response.headers.replaceOrAdd(
                    name: .contentDisposition,
                    value: "attachment; filename=\"\(metadata.filename)\"")
                response.headers.replaceOrAdd(name: .contentType, value: metadata.contentType)
            }
        }
        return response
    }

    func delete(req: Request) async throws -> HTTPStatus {
        let userID = try req.auth.require(UserPayload.self).getID()
        let fileID = try req.parameters.require("fileID", as: UUID.self)

        try await req.storage.moveToTrash(fileID: fileID, userID: userID)
        return .noContent
    }

    func restore(req: Request) async throws -> FileMetadata {
        let userID = try req.auth.require(UserPayload.self).getID()

        guard let fileID = req.parameters.get("fileID", as: UUID.self)
        else {
            throw Abort(.notFound)
        }

        return try await req.storage.restore(fileID: fileID, userID: userID)
    }

    func toggleFavorite(req: Request) async throws -> FileMetadata {
        let userID = try req.auth.require(UserPayload.self).getID()

        guard let fileID = req.parameters.get("fileID", as: UUID.self),
            let file = try await FileMetadata.query(on: req.db)
                .filter(\.$id == fileID)
                .filter(\.$owner.$id == userID)
                .first()
        else {
            throw Abort(.notFound)
        }

        // Check for specific value in body if we want to set true/false explicitly

        if let input = try? req.content.decode(ToggleFavoriteInput.self), let val = input.isFavorite
        {
            file.isFavorite = val
        } else {
            file.isFavorite.toggle()
        }

        try await file.save(on: req.db)

        req.logger.info(
            "File favorite toggled",
            metadata: [
                "fileID": .string(fileID.uuidString),
                "userID": .string(userID.uuidString),
                "isFavorite": .string("\(file.isFavorite)"),
                "action": "toggle_favorite",
            ])

        return file
    }

}
