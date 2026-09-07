import Fluent
import Foundation
import Redis
import Vapor

/// WebDAV (RFC 4918) endpoint exposing each user's files under `/dav`. Clients authenticate
/// with HTTP Basic auth (see `WebDAVAuthenticator`). Paths are hierarchical and resolved to the
/// UUID-keyed `FileMetadata` tree per request.
struct WebDAVController: RouteCollection {
    // Character set allowed unescaped inside an href path segment.
    private static let hrefAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove("/")
        return set
    }()

    func boot(routes: any RoutesBuilder) throws {
        let dav = routes.grouped("api", "dav").grouped(WebDAVAuthenticator())

        dav.on(.OPTIONS, use: options)
        dav.on(.OPTIONS, "**", use: options)
        dav.on(.PROPFIND, use: propfind)
        dav.on(.PROPFIND, "**", use: propfind)
        dav.on(.PROPPATCH, "**", use: proppatch)
        dav.on(.GET, "**", use: get)
        dav.on(.HEAD, "**", use: get)
        dav.on(.PUT, "**", body: .stream, use: put)
        dav.on(.DELETE, "**", use: delete)
        dav.on(.MKCOL, "**", use: mkcol)
        dav.on(.MOVE, "**", use: move)
        dav.on(.COPY, "**", use: copy)
        dav.on(.LOCK, use: lock)
        dav.on(.LOCK, "**", use: lock)
        dav.on(.UNLOCK, "**", use: unlock)
    }

    // MARK: - OPTIONS

    func options(req: Request) async throws -> Response {
        let response = Response(status: .ok)
        response.headers.replaceOrAdd(name: "DAV", value: "1, 2")
        response.headers.replaceOrAdd(name: "MS-Author-Via", value: "DAV")
        response.headers.replaceOrAdd(
            name: .allow,
            value: "OPTIONS, GET, HEAD, PUT, DELETE, PROPFIND, PROPPATCH, MKCOL, COPY, MOVE, LOCK, UNLOCK")
        response.headers.replaceOrAdd(name: .contentLength, value: "0")
        return response
    }

    // MARK: - PROPFIND

    func propfind(req: Request) async throws -> Response {
        let userID = try req.auth.require(User.self).requireID()
        let segments = pathSegments(req)
        let depth = req.headers.first(name: "Depth") ?? "1"

        var entries: [DAVEntry] = []

        if segments.isEmpty {
            entries.append(DAVEntry(href: href(segments: [], isCollection: true), displayName: "/", isCollection: true, size: 0, contentType: "httpd/unix-directory", lastModified: Date(), created: nil))
            if depth != "0" {
                for child in try await req.fileService.children(ofDirectory: nil, userID: userID) {
                    entries.append(makeEntry(child, segments: [child.filename]))
                }
            }
        } else {
            guard let target = try await req.fileService.resolvePath(segments, userID: userID) else {
                throw Abort(.notFound)
            }
            entries.append(makeEntry(target, segments: segments))
            if target.isDirectory && depth != "0" {
                for child in try await req.fileService.children(ofDirectory: try target.requireID(), userID: userID) {
                    entries.append(makeEntry(child, segments: segments + [child.filename]))
                }
            }
        }

        return multistatusResponse(buildMultistatus(entries))
    }

    // MARK: - PROPPATCH

    func proppatch(req: Request) async throws -> Response {
        let userID = try req.auth.require(User.self).requireID()
        let segments = pathSegments(req)
        let target = try await req.fileService.resolvePath(segments, userID: userID)
        guard target != nil else { throw Abort(.notFound) }

        // We don't persist dead properties; acknowledge success so clients (Finder/Explorer) proceed.
        let isCollection = target?.isDirectory ?? true
        let body = """
            <?xml version="1.0" encoding="utf-8"?>
            <D:multistatus xmlns:D="DAV:"><D:response><D:href>\(escapeXML(href(segments: segments, isCollection: isCollection)))</D:href>\
            <D:propstat><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>
            """
        return multistatusResponse(body)
    }

    // MARK: - GET / HEAD

    func get(req: Request) async throws -> Response {
        let userID = try req.auth.require(User.self).requireID()
        let segments = pathSegments(req)
        guard !segments.isEmpty,
            let file = try await req.fileService.resolvePath(segments, userID: userID)
        else {
            throw Abort(.notFound)
        }
        guard !file.isDirectory else {
            throw Abort(.methodNotAllowed, reason: "Cannot GET a collection.")
        }

        let response = try await req.fileService.getFileResponse(
            for: file, userID: userID, range: req.headers.range)
        response.headers.replaceOrAdd(name: .contentType, value: file.contentType)

        if req.method == .HEAD {
            response.body = .init()
            response.headers.replaceOrAdd(name: .contentLength, value: String(file.size))
        }
        return response
    }

    // MARK: - PUT

    func put(req: Request) async throws -> Response {
        let userID = try req.auth.require(User.self).requireID()
        let segments = pathSegments(req)
        guard let filename = segments.last, !filename.isEmpty else {
            throw Abort(.badRequest)
        }

        // Finder/Explorer upload metadata sidecars (AppleDouble "._*", .DS_Store). Swallow them
        // so they never hit storage; the body must still be drained to keep the connection healthy.
        if Self.isPlatformMetadata(filename) {
            for try await _ in req.body {}
            return Response(status: .created)
        }

        // macOS's WebDAV client sends the real size in X-Expected-Entity-Length with a chunked body
        // (no Content-Length); honor it first so those uploads aren't treated as zero bytes.
        let claimedSize: Int64 =
            req.headers.first(name: "X-Expected-Entity-Length").flatMap { Int64($0) }
            ?? req.headers.first(name: .contentLength).flatMap { Int64($0) }
            ?? 0

        let contentType = req.headers.first(name: .contentType) ?? "application/octet-stream"
        let lastModifiedHeader: Int64? = req.headers.first(name: "X-OC-MTime").flatMap { Int64($0).map { $0 * 1000 } }
            ?? req.headers.first(name: "X-Last-Modified").flatMap { Int64($0) }
        let createdAtHeader: Int64? = req.headers.first(name: "X-OC-CreatedAt").flatMap { Int64($0).map { $0 * 1000 } }
            ?? req.headers.first(name: "X-Created-At").flatMap { Int64($0) }

        if let existing = try await req.fileService.resolvePath(segments, userID: userID) {
            guard !existing.isDirectory else {
                throw Abort(.methodNotAllowed, reason: "Cannot PUT over a collection.")
            }
            let metadata = try await req.fileService.update(
                fileID: try existing.requireID(), stream: req.body, claimedSize: claimedSize,
                contentType: contentType, userID: userID, lastModified: lastModifiedHeader)
            dispatchPostWriteJobs(for: metadata, req: req)
            return Response(status: .noContent)
        }

        let parentID = try await resolveParentID(req, segments: Array(segments.dropLast()), userID: userID)
        let metadata = try await req.fileService.upload(
            filename: filename, stream: req.body, claimedSize: claimedSize,
            contentType: contentType, parentID: parentID, userID: userID,
            lastModified: lastModifiedHeader, createdAt: createdAtHeader)
        dispatchPostWriteJobs(for: metadata, req: req)
        return Response(status: .created)
    }

    /// Mirrors FileController: after a write, enqueue search-embedding and thumbnail jobs.
    private func dispatchPostWriteJobs(for metadata: FileMetadata, req: Request) {
        guard let fileID = metadata.id else { return }
        Task {
            let isEnabled = (try? await req.application.settings.get(AppSettings.EmbeddingEnabled.self)) ?? true
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
        GenerateThumbnailJob.dispatchIfNeeded(for: metadata, req: req)
    }

    // MARK: - MKCOL

    func mkcol(req: Request) async throws -> Response {
        let userID = try req.auth.require(User.self).requireID()
        let segments = pathSegments(req)
        guard let name = segments.last, !name.isEmpty else { throw Abort(.badRequest) }

        if try await req.fileService.resolvePath(segments, userID: userID) != nil {
            throw Abort(.methodNotAllowed, reason: "Resource already exists.")
        }

        let parentID = try await resolveParentID(req, segments: Array(segments.dropLast()), userID: userID)
        _ = try await req.fileService.createDirectory(name: name, parentID: parentID, userID: userID)
        return Response(status: .created)
    }

    // MARK: - DELETE

    func delete(req: Request) async throws -> Response {
        let userID = try req.auth.require(User.self).requireID()
        let segments = pathSegments(req)
        guard !segments.isEmpty,
            let file = try await req.fileService.resolvePath(segments, userID: userID)
        else {
            // Never-stored metadata sidecars: report success so Finder's cleanup doesn't error.
            if let name = segments.last, Self.isPlatformMetadata(name) {
                return Response(status: .noContent)
            }
            throw Abort(.notFound)
        }
        try await req.fileService.moveToTrash(fileID: try file.requireID(), userID: userID)
        return Response(status: .noContent)
    }

    // MARK: - MOVE

    func move(req: Request) async throws -> Response {
        let userID = try req.auth.require(User.self).requireID()
        let srcSegments = pathSegments(req)
        guard !srcSegments.isEmpty,
            let source = try await req.fileService.resolvePath(srcSegments, userID: userID)
        else {
            throw Abort(.notFound)
        }

        let destSegments = try destinationSegments(req)
        guard let destName = destSegments.last, !destName.isEmpty else { throw Abort(.badRequest) }
        let overwrite = (req.headers.first(name: "Overwrite") ?? "T").uppercased() != "F"
        let destParentID = try await resolveParentID(req, segments: Array(destSegments.dropLast()), userID: userID)

        var created = true
        if let existingDest = try await req.fileService.resolvePath(destSegments, userID: userID) {
            guard overwrite else { throw Abort(.preconditionFailed) }
            try await req.fileService.deleteRecursive(fileID: try existingDest.requireID(), userID: userID)
            created = false
        }

        let sourceID = try source.requireID()
        if source.$parent.id != destParentID {
            _ = try await req.fileService.move(fileID: sourceID, newParentID: destParentID, userID: userID)
        }
        if source.filename != destName {
            _ = try await req.fileService.rename(fileID: sourceID, newName: destName, userID: userID)
        }
        return Response(status: created ? .created : .noContent)
    }

    // MARK: - COPY

    func copy(req: Request) async throws -> Response {
        let userID = try req.auth.require(User.self).requireID()
        let srcSegments = pathSegments(req)
        guard !srcSegments.isEmpty,
            let source = try await req.fileService.resolvePath(srcSegments, userID: userID)
        else {
            throw Abort(.notFound)
        }

        let destSegments = try destinationSegments(req)
        guard let destName = destSegments.last, !destName.isEmpty else { throw Abort(.badRequest) }
        let overwrite = (req.headers.first(name: "Overwrite") ?? "T").uppercased() != "F"
        let destParentID = try await resolveParentID(req, segments: Array(destSegments.dropLast()), userID: userID)

        var created = true
        if let existingDest = try await req.fileService.resolvePath(destSegments, userID: userID) {
            guard overwrite else { throw Abort(.preconditionFailed) }
            try await req.fileService.deleteRecursive(fileID: try existingDest.requireID(), userID: userID)
            created = false
        }

        _ = try await req.fileService.copyItem(
            fileID: try source.requireID(), destParentID: destParentID, newName: destName, userID: userID)
        return Response(status: created ? .created : .noContent)
    }

    // MARK: - LOCK / UNLOCK

    func lock(req: Request) async throws -> Response {
        let userID = try req.auth.require(User.self).requireID()
        let segments = pathSegments(req)
        let token = "opaquelocktoken:\(UUID().uuidString)"

        if !segments.isEmpty,
            let file = try? await req.fileService.resolvePath(segments, userID: userID)
        {
            let key = RedisKey("webdav:lock:\(try file.requireID().uuidString)")
            _ = try? await req.redis.set(key, to: token).get()
            _ = try? await req.redis.expire(key, after: .seconds(3600)).get()
        }

        let body = """
            <?xml version="1.0" encoding="utf-8"?>
            <D:prop xmlns:D="DAV:"><D:lockdiscovery><D:activelock>\
            <D:locktype><D:write/></D:locktype>\
            <D:lockscope><D:exclusive/></D:lockscope>\
            <D:depth>infinity</D:depth>\
            <D:timeout>Second-3600</D:timeout>\
            <D:locktoken><D:href>\(token)</D:href></D:locktoken>\
            </D:activelock></D:lockdiscovery></D:prop>
            """
        let response = Response(status: .ok)
        response.headers.replaceOrAdd(name: .contentType, value: "application/xml; charset=utf-8")
        response.headers.replaceOrAdd(name: "Lock-Token", value: "<\(token)>")
        response.body = .init(string: body)
        return response
    }

    func unlock(req: Request) async throws -> Response {
        let userID = try req.auth.require(User.self).requireID()
        let segments = pathSegments(req)
        if !segments.isEmpty,
            let file = try? await req.fileService.resolvePath(segments, userID: userID)
        {
            let key = RedisKey("webdav:lock:\(try file.requireID().uuidString)")
            _ = try? await req.redis.delete(key).get()
        }
        return Response(status: .noContent)
    }

    // MARK: - Helpers

    private func pathSegments(_ req: Request) -> [String] {
        req.parameters.getCatchall()
            .map { $0.removingPercentEncoding ?? $0 }
            .filter { !$0.isEmpty }
    }

    /// macOS/Windows metadata sidecars that clients create automatically and we never want to store.
    private static func isPlatformMetadata(_ name: String) -> Bool {
        if name.hasPrefix("._") { return true }
        switch name {
        case ".DS_Store", ".localized", ".metadata_never_index",
            ".Spotlight-V100", ".Trashes", ".fseventsd", ".apdisk", ".TemporaryItems",
            "Thumbs.db", "desktop.ini":
            return true
        default:
            return false
        }
    }

    /// Resolves the parent collection for a write operation. Returns nil for the root.
    /// Throws 409 Conflict when an intermediate collection is missing (per RFC 4918).
    private func resolveParentID(_ req: Request, segments: [String], userID: UUID) async throws -> UUID? {
        if segments.isEmpty { return nil }
        guard let parent = try await req.fileService.resolvePath(segments, userID: userID),
            parent.isDirectory
        else {
            throw Abort(.conflict, reason: "Parent collection does not exist.")
        }
        return try parent.requireID()
    }

    /// Parses the `Destination` header (absolute URL or path) into decoded path segments below `/dav`.
    private func destinationSegments(_ req: Request) throws -> [String] {
        guard let raw = req.headers.first(name: "Destination") else {
            throw Abort(.badRequest, reason: "Missing Destination header.")
        }
        let pathString: String
        if let url = URL(string: raw), url.host != nil {
            pathString = url.path
        } else {
            pathString = raw
        }
        var comps = pathString.split(separator: "/").map(String.init)
        if let idx = comps.firstIndex(of: "dav") {
            comps = Array(comps[(idx + 1)...])
        }
        return comps.map { $0.removingPercentEncoding ?? $0 }.filter { !$0.isEmpty }
    }

    private func makeEntry(_ file: FileMetadata, segments: [String]) -> DAVEntry {
        DAVEntry(
            href: href(segments: segments, isCollection: file.isDirectory),
            displayName: file.filename,
            isCollection: file.isDirectory,
            size: file.size,
            contentType: file.isDirectory ? "httpd/unix-directory" : file.contentType,
            lastModified: file.lastModified ?? file.updatedAt ?? file.createdAt,
            created: file.createdAt ?? file.uploadedAt ?? file.updatedAt)
    }

    private func href(segments: [String], isCollection: Bool) -> String {
        var path = "/api/dav"
        for segment in segments {
            let encoded = segment.addingPercentEncoding(withAllowedCharacters: Self.hrefAllowed) ?? segment
            path += "/" + encoded
        }
        if segments.isEmpty || isCollection { path += "/" }
        return path
    }

    private func multistatusResponse(_ body: String) -> Response {
        let response = Response(status: HTTPResponseStatus(statusCode: 207, reasonPhrase: "Multi-Status"))
        response.headers.replaceOrAdd(name: .contentType, value: "application/xml; charset=utf-8")
        response.body = .init(string: body)
        return response
    }

    private func buildMultistatus(_ entries: [DAVEntry]) -> String {
        let httpDate = Self.makeHTTPDateFormatter()
        let iso = ISO8601DateFormatter()

        var xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<D:multistatus xmlns:D=\"DAV:\">\n"
        for entry in entries {
            xml += "<D:response><D:href>\(escapeXML(entry.href))</D:href><D:propstat><D:prop>"
            xml += "<D:displayname>\(escapeXML(entry.displayName))</D:displayname>"
            if let modified = entry.lastModified {
                xml += "<D:getlastmodified>\(httpDate.string(from: modified))</D:getlastmodified>"
            }
            if let created = entry.created {
                xml += "<D:creationdate>\(iso.string(from: created))</D:creationdate>"
            }
            if entry.isCollection {
                xml += "<D:resourcetype><D:collection/></D:resourcetype>"
            } else {
                xml += "<D:resourcetype/>"
                xml += "<D:getcontentlength>\(entry.size)</D:getcontentlength>"
                xml += "<D:getcontenttype>\(escapeXML(entry.contentType))</D:getcontenttype>"
            }
            xml += "</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>\n"
        }
        xml += "</D:multistatus>"
        return xml
    }

    private func escapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func makeHTTPDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }
}

private struct DAVEntry {
    let href: String
    let displayName: String
    let isCollection: Bool
    let size: Int64
    let contentType: String
    let lastModified: Date?
    let created: Date?
}
