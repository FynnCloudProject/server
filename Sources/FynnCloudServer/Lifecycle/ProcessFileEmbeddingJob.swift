import Queues
import Vapor
import Fluent
import FluentSQL
import Foundation

struct FileEmbeddingPayload: Codable {
    let fileID: UUID
}

struct ProcessFileEmbeddingJob: AsyncJob {
    typealias Payload = FileEmbeddingPayload

    func dequeue(_ context: QueueContext, _ payload: FileEmbeddingPayload) async throws {
        let app = context.application
        let db = app.db
        let logger = context.logger.scoped(to: .embedding)

        let isEnabled = (try? await app.settings.get(AppSettings.EmbeddingEnabled.self)) ?? true
        guard isEnabled else {
            logger.debug(
                "Embedding generation skipped: embeddings are disabled",
                metadata: ["file_id": .stringConvertible(payload.fileID)]
            )
            return
        }

        logger.debug(
            "Processing file embedding",
            metadata: ["file_id": .stringConvertible(payload.fileID)]
        )

        guard let file = try await FileMetadata.query(on: db)
            .filter(\.$id == payload.fileID)
            .first()
        else {
            logger.warning(
                "Embedding generation skipped: file not found",
                metadata: ["file_id": .stringConvertible(payload.fileID)]
            )
            return
        }

        var extractedText = ""
        let structuredText: String
        var tempImagePath: String? = nil

        if file.isDirectory {
            structuredText = "\(file.filename) - folder, directory"
        } else {
            let typeDescription = Self.semanticTypeDescription(for: file.contentType, filename: file.filename)
            let isImage = file.contentType.hasPrefix("image/")
            let isTextOrPdf = file.contentType.hasPrefix("text/") ||
                              file.contentType == "application/pdf"

            if isImage || isTextOrPdf {
                let tempDir = NSTemporaryDirectory()
                let tempFilePath = "\(tempDir)\(UUID().uuidString)-\(file.filename)"
                logger.debug(
                    "Downloading file for embedding extraction",
                    metadata: [
                        "file_id": .stringConvertible(payload.fileID),
                        "path": .string(tempFilePath),
                    ]
                )

                do {
                    let eventLoop = app.eventLoopGroup.next()
                    let storageService = StorageService(provider: app.fileStorage, eventLoop: eventLoop)
                    let response = try await storageService.getFileResponse(for: payload.fileID, userID: file.$owner.id)
                    
                    if let buffer = try await response.body.collect(on: eventLoop).get() {
                        let data = Data(buffer.readableBytesView)
                        try data.write(to: URL(fileURLWithPath: tempFilePath))

                        if isImage {
                            // Keep image file for CLIP image embedding
                            tempImagePath = tempFilePath
                        }

                        if isTextOrPdf {
                            let extractor = TextExtractorService(logger: logger)
                            extractedText = await extractor.extractText(from: tempFilePath, contentType: file.contentType)
                        }
                    } else {
                        logger.warning(
                            "No data returned from storage provider for embedding",
                            metadata: [
                                "file_id": .stringConvertible(payload.fileID),
                                "filename": .string(file.filename),
                            ]
                        )
                    }
                } catch {
                    logger.error(
                        "Failed to download or extract text for embedding",
                        metadata: [
                            "file_id": .stringConvertible(payload.fileID),
                            "filename": .string(file.filename),
                            "error": .string("\(error)"),
                        ]
                    )
                    try? FileManager.default.removeItem(atPath: tempFilePath)
                }
            }

            if !extractedText.isEmpty {
                let textSnippet = String(extractedText.prefix(5000))
                structuredText = "\(typeDescription). \(file.filename). \(textSnippet)"
            } else {
                structuredText = "\(typeDescription). \(file.filename)"
            }
        }

        let embeddingUrl = (try? await app.settings.get(AppSettings.EmbeddingUrl.self)) ?? AppSettings.EmbeddingUrl.defaultValue
        let embeddingApiKeyRaw = try? await app.settings.get(AppSettings.EmbeddingApiKey.self)
        let embeddingApiKey = (embeddingApiKeyRaw?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? embeddingApiKeyRaw : nil)
        let embeddingModel = (try? await app.settings.get(AppSettings.EmbeddingModel.self)) ?? AppSettings.EmbeddingModel.defaultValue

        let embeddingService = EmbeddingService(
            client: app.client,
            url: embeddingUrl,
            apiKey: embeddingApiKey,
            model: embeddingModel,
            logger: logger
        )

        let embedding: [Float]
        do {
            if let imagePath = tempImagePath {
                // For images: send text + image in one request, average the vectors
                embedding = try await embeddingService.getCombinedEmbedding(text: structuredText, imageFilePath: imagePath)
            } else {
                // For non-image files: text embedding only (passage = document being indexed)
                embedding = try await embeddingService.getTextEmbedding(for: structuredText, promptName: "passage")
            }
        } catch {
            logger.error(
                "Failed to generate embedding",
                metadata: [
                    "file_id": .stringConvertible(payload.fileID),
                    "filename": .string(file.filename),
                    "error": .string("\(error)"),
                ]
            )
            if let imagePath = tempImagePath {
                try? FileManager.default.removeItem(atPath: imagePath)
            }
            return
        }

        if let imagePath = tempImagePath {
            try? FileManager.default.removeItem(atPath: imagePath)
        }

        let vectorString: String
        do {
            let data = try JSONEncoder().encode(embedding)
            vectorString = String(data: data, encoding: .utf8) ?? "[]"
        } catch {
            logger.error(
                "Failed to serialize vector",
                metadata: [
                    "file_id": .stringConvertible(payload.fileID),
                    "filename": .string(file.filename),
                    "error": .string("\(error)"),
                ]
            )
            return
        }

        if let existing = try await FileEmbedding.query(on: db).filter(\.$file.$id == payload.fileID).first() {
            existing.extractedText = extractedText
            existing.vectorData = vectorString
            try await existing.save(on: db)
        } else {
            let record = FileEmbedding(fileID: payload.fileID, extractedText: extractedText, vectorData: vectorString)
            try await record.save(on: db)
        }

        if let sql = db as? any SQLDatabase, sql.dialect.name == "postgresql" {
            let extensionCheck = try? await sql.raw("SELECT 1 FROM pg_extension WHERE extname = 'vector'").first()
            if extensionCheck != nil {
                let vectorSqlRepresentation = "[" + embedding.map { String($0) }.joined(separator: ",") + "]"
                do {
                    try await sql.raw("""
                        UPDATE file_embeddings 
                        SET embedding = \(bind: vectorSqlRepresentation)::vector 
                        WHERE file_id = \(bind: payload.fileID)
                    """).run()
                } catch {
                    logger.warning(
                        "Failed to update pgvector column",
                        metadata: [
                            "file_id": .stringConvertible(payload.fileID),
                            "error": .string("\(error)"),
                        ]
                    )
                }
            } else {
                logger.debug("pgvector extension is not installed; skipping raw vector column update")
            }
        }

        logger.info(
            "File embedding generated",
            metadata: [
                "file_id": .stringConvertible(payload.fileID),
                "filename": .string(file.filename),
            ]
        )
    }

