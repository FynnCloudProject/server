import Foundation

// MARK: - Email Address

/// Represents an email address with an optional display name.
public struct EmailAddress: Codable, Sendable, Hashable, Equatable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let name: String?
    public let address: String

    public init(address: String, name: String? = nil) {
        self.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = (trimmedName?.isEmpty == false) ? trimmedName : nil
    }

    /// Parses an address from string literal format:
    /// `"john@example.com"` or `"John Doe <john@example.com>"`
    public init(stringLiteral value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let openAngle = trimmed.firstIndex(of: "<"),
           let closeAngle = trimmed.lastIndex(of: ">"),
           openAngle < closeAngle {
            let namePart = trimmed[..<openAngle].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let emailPart = trimmed[trimmed.index(after: openAngle)..<closeAngle].trimmingCharacters(in: .whitespacesAndNewlines)
            self.init(address: emailPart, name: namePart.isEmpty ? nil : namePart)
        } else {
            self.init(address: trimmed, name: nil)
        }
    }

    /// Formatted RFC 5322 representation (e.g. `"John Doe <john@example.com>"` or `"john@example.com"`).
    public var description: String {
        if let name = name, !name.isEmpty {
            // If the name contains specials or commas, quote it
            if name.contains(",") || name.contains("\"") || name.contains("<") || name.contains(">") {
                let escaped = name.replacingOccurrences(of: "\"", with: "\\\"")
                return "\"\(escaped)\" <\(address)>"
            }
            return "\(name) <\(address)>"
        }
        return address
    }
}

// MARK: - Email Body

/// Content of an email message.
public enum EmailBody: Codable, Sendable, Equatable {
    case plain(String)
    case html(String)
    case both(plain: String, html: String)

    public var plainText: String? {
        switch self {
        case .plain(let text):
            return text
        case .html:
            return nil
        case .both(let plain, _):
            return plain
        }
    }

    public var html: String? {
        switch self {
        case .plain:
            return nil
        case .html(let html):
            return html
        case .both(_, let html):
            return html
        }
    }
}

// MARK: - Email Attachment

/// A file attachment to an email message.
public struct EmailAttachment: Codable, Sendable, Equatable {
    public let filename: String
    public let contentType: String
    public let data: Data
    public let contentID: String?

    public init(
        filename: String,
        contentType: String,
        data: Data,
        contentID: String? = nil
    ) {
        self.filename = filename
        self.contentType = contentType
        self.data = data
        self.contentID = contentID
    }
}

// MARK: - Email Message

/// A complete email message ready to be sent.
public struct Email: Codable, Sendable, Equatable {
    public let id: UUID
    public var from: EmailAddress?
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    public var replyTo: [EmailAddress]
    public var subject: String
    public var body: EmailBody
    public var attachments: [EmailAttachment]
    public var headers: [String: String]

    public init(
        id: UUID = UUID(),
        from: EmailAddress? = nil,
        to: [EmailAddress],
        cc: [EmailAddress] = [],
        bcc: [EmailAddress] = [],
        replyTo: [EmailAddress] = [],
        subject: String,
        body: EmailBody,
        attachments: [EmailAttachment] = [],
        headers: [String: String] = [:]
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.replyTo = replyTo
        self.subject = subject
        self.body = body
        self.attachments = attachments
        self.headers = headers
    }

    public init(
        id: UUID = UUID(),
        from: EmailAddress? = nil,
        to: EmailAddress,
        cc: [EmailAddress] = [],
        bcc: [EmailAddress] = [],
        replyTo: [EmailAddress] = [],
        subject: String,
        body: EmailBody,
        attachments: [EmailAttachment] = [],
        headers: [String: String] = [:]
    ) {
        self.init(
            id: id,
            from: from,
            to: [to],
            cc: cc,
            bcc: bcc,
            replyTo: replyTo,
            subject: subject,
            body: body,
            attachments: attachments,
            headers: headers
        )
    }

