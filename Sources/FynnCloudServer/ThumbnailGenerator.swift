import Vapor

// TODO: Rework and turn into a service
struct ThumbnailGenerator {
    static func generateThumbnail(for file: FileMetadata, at path: String, req: Request) async {
        guard file.contentType.hasPrefix("image/") else { return }

        let thumbPath = path + ".thumb.jpg"

        // Use sips to resize on macOS
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        process.arguments = ["-Z", "256", path, "--out", thumbPath]

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                continuation.resume()
            }

            do {
                try process.run()
            } catch {
                req.logger.error("Failed to generate thumbnail: \(error)")
                continuation.resume()
            }
        }
    }
}
