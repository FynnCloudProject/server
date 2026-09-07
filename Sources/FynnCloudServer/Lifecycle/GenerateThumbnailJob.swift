import Fluent
import Foundation
import Queues
import Vapor

struct ThumbnailPayload: Codable {
    let fileID: UUID
}

struct GenerateThumbnailJob: AsyncJob {
    typealias Payload = ThumbnailPayload

    /// Content types that support thumbnail generation
    private static let supportedPrefixes = ["image/", "video/", "audio/"]
    private static let supportedTypes: Set<String> = [
        "application/pdf"
    ]

    static func supports(contentType: String) -> Bool {
        supportedPrefixes.contains(where: { contentType.hasPrefix($0) })
            || supportedTypes.contains(contentType)
    }

    func dequeue(_ context: QueueContext, _ payload: ThumbnailPayload) async throws {
        let app = context.application
        let db = app.db
        let logger = context.logger.scoped(to: .storage)

        logger.debug(
            "Generating thumbnail",
            metadata: ["file_id": .stringConvertible(payload.fileID)]
        )

        guard
            let file = try await FileMetadata.query(on: db)
                .filter(\.$id == payload.fileID)
                .first()
        else {
            logger.warning(
                "Thumbnail generation skipped: file not found",
                metadata: ["file_id": .stringConvertible(payload.fileID)]
            )
            return
        }

        guard Self.supports(contentType: file.contentType) else {
            logger.debug(
                "Thumbnail generation skipped: unsupported content type",
                metadata: [
                    "file_id": .stringConvertible(payload.fileID),
                    "content_type": .string(file.contentType),
                ]
            )
            return
        }

        let tempDir = NSTemporaryDirectory()
        let ext = (file.filename as NSString).pathExtension
        let safeExt = ext.isEmpty ? "" : ".\(ext)"
        let tempFilePath = "\(tempDir)\(UUID().uuidString)\(safeExt)"
        let thumbFilePath = "\(tempDir)\(UUID().uuidString)-thumb.jpg"

        defer {
            try? FileManager.default.removeItem(atPath: tempFilePath)
            try? FileManager.default.removeItem(atPath: thumbFilePath)
        }

        let eventLoop = app.eventLoopGroup.next()
        let threadPool = app.threadPool
        let storageService = StorageService(provider: app.fileStorage, eventLoop: eventLoop)

        do {
            // Stream the source object straight to disk; the whole file is never held in RAM.
            try await storageService.downloadToFile(
                for: payload.fileID, userID: file.$owner.id, path: tempFilePath)
        } catch {
            logger.error(
                "Failed to download file for thumbnail generation",
                metadata: [
                    "file_id": .stringConvertible(payload.fileID),
                    "filename": .string(file.filename),
                    "error": .string("\(error)"),
                ]
            )
            return
        }

        // 3. Generate thumbnail off the event loop. ffmpeg / vipsthumbnail / sips all call
        //    process.waitUntilExit(), which blocks the calling thread; running it directly on a
        //    NIO event loop starves HTTP handling. The thread pool bounds concurrency to its size.
        let contentType = file.contentType
        let filename = file.filename
        let generated = try await threadPool.runIfActive(eventLoop: eventLoop) {
            Self.generateThumbnailFile(
                contentType: contentType,
                filename: filename,
                inputPath: tempFilePath,
                outputPath: thumbFilePath,
                logger: logger
            )
        }.get()

        guard generated else { return }

        guard FileManager.default.fileExists(atPath: thumbFilePath) else {
            logger.error(
                "Thumbnail file was not created",
                metadata: [
                    "file_id": .stringConvertible(payload.fileID),
                    "filename": .string(file.filename),
                ]
            )
            return
        }

        let thumbData = try await threadPool.runIfActive(eventLoop: eventLoop) {
            try Data(contentsOf: URL(fileURLWithPath: thumbFilePath))
        }.get()
        let thumbBuffer = ByteBuffer(data: thumbData)

        try await storageService.storeThumbnail(
            fileID: payload.fileID, userID: file.$owner.id, buffer: thumbBuffer)

        file.hasThumbnail = true
        try await file.save(on: db)

        logger.info(
            "Thumbnail generated",
            metadata: [
                "file_id": .stringConvertible(payload.fileID),
                "filename": .string(file.filename),
                "bytes": .stringConvertible(thumbData.count),
            ]
        )
    }