    /// Convenience initializer for a plain text email.
    public init(
        id: UUID = UUID(),
        from: EmailAddress? = nil,
        to: EmailAddress,
        subject: String,
        text: String,
        attachments: [EmailAttachment] = []
    ) {
        self.init(
            id: id,
            from: from,
            to: [to],
            subject: subject,
            body: .plain(text),
            attachments: attachments
        )
    }

    /// Convenience initializer for an HTML email with optional plain text fallback.
    public init(
        id: UUID = UUID(),
        from: EmailAddress? = nil,
        to: EmailAddress,
        subject: String,
        html: String,
        text: String? = nil,
        attachments: [EmailAttachment] = []
    ) {
        let body: EmailBody
        if let text = text {
            body = .both(plain: text, html: html)
        } else {
            body = .html(html)
        }
        self.init(
            id: id,
            from: from,
            to: [to],
            subject: subject,
            body: body,
            attachments: attachments
        )
    }

    /// Convenience initializer for a plain text email with optional cc, bcc, and headers.
    public init(
        id: UUID = UUID(),
        from: EmailAddress? = nil,
        to: [EmailAddress],
        cc: [EmailAddress] = [],
        bcc: [EmailAddress] = [],
        replyTo: [EmailAddress] = [],
        subject: String,
        text: String,
        attachments: [EmailAttachment] = [],
        headers: [String: String] = [:]
    ) {
        self.init(
            id: id,
            from: from,
            to: to,
            cc: cc,
            bcc: bcc,
            replyTo: replyTo,
            subject: subject,
            body: .plain(text),
            attachments: attachments,
            headers: headers
        )
    }

    /// Convenience initializer for an HTML email with optional cc, bcc, plain text fallback, and headers.
    public init(
        id: UUID = UUID(),
        from: EmailAddress? = nil,
        to: [EmailAddress],
        cc: [EmailAddress] = [],
        bcc: [EmailAddress] = [],
        replyTo: [EmailAddress] = [],
        subject: String,
        html: String,
        text: String? = nil,
        attachments: [EmailAttachment] = [],
        headers: [String: String] = [:]
    ) {
        let body: EmailBody
        if let text = text {
            body = .both(plain: text, html: html)
        } else {
            body = .html(html)
        }
        self.init(
            id: id,
            from: from,
            to: to,
            cc: cc,
            bcc: bcc,
            replyTo: replyTo,
            subject: subject,
            body: body,
            attachments: attachments,
            headers: headers
        )
    }

    /// Convenience initializer for a single-recipient plain text email with optional cc, bcc, and headers.
    public init(
        id: UUID = UUID(),
        from: EmailAddress? = nil,
        to: EmailAddress,
        cc: [EmailAddress] = [],
        bcc: [EmailAddress] = [],
        replyTo: [EmailAddress] = [],
        subject: String,
        text: String,
        attachments: [EmailAttachment] = [],
        headers: [String: String] = [:]
    ) {
        self.init(
            id: id,
            from: from,
            to: [to],
            cc: cc,
            bcc: bcc,
            replyTo: replyTo,
            subject: subject,
            text: text,
            attachments: attachments,
            headers: headers
        )
    }

    /// Convenience initializer for a single-recipient HTML email with optional cc, bcc, plain text fallback, and headers.
    public init(
        id: UUID = UUID(),
        from: EmailAddress? = nil,
        to: EmailAddress,
        cc: [EmailAddress] = [],
        bcc: [EmailAddress] = [],
        replyTo: [EmailAddress] = [],
        subject: String,
        html: String,
        text: String? = nil,
        attachments: [EmailAttachment] = [],
        headers: [String: String] = [:]
    ) {
        self.init(
            id: id,
            from: from,
            to: [to],
            cc: cc,
            bcc: bcc,
            replyTo: replyTo,
            subject: subject,
            html: html,
            text: text,
            attachments: attachments,
            headers: headers
        )
    }
}
