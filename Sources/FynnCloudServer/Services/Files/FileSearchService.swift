import Fluent
import FluentSQL
import SQLKit
import Vapor

/// Filename and semantic (pgvector) search over a user's own files.
struct FileSearchService: Sendable {
    /// Upper bound (in seconds) for the query-embedding request. Keeps search responsive by
    /// falling back to filename matching quickly when the embedding service is slow or unreachable.
    static let embeddingTimeout: TimeInterval = 3

    /// Trigram score below which a filename is not considered a fuzzy match.
    static let filenameSimilarityThreshold = 0.15

    enum SearchMode: String, Sendable {
        case filename
        case semantic
    }

    let context: FileServiceContext

    init(_ context: FileServiceContext) { self.context = context }

    private var db: any Database { context.db }
    private var logger: Logger { context.logger }
    private var embeddingService: EmbeddingService? { context.embedding }
    private var semanticSearchThreshold: Double { context.semanticSearchThreshold }

    /// reaches the SQL string itself.
    private func filenameLikePatterns(for query: String) -> [String] {
        let tokens = query.components(separatedBy: .whitespacesAndNewlines).filter { $0.count >= 2 }
        guard !tokens.isEmpty else { return ["%\(query)%"] }
        return tokens.map { "%\($0)%" }
    }

    // MARK: - Search

    func search(
        query: String,
        userID: UUID,
        window: PageRequest = PageRequest(limit: 50),
        mode: SearchMode? = nil
    ) async throws -> FileIndexDTO {
        let sql = try context.requireSQL()

        let sanitizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitizedQuery.isEmpty else {
            return FileIndexDTO(
                files: [], parentID: nil, breadcrumbs: [Breadcrumb.search], totalCount: 0, hasMore: false)
        }

        let offset = window.offset
        // A nil limit means "whole result set" (same contract as `list`). Both values are Ints, so
        // interpolating them raw can't inject.
        let pageClause = window.limit.map { "LIMIT \($0) OFFSET \(offset)" } ?? ""

        let useFilename = mode == nil || mode == .filename
        let useSemantic = (mode == nil || mode == .semantic) && embeddingService != nil

        let matches: (files: [FileMetadata], totalCount: Int)
        if useFilename && useSemantic, let embeddingService {
            // Without an embedding the hybrid ranking has nothing to add, so fall back to names.
            let embedding = (try? await embeddingService.getTextEmbedding(
                for: sanitizedQuery, timeout: Self.embeddingTimeout)) ?? []
            if embedding.isEmpty {
                logger.scoped(to: .embedding).error(
                    "Failed to generate query embedding for search, falling back to filenames",
                    metadata: ["query_length": .stringConvertible(sanitizedQuery.count)])
                matches = try await matchFilenames(
                    sql: sql, userID: userID, query: sanitizedQuery, pageClause: pageClause)
            } else {
                matches = try await matchFilenamesOrEmbedding(
                    sql: sql, userID: userID, query: sanitizedQuery, embedding: embedding,
                    pageClause: pageClause)
            }
        } else if useSemantic, let embeddingService {
            let embedding: [Float]
            do {
                embedding = try await embeddingService.getTextEmbedding(
                    for: sanitizedQuery, timeout: Self.embeddingTimeout)
            } catch {
                logger.scoped(to: .embedding).error(
                    "Failed to generate query embedding for semantic search",
                    metadata: ["error": .string("\(error)")]
                )
                throw Abort(.internalServerError, reason: "Failed to generate query embedding")
            }
            matches = try await matchEmbedding(
                sql: sql, userID: userID, embedding: embedding, pageClause: pageClause)
        } else {
            matches = try await matchFilenames(
                sql: sql, userID: userID, query: sanitizedQuery, pageClause: pageClause)
        }

        let files = matches.files
        let totalCount = matches.totalCount

        let fileIDs = files.compactMap { $0.id }
        let pathsByID = try await resolvePaths(sql: sql, fileIDs: fileIDs)
        let userFavoriteIDs = try await UserFavorite.ids(
            among: fileIDs, userID: userID, on: db)

        let fileDTOs = files.map { file -> FileIndexItemDTO in
            let path = file.id.flatMap { pathsByID[$0] }
            let isFav = file.id.map { userFavoriteIDs.contains($0) } ?? false
            return FileIndexItemDTO(from: file, isFavorite: isFav, path: path)
        }

        return FileIndexDTO(
            files: fileDTOs,
            parentID: nil,
            breadcrumbs: [Breadcrumb.search],
            // An unlimited request returned everything, so the rows themselves are the true count.
            totalCount: window.limit == nil ? files.count : totalCount,
            hasMore: window.limit != nil && offset + files.count < totalCount
        )
    }

