import Foundation
import NIOCore
import Vapor

/// Loads initial document templates from bundled resources or the filesystem (`Resources/templates/`).
enum FileTemplates: Sendable {
    /// Template filename for each `NewFileType`.
    static func filename(for type: NewFileType) -> String? {
        switch type {
        case .document: return "empty.docx"
        case .spreadsheet: return "empty.xlsx"
        case .presentation: return "empty.pptx"
        case .text: return nil
        }
    }

    /// Loads the raw Data for a template file from the resource bundle or filesystem.
    static func loadTemplateData(for type: NewFileType) throws -> Data {
        guard let filename = filename(for: type) else {
            return Data()
        }

        if let bundleURL = Bundle.module.url(forResource: filename, withExtension: nil, subdirectory: "templates") ??
                           Bundle.module.url(forResource: filename, withExtension: nil),
           let data = try? Data(contentsOf: bundleURL) {
            return data
        }

        let candidates = [
            "Resources/templates/\(filename)",
            "./Resources/templates/\(filename)",
            "/app/Resources/templates/\(filename)"
        ]
        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate),
               let data = try? Data(contentsOf: URL(fileURLWithPath: candidate)) {
                return data
            }
        }

        throw Abort(.internalServerError, reason: "Template file '\(filename)' not found.")
    }

    /// Returns the initial template ByteBuffer for the specified `NewFileType`.
    static func templateBuffer(for type: NewFileType) throws -> ByteBuffer {
        let data = try loadTemplateData(for: type)
        return ByteBuffer(data: data)
    }
}
