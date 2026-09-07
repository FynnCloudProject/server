import Foundation
import NIOCore
import Vapor

enum AvatarProcessor {
    /// Resizes and crops an uploaded avatar buffer to a square 256x256 JPEG image.
    /// Strips EXIF metadata and normalizes image quality.
    static func process(buffer: ByteBuffer) async throws -> ByteBuffer {
        let tempDir = FileManager.default.temporaryDirectory
        let inputPath = tempDir.appendingPathComponent("avatar_in_\(UUID().uuidString).tmp").path
        let outputPath = tempDir.appendingPathComponent("avatar_out_\(UUID().uuidString).jpg").path

        defer {
            try? FileManager.default.removeItem(atPath: inputPath)
            try? FileManager.default.removeItem(atPath: outputPath)
        }

        let data = Data(buffer.readableBytesView)
        try data.write(to: URL(fileURLWithPath: inputPath))

        let process = Process()

        if let vipsPath = findExecutable("vipsthumbnail") {
            process.executableURL = vipsPath
            process.arguments = [
                inputPath,
                "--size", "256x256",
                "--crop",
                "--output", outputPath + "[Q=85]"
            ]
        } else if let sipsPath = findExecutable("sips") {
            process.executableURL = sipsPath
            process.arguments = [
                "-Z", "256",
                "-s", "format", "jpeg",
                inputPath,
                "--out", outputPath
            ]
        } else {
            // Return raw buffer if no image processing tool is available
            return buffer
        }

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return buffer
        }

        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: outputPath) else {
            return buffer
        }

        let processedData = try Data(contentsOf: URL(fileURLWithPath: outputPath))
        return ByteBuffer(data: processedData)
    }

    private static func findExecutable(_ name: String) -> URL? {
        let pathEnv = ProcessInfo.processInfo.environment["PATH"]
            ?? "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        for searchPath in pathEnv.components(separatedBy: ":") {
            let candidate = URL(fileURLWithPath: searchPath).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