    /// Exact substring beats per-word match beats trigram similarity.
    private func matchFilenames(
        sql: any SQLDatabase, userID: UUID, query: String, pageClause: String
    ) async throws -> (files: [FileMetadata], totalCount: Int) {
        let likePattern = "%\(query)%"
        let tokenPatterns = filenameLikePatterns(for: query)
        let minSimilarity = Self.filenameSimilarityThreshold

        let countRow = try await sql.raw("""
            SELECT COUNT(*) as count FROM file_metadata f
            WHERE f.owner_id = \(bind: userID) AND f.deleted_at IS NULL
            AND (f.filename ILIKE \(bind: likePattern) OR f.filename ILIKE ANY(\(bind: tokenPatterns)) OR similarity(f.filename, \(bind: query)) > \(bind: minSimilarity))
        """).first()

        let files = try await sql.raw("""
            SELECT f.* FROM file_metadata f
            WHERE f.owner_id = \(bind: userID) AND f.deleted_at IS NULL
            AND (f.filename ILIKE \(bind: likePattern) OR f.filename ILIKE ANY(\(bind: tokenPatterns)) OR similarity(f.filename, \(bind: query)) > \(bind: minSimilarity))
            ORDER BY 
                CASE 
                    WHEN f.filename ILIKE \(bind: likePattern) THEN 0.0
                    ELSE (1.0 - similarity(f.filename, \(bind: query)))
                END ASC,
                f.filename ASC
            \(unsafeRaw: pageClause)
        """).all(decodingFluent: FileMetadata.self)

        return (files, try countRow?.decode(column: "count", as: Int.self) ?? 0)
    }

    /// Nearest neighbours by cosine distance over the file embeddings.
    private func matchEmbedding(
        sql: any SQLDatabase, userID: UUID, embedding: [Float], pageClause: String
    ) async throws -> (files: [FileMetadata], totalCount: Int) {
        let vector = vectorLiteral(embedding)

        let countRow = try await sql.raw("""
            SELECT COUNT(*) as count FROM file_metadata f
            JOIN file_embeddings e ON e.file_id = f.id
            WHERE f.owner_id = \(bind: userID) AND f.deleted_at IS NULL
            AND e.embedding IS NOT NULL
            AND (e.embedding <=> \(bind: vector)::vector) < \(bind: semanticSearchThreshold)
        """).first()

        let files = try await sql.raw("""
            SELECT f.* FROM file_metadata f
            JOIN file_embeddings e ON e.file_id = f.id
            WHERE f.owner_id = \(bind: userID) AND f.deleted_at IS NULL
            AND e.embedding IS NOT NULL
            AND (e.embedding <=> \(bind: vector)::vector) < \(bind: semanticSearchThreshold)
            ORDER BY e.embedding <=> \(bind: vector)::vector ASC, f.filename ASC
            \(unsafeRaw: pageClause)
        """).all(decodingFluent: FileMetadata.self)

        return (files, try countRow?.decode(column: "count", as: Int.self) ?? 0)
    }

