import Foundation
import NIOCore
import Vapor

enum SVGProcessor {
    /// Sanitizes an uploaded SVG XML buffer to prevent XSS (strips scripts, event handlers, javascript URIs, XXE).
    static func sanitize(buffer: ByteBuffer) throws -> ByteBuffer {
        guard let rawString = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) else {
            throw Abort(.badRequest, reason: "Invalid SVG: not valid UTF-8 text.")
        }

        // Quick check that it looks like an SVG
        guard rawString.localizedCaseInsensitiveContains("<svg") else {
            throw Abort(.badRequest, reason: "Invalid SVG: missing <svg> element.")
        }

        var sanitized = rawString

        // 1. Remove XML DOCTYPE and ENTITY declarations (XXE protection)
        sanitized = sanitized.replacingOccurrences(
            of: "<!DOCTYPE[^>]*(\\[[\\s\\S]*?\\])?>",
            with: "",
            options: .regularExpression
        )
        sanitized = sanitized.replacingOccurrences(
            of: "<!ENTITY[^>]*>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // 2. Strip <script> ... </script> and self-closing <script ... />
        sanitized = sanitized.replacingOccurrences(
            of: "<script[\\s\\S]*?>[\\s\\S]*?<\\/script>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        sanitized = sanitized.replacingOccurrences(
            of: "<script[^>]*\\/>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // 3. Strip all inline on* event handlers (onload, onclick, onerror, onmouseover, etc.)
        sanitized = sanitized.replacingOccurrences(
            of: "\\s+on[a-zA-Z]+\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // 4. Strip dangerous javascript: and data: text/html in href/xlink:href attributes
        sanitized = sanitized.replacingOccurrences(
            of: "(href|xlink:href)\\s*=\\s*[\"']\\s*javascript:[^\"']*[\"']",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        sanitized = sanitized.replacingOccurrences(
            of: "(href|xlink:href)\\s*=\\s*[\"']\\s*data:\\s*text\\/html[^\"']*[\"']",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // 5. Strip <foreignObject> ... </foreignObject> which can embed arbitrary HTML
        sanitized = sanitized.replacingOccurrences(
            of: "<foreignObject[\\s\\S]*?>[\\s\\S]*?<\\/foreignObject>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        sanitized = sanitized.replacingOccurrences(
            of: "<foreignObject[^>]*\\/>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        guard let data = sanitized.data(using: .utf8) else {
            throw Abort(.badRequest, reason: "Failed to encode sanitized SVG.")
        }

        return ByteBuffer(data: data)
    }
}
