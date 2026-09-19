import Foundation
import Logging
import NIOCore
import SwiftSMTP
import Vapor

// MARK: - SMTP Configuration

public struct SMTPConfiguration: Sendable, Codable, Equatable {
    public enum Encryption: String, Sendable, Codable, Equatable {
        case none
        case starttls
        case ssl
    }

    public var host: String
    public var port: Int
    public var username: String?
    public var password: String?
    public var encryption: Encryption
    public var defaultFrom: EmailAddress?
    public var clientHostname: String
    public var timeoutSeconds: Int

    public init(
        host: String,
        port: Int = 587,
        username: String? = nil,
        password: String? = nil,
        encryption: Encryption = .starttls,
        defaultFrom: EmailAddress? = nil,
        clientHostname: String = "localhost",
        timeoutSeconds: Int = 30
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.encryption = encryption
        self.defaultFrom = defaultFrom
        self.clientHostname = clientHostname
        self.timeoutSeconds = timeoutSeconds
    }
}

// MARK: - SMTP Errors

public enum SMTPError: Error, CustomStringConvertible, Sendable {
    case connectionClosed
    case timeout
    case commandFailed(code: Int, message: String)
    case starttlsFailed(message: String)
    case authenticationFailed(message: String)
    case invalidResponse(String)
    case missingRecipient
    case missingSender

    public var description: String {
        switch self {
        case .connectionClosed:
            return "SMTP connection closed unexpectedly."
        case .timeout:
            return "SMTP operation timed out."
        case .commandFailed(let code, let msg):
            return "SMTP command failed with code \(code): \(msg)"
        case .starttlsFailed(let msg):
            return "SMTP STARTTLS failed: \(msg)"
        case .authenticationFailed(let msg):
            return "SMTP authentication failed: \(msg)"
        case .invalidResponse(let line):
            return "SMTP server returned invalid response: \(line)"
        case .missingRecipient:
            return "Email has no recipients."
        case .missingSender:
            return "Email has no sender and no default sender is configured."
        }
    }
}

// MARK: - SMTP Mail Service Driver

/// Production SMTP mail driver built on `sersoft-gmbh/swift-smtp`.
/// Handles RFC-compliant connection pooling, STARTTLS negotiation, authentication,
/// and message delivery.
public struct SMTPMailService: MailService, Sendable {
    public let configuration: SMTPConfiguration
    public let eventLoopGroup: any EventLoopGroup
    public let logger: Logger

    public init(
        configuration: SMTPConfiguration,
        eventLoopGroup: any EventLoopGroup,
        logger: Logger
    ) {
        self.configuration = configuration
        self.eventLoopGroup = eventLoopGroup
        self.logger = logger
    }

    public func send(_ email: Email) async throws {
        // Validate sender
        guard let sender = email.from ?? configuration.defaultFrom else {
            throw SMTPError.missingSender
        }

        // Validate recipients
        guard !email.to.isEmpty || !email.cc.isEmpty || !email.bcc.isEmpty else {
            throw SMTPError.missingRecipient
        }

        // Configure server encryption
        let encryption: SwiftSMTP.Configuration.Server.Encryption
        switch configuration.encryption {
        case .none:
            encryption = .plain
        case .ssl:
            encryption = .ssl
        case .starttls:
            encryption = .startTLS(.always)
        }

        let server = SwiftSMTP.Configuration.Server(
            hostname: configuration.host,
            port: configuration.port,
            encryption: encryption
        )

        // Configure credentials
        let credentials: SwiftSMTP.Configuration.Credentials?
        if let username = configuration.username, !username.isEmpty {
            credentials = SwiftSMTP.Configuration.Credentials(
                username: username,
                password: configuration.password ?? ""
            )
        } else {
            credentials = nil
        }

        let clientConfig = SwiftSMTP.Configuration(
            server: server,
            connectionTimeOut: .seconds(Int64(configuration.timeoutSeconds)),
            credentials: credentials,
            featureFlags: [.useESMTP]
        )

        // Convert body
        let smtpBody: SwiftSMTP.Email.Body
        switch email.body {
        case .plain(let text):
            smtpBody = .plain(text)
        case .html(let html):
            smtpBody = .html(html)
        case .both(let plain, let html):
            smtpBody = .universal(plain: plain, html: html)
        }

        // Convert attachments (handling inline CID images vs regular file attachments)
        let smtpAttachments = email.attachments.map { att in
            let kind: SwiftSMTP.Email.Attachment.Kind
            if let cid = att.contentID {
                kind = .inline(contentID: cid)
            } else {
                kind = .attachment(contentID: nil)
            }
            return SwiftSMTP.Email.Attachment(
                kind: kind,
                name: att.filename,
                contentType: att.contentType,
                data: att.data
            )
        }

        // Build SwiftSMTP.Email model
        let smtpEmail = SwiftSMTP.Email(
            sender: SwiftSMTP.Email.Contact(name: sender.name, emailAddress: sender.address),
            replyTo: email.replyTo.first.map { SwiftSMTP.Email.Contact(name: $0.name, emailAddress: $0.address) },
            recipients: email.to.map { SwiftSMTP.Email.Contact(name: $0.name, emailAddress: $0.address) },
            cc: email.cc.map { SwiftSMTP.Email.Contact(name: $0.name, emailAddress: $0.address) },
            bcc: email.bcc.map { SwiftSMTP.Email.Contact(name: $0.name, emailAddress: $0.address) },
            subject: email.subject,
            body: smtpBody,
            attachments: smtpAttachments
        )

        // Dispatch via SwiftSMTP Mailer
        let mailer = Mailer(
            group: eventLoopGroup,
            configuration: clientConfig
        )

        try await mailer.send(smtpEmail)

        logger.info(
            "Sent email '\(email.subject)' to \(email.to.map(\.description).joined(separator: ", ")) via SMTP (\(configuration.host):\(configuration.port))",
            metadata: ["email_id": .string(email.id.uuidString)]
        )
    }
}
