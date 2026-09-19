import Foundation
import Logging
import Vapor

/// A `MailService` driver that writes outgoing emails to the application log.
/// Useful for development environments where an active SMTP relay is not configured.
public struct LogMailService: MailService, Sendable {
    public let logger: Logger

    public init(logger: Logger) {
        self.logger = logger
    }

    public func send(_ email: Email) async throws {
        var metadata: Logger.Metadata = [
            "email_id": .string(email.id.uuidString),
            "subject": .string(email.subject),
            "to": .array(email.to.map { .string($0.description) }),
        ]

        if let from = email.from {
            metadata["from"] = .string(from.description)
        }
        if !email.cc.isEmpty {
            metadata["cc"] = .array(email.cc.map { .string($0.description) })
        }
        if !email.bcc.isEmpty {
            metadata["bcc"] = .array(email.bcc.map { .string($0.description) })
        }
        if !email.attachments.isEmpty {
            metadata["attachments"] = .array(email.attachments.map { .string("\($0.filename) (\($0.data.count) bytes)") })
        }

        let bodyPreview: String
        switch email.body {
        case .plain(let text):
            bodyPreview = text
        case .html(let html):
            bodyPreview = "[HTML content, \(html.count) characters]"
        case .both(let plain, _):
            bodyPreview = plain
        }

        logger.info(
            "Delivered email via LogMailService: '\(email.subject)' to [\(email.to.map(\.description).joined(separator: ", "))]",
            metadata: metadata
        )
        logger.debug("Email body preview:\n\(bodyPreview)")
    }
}