    /// Union of both matchers, ranked so a filename hit always outranks a semantic one.
    private func matchFilenamesOrEmbedding(
        sql: any SQLDatabase, userID: UUID, query: String, embedding: [Float], pageClause: String
    ) async throws -> (files: [FileMetadata], totalCount: Int) {
        let likePattern = "%\(query)%"
        let tokenPatterns = filenameLikePatterns(for: query)
        let vector = vectorLiteral(embedding)
        let maxDistance = semanticSearchThreshold
        let minSimilarity = Self.filenameSimilarityThreshold

        let countRow = try await sql.raw("""
            SELECT COUNT(*) as count FROM (
                SELECT f.id FROM file_metadata f
                WHERE f.owner_id = \(bind: userID) AND f.deleted_at IS NULL
                AND (f.filename ILIKE \(bind: likePattern) OR f.filename ILIKE ANY(\(bind: tokenPatterns)) OR similarity(f.filename, \(bind: query)) > \(bind: minSimilarity))
                UNION
                SELECT f.id FROM file_metadata f
                JOIN file_embeddings e ON e.file_id = f.id
                WHERE f.owner_id = \(bind: userID) AND f.deleted_at IS NULL
                AND e.embedding IS NOT NULL
                AND (e.embedding <=> \(bind: vector)::vector) < \(bind: maxDistance)
            ) combined
        """).first()

        let files = try await sql.raw("""
            SELECT f.* FROM (
                SELECT id, MIN(rank) as best_rank FROM (
                    SELECT f.id, (
                        CASE 
                            WHEN f.filename ILIKE \(bind: likePattern) THEN 0.0
                            ELSE (0.2 - (similarity(f.filename, \(bind: query)) * 0.2))
                        END
                    ) as rank FROM file_metadata f
                    WHERE f.owner_id = \(bind: userID) AND f.deleted_at IS NULL
                    AND (f.filename ILIKE \(bind: likePattern) OR f.filename ILIKE ANY(\(bind: tokenPatterns)) OR similarity(f.filename, \(bind: query)) > \(bind: minSimilarity))
                    UNION ALL
                    SELECT f.id, (e.embedding <=> \(bind: vector)::vector) as rank
                    FROM file_metadata f
                    JOIN file_embeddings e ON e.file_id = f.id
                    WHERE f.owner_id = \(bind: userID) AND f.deleted_at IS NULL
                    AND e.embedding IS NOT NULL
                    AND (e.embedding <=> \(bind: vector)::vector) < \(bind: maxDistance)
                ) all_results
                GROUP BY id
            ) ranked
            JOIN file_metadata f ON f.id = ranked.id
            ORDER BY ranked.best_rank ASC, f.filename ASC
            \(unsafeRaw: pageClause)
        """).all(decodingFluent: FileMetadata.self)

        return (files, try countRow?.decode(column: "count", as: Int.self) ?? 0)
    }

    /// pgvector takes its input as a `[1,2,3]` text literal, bound and cast at the call site.
    private func vectorLiteral(_ embedding: [Float]) -> String {
        "[" + embedding.map { String($0) }.joined(separator: ",") + "]"
    }

    /// Full `/a/b` path of each hit, walked up from the file to its root folder.
    private func resolvePaths(sql: any SQLDatabase, fileIDs: [UUID]) async throws -> [UUID: String] {
        guard !fileIDs.isEmpty else { return [:] }

        let pathResults = try await sql.raw("""
            WITH RECURSIVE path_builder AS (
                SELECT id, parent_id, filename, CAST(filename AS text) as path_string, id as origin_id
                FROM file_metadata
                WHERE id = ANY(\(bind: fileIDs))
                
                UNION ALL
                
                SELECT f.id, f.parent_id, f.filename, 
                       f.filename || '/' || pb.path_string as path_string,
                       pb.origin_id
                FROM file_metadata f
                INNER JOIN path_builder pb ON pb.parent_id = f.id
            )
            SELECT origin_id as "originId", path_string as "pathString" 
            FROM path_builder 
            WHERE parent_id IS NULL;
        """).all()

        var pathsByID: [UUID: String] = [:]
        for row in pathResults {
            if let originID = try? row.decode(column: "originId", as: UUID.self),
               let pathString = try? row.decode(column: "pathString", as: String.self) {
                var parts = pathString.split(separator: "/")
                if !parts.isEmpty {
                    parts.removeLast()
                }
                pathsByID[originID] = "/" + parts.joined(separator: "/")
            }
        }
        return pathsByID
    }
}
