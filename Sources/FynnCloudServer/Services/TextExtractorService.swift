import Vapor
import Foundation

struct TextExtractorService: Sendable {
    let logger: Logger

    func extractText(from filePath: String, contentType: String) async -> String {
        let trimmedType = contentType.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let log = logger.scoped(to: .embedding)

        if trimmedType.hasPrefix("text/") || trimmedType == "application/json" || trimmedType == "application/javascript" {
            do {
                let content = try String(contentsOfFile: filePath, encoding: .utf8)
                return content.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                log.error(
                    "Failed to read text file for text extraction",
                    metadata: [
                        "path": .string(filePath),
                        "error": .string("\(error)"),
                    ]
                )
                return ""
            }
        }

        if trimmedType == "application/pdf" {
            if let pdftotextPath = Self.findExecutable(named: "pdftotext") {
                log.debug(
                    "Extracting text from PDF via pdftotext",
                    metadata: ["executable": .string(pdftotextPath)]
                )
                let rawText = await Self.runCommand(executable: pdftotextPath, arguments: [filePath, "-"], logger: log)
                return rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                log.debug("pdftotext is not installed; skipping PDF text extraction")
                return ""
            }
        }

        if trimmedType.hasPrefix("image/") {
            if let tesseractPath = Self.findExecutable(named: "tesseract") {
                log.debug(
                    "Performing OCR on image via tesseract",
                    metadata: ["executable": .string(tesseractPath)]
                )
                // Arguments: input_file output_base (stdout base prints directly to standard output)
                let rawText = await Self.runCommand(executable: tesseractPath, arguments: [filePath, "stdout"], logger: log)
                return rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                log.debug("tesseract is not installed; skipping OCR extraction")
                return ""
            }
        }

        return ""
    }

    // MARK: - Subprocess execution helpers

    private static func findExecutable(named name: String) -> String? {
        let paths = [
            "/usr/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/bin/\(name)"
        ]
        let fileManager = FileManager.default
        for path in paths {
            if fileManager.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    private static func runCommand(executable: String, arguments: [String], logger: Logger) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe() // Silence logs from stderr of command

        return await withCheckedContinuation { continuation in
            do {
                process.terminationHandler = { _ in
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(returning: output)
                }
                try process.run()
            } catch {
                logger.error(
                    "Failed to execute extraction process",
                    metadata: [
                        "executable": .string(executable),
                        "error": .string("\(error)"),
                    ]
                )
                continuation.resume(returning: "")
            }
        }
    }
}

extension Request {
    var textExtractor: TextExtractorService {
        TextExtractorService(logger: self.logger)
    }
}