    /// Produces a JPEG thumbnail at `outputPath` from `inputPath`. Runs blocking subprocesses
    /// (`ffmpeg` for video/audio, `vipsthumbnail`/`sips` for images & PDFs) and is intended to be
    /// called on a thread pool, never directly on a NIO event loop.
    private static func generateThumbnailFile(
        contentType: String,
        filename: String,
        inputPath: String,
        outputPath: String,
        logger: Logger
    ) -> Bool {
        if contentType.hasPrefix("video/") || contentType.hasPrefix("audio/") {
            guard let ffmpegPath = findExecutable("ffmpeg") else {
                logger.error("ffmpeg not found in PATH for video/audio thumbnail generation")
                return false
            }

            let isAudio = contentType.hasPrefix("audio/")

            // For audio files, do not pass -ss so FFmpeg grabs the attached picture stream immediately
            let success = runFFmpeg(
                ffmpegPath: ffmpegPath,
                seekSeconds: isAudio ? nil : "0.5",
                inputPath: inputPath,
                outputPath: outputPath
            )

            // If 0.5s seek fails for videos (e.g. video < 0.5s long), fallback to beginning (0.0s)
            if !success && !isAudio {
                logger.debug(
                    "ffmpeg seek to 0.5s failed, retrying at 0.0s",
                    metadata: ["filename": .string(filename)]
                )
                let fallbackSuccess = runFFmpeg(
                    ffmpegPath: ffmpegPath,
                    seekSeconds: "0.0",
                    inputPath: inputPath,
                    outputPath: outputPath
                )
                guard fallbackSuccess else {
                    logger.error(
                        "ffmpeg thumbnail generation failed",
                        metadata: ["filename": .string(filename)]
                    )
                    return false
                }
            } else if !success {
                logger.debug(
                    "No cover art extracted for audio file",
                    metadata: ["filename": .string(filename)]
                )
                return false
            }
            return true
        } else {
            let process = Process()
            // Detach from the controlling terminal / parent stdio. Inheriting the server's TTY on
            // stdin causes background subprocesses to receive SIGTTIN and hang (state "T"); undrained
            // Pipe() on stdout/stderr can deadlock once the 64KB buffer fills. We discard all three.
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            if let vipsPath = findExecutable("vipsthumbnail") {
                process.executableURL = vipsPath
                process.arguments = [
                    inputPath,
                    "--size", "512x512",
                    "--output", outputPath + "[Q=80]",
                ]
            } else if let sipsPath = findExecutable("sips") {
                // Fallback for macOS development without libvips
                process.executableURL = sipsPath
                process.arguments = [
                    "-Z", "512",
                    "-s", "format", "jpeg",
                    inputPath,
                    "--out", outputPath,
                ]
            } else {
                logger.error("Neither vipsthumbnail nor sips found in PATH")
                return false
            }

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                logger.error(
                    "Failed to run thumbnail tool",
                    metadata: [
                        "filename": .string(filename),
                        "error": .string("\(error)"),
                    ]
                )
                return false
            }

            guard process.terminationStatus == 0 else {
                logger.error(
                    "Thumbnail tool exited with non-zero status",
                    metadata: [
                        "status": .stringConvertible(process.terminationStatus),
                        "filename": .string(filename),
                    ]
                )
                return false
            }
            return true
        }
    }

    private static func findExecutable(_ name: String) -> URL? {
        let searchPaths = [
            "/usr/bin",
            "/usr/local/bin",
            "/opt/homebrew/bin",
        ]
        for dir in searchPaths {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private static func runFFmpeg(
        ffmpegPath: URL, seekSeconds: String?, inputPath: String, outputPath: String
    ) -> Bool {
        let process = Process()
        process.executableURL = ffmpegPath
        // Detach from the controlling terminal / parent stdio (see note in generateThumbnailFile).
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        // -nostdin stops ffmpeg from reading the terminal, which would trigger SIGTTIN and suspend it.
        var args = ["-nostdin", "-loglevel", "error"]
        if let seek = seekSeconds {
            args.append(contentsOf: ["-ss", seek])
        }
        args.append(contentsOf: [
            "-i", inputPath,
            "-vframes", "1",
            "-vf", "scale=512:512:force_original_aspect_ratio=decrease",
            "-pix_fmt", "yuv420p",
            "-q:v", "4",
            "-f", "image2",
            "-update", "1",
            "-y",
            outputPath,
        ])
        process.arguments = args

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
                && FileManager.default.fileExists(atPath: outputPath)
        } catch {
            return false
        }
    }
}

extension GenerateThumbnailJob {
    /// Dispatches a thumbnail generation job for the given file ID if the content type supports thumbnails.
    static func dispatchIfNeeded(fileID: UUID, contentType: String, req: Request) {
        guard supports(contentType: contentType) else { return }
        Task {
            do {
                try await req.queue.dispatch(
                    GenerateThumbnailJob.self, ThumbnailPayload(fileID: fileID))
            } catch {
                req.logger(subsystem: .storage).error(
                    "Failed to dispatch thumbnail job",
                    metadata: [
                        "file_id": .stringConvertible(fileID),
                        "error": .string("\(error)"),
                    ]
                )
            }
        }
    }

    /// Dispatches a thumbnail generation job for the given FileMetadata model if applicable.
    static func dispatchIfNeeded(for file: FileMetadata, req: Request) {
        guard let fileID = file.id else { return }
        dispatchIfNeeded(fileID: fileID, contentType: file.contentType, req: req)
    }
}