    /// Maps content types to natural-language semantic descriptions so that
    /// searches like "music" match audio files, "photos" match images, etc.
    private static func semanticTypeDescription(for contentType: String, filename: String) -> String {
        let ext = filename.split(separator: ".").last.map(String.init)?.lowercased() ?? ""

        if contentType.hasPrefix("audio/") {
            return "audio file, music, song, sound, track"
        }
        if contentType.hasPrefix("video/") {
            return "video file, movie, clip, recording"
        }
        if contentType.hasPrefix("image/") {
            return "image file, photo, picture, graphic"
        }
        if contentType.hasPrefix("text/") {
            switch ext {
            case "md", "markdown":
                return "text file, markdown document, notes, writing"
            case "csv":
                return "text file, spreadsheet, data, table, csv"
            case "html", "htm":
                return "text file, webpage, html document"
            case "css":
                return "text file, stylesheet, css, design"
            case "js", "ts":
                return "text file, code, script, programming"
            default:
                return "text file, plain text, document, note, writing"
            }
        }
        if contentType == "application/pdf" {
            return "PDF file, document, paper, report"
        }
        if contentType.contains("spreadsheet") || contentType.contains("excel") || ext == "xlsx" || ext == "xls" {
            return "spreadsheet file, data, table, excel"
        }
        if contentType.contains("presentation") || contentType.contains("powerpoint") || ext == "pptx" || ext == "ppt" {
            return "presentation file, slides, powerpoint"
        }
        if contentType.contains("word") || ext == "docx" || ext == "doc" {
            return "Word document file, text, report"
        }
        if contentType == "application/zip" || contentType.contains("compressed") || contentType.contains("archive")
            || ["zip", "tar", "gz", "rar", "7z"].contains(ext) {
            return "archive file, compressed, zip"
        }
        if ["swift", "py", "rb", "go", "rs", "java", "kt", "c", "cpp", "h"].contains(ext) {
            return "code file, source code, programming"
        }
        return "file"
    }
}
