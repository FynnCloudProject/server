import Foundation
import Fluent
import FluentSQL
import SQLKit

struct AddAncestorIDsToFileMetadata: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("file_metadata")
            .field("ancestor_ids", .array(of: .uuid), .required, .sql(.default(SQLRaw("'{}'"))))
            .update()

        if let sql = database as? any SQLDatabase {
            if sql.dialect.name == "postgresql" {
                try await sql.raw("""
                    WITH RECURSIVE file_ancestors AS (
                        SELECT id, ARRAY[]::uuid[] AS ancestor_ids
                        FROM file_metadata
                        WHERE parent_id IS NULL
                        UNION ALL
                        SELECT f.id, fa.ancestor_ids || f.parent_id
                        FROM file_metadata f
                        JOIN file_ancestors fa ON f.parent_id = fa.id
                    )
                    UPDATE file_metadata f
                    SET ancestor_ids = fa.ancestor_ids
                    FROM file_ancestors fa
                    WHERE f.id = fa.id;
                    """).run()
            } else {
                struct FileNode: Decodable {
                    let id: UUID
                    let parent_id: UUID?
                }
                let allFiles = try await sql.raw("SELECT id, parent_id FROM file_metadata").all(decoding: FileNode.self)
                var ancestorMap: [UUID: [UUID]] = [:]

                let fileMap = Dictionary(uniqueKeysWithValues: allFiles.map { ($0.id, $0) })

                func getAncestors(for file: FileNode) -> [UUID] {
                    if let cached = ancestorMap[file.id] {
                        return cached
                    }
                    guard let parentID = file.parent_id, let parent = fileMap[parentID] else {
                        ancestorMap[file.id] = []
                        return []
                    }
                    let parentAncestors = getAncestors(for: parent)
                    let result = parentAncestors + [parentID]
                    ancestorMap[file.id] = result
                    return result
                }

                for file in allFiles {
                    let ancestors = getAncestors(for: file)
                    let jsonArray = try JSONEncoder().encode(ancestors)
                    let jsonString = String(data: jsonArray, encoding: .utf8) ?? "[]"
                    try await sql.raw("UPDATE file_metadata SET ancestor_ids = \(bind: jsonString) WHERE id = \(bind: file.id)").run()
                }
            }
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema("file_metadata")
            .deleteField("ancestor_ids")
            .update()
    }
}
