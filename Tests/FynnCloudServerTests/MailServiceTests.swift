import XCTest
import NIOCore
import Vapor
import VaporTesting
import Queues
@testable import FynnCloudServer

final class MailServiceTests: XCTestCase {

    // MARK: - EmailAddress Tests

    func testEmailAddressParsingAndFormatting() {
        // Plain address
        let addr1 = EmailAddress(address: "user@example.com")
        XCTAssertEqual(addr1.address, "user@example.com")
        XCTAssertNil(addr1.name)
        XCTAssertEqual(addr1.description, "user@example.com")

        // Address with name
        let addr2 = EmailAddress(address: "user@example.com", name: "John Doe")
        XCTAssertEqual(addr2.address, "user@example.com")
        XCTAssertEqual(addr2.name, "John Doe")
        XCTAssertEqual(addr2.description, "John Doe <user@example.com>")

        // String literal with angle brackets
        let addr3: EmailAddress = "Jane Smith <jane@example.com>"
        XCTAssertEqual(addr3.address, "jane@example.com")
        XCTAssertEqual(addr3.name, "Jane Smith")
        XCTAssertEqual(addr3.description, "Jane Smith <jane@example.com>")

        // String literal plain
        let addr4: EmailAddress = "plain@example.com"
        XCTAssertEqual(addr4.address, "plain@example.com")
        XCTAssertNil(addr4.name)

        // Quoting for special characters in name
        let addr5 = EmailAddress(address: "smith@example.com", name: "Smith, John")
        XCTAssertEqual(addr5.description, "\"Smith, John\" <smith@example.com>")
    }

    // MARK: - EmailMimeEncoder Tests

    func testMimeEncoderPlainText() {
        let encoder = EmailMimeEncoder()
        let email = Email(
            from: "sender@example.com",
            to: "receiver@example.com",
            subject: "Plain Subject",
            text: "Hello, this is a plain text body."
        )

        let mime = encoder.encode(email, hostname: "test.local")
        XCTAssertTrue(mime.contains("From: sender@example.com"))
        XCTAssertTrue(mime.contains("To: receiver@example.com"))
        XCTAssertTrue(mime.contains("Subject: Plain Subject"))
        XCTAssertTrue(mime.contains("Content-Type: text/plain; charset=utf-8"))
        XCTAssertTrue(mime.contains("Content-Transfer-Encoding: 8bit"))
        XCTAssertTrue(mime.contains("Hello, this is a plain text body."))
    }

    func testMimeEncoderHtmlAndAlternative() {
        let encoder = EmailMimeEncoder()
        let email = Email(
            from: "sender@example.com",
            to: "receiver@example.com",
            subject: "HTML & Text",
            html: "<h1>Hello</h1>",
            text: "Hello"
        )

        let mime = encoder.encode(email, hostname: "test.local")
        XCTAssertTrue(mime.contains("Content-Type: multipart/alternative; boundary=\"alt_"))
        XCTAssertTrue(mime.contains("Content-Type: text/plain; charset=utf-8"))
        XCTAssertTrue(mime.contains("Content-Type: text/html; charset=utf-8"))
        XCTAssertTrue(mime.contains("<h1>Hello</h1>"))
        XCTAssertTrue(mime.contains("Hello"))
    }

    func testMimeEncoderAttachments() {
        let encoder = EmailMimeEncoder()
        let fileData = Data("Attachment content here".utf8)
        let attachment = EmailAttachment(
            filename: "sample.txt",
            contentType: "text/plain",
            data: fileData
        )

        let email = Email(
            from: "sender@example.com",
            to: "receiver@example.com",
            subject: "With Attachment",
            body: .plain("Please find attached file."),
            attachments: [attachment]
        )

        let mime = encoder.encode(email, hostname: "test.local")
        XCTAssertTrue(mime.contains("Content-Type: multipart/mixed; boundary=\"mixed_"))
        XCTAssertTrue(mime.contains("Content-Disposition: attachment; filename=\"sample.txt\""))
        XCTAssertTrue(mime.contains("Content-Type: text/plain; name=\"sample.txt\""))
        XCTAssertTrue(mime.contains(fileData.base64EncodedString()))
    }

    func testMimeEncoderInlineAttachments() {
        let encoder = EmailMimeEncoder()
        let imgData = Data([0x89, 0x50, 0x4E, 0x47])
        let attachment = EmailAttachment(
            filename: "logo.png",
            contentType: "image/png",
            data: imgData,
            contentID: "logo.png"
        )

        let email = Email(
            from: "sender@example.com",
            to: "receiver@example.com",
            subject: "With Inline Logo",
            body: .html("<img src=\"cid:logo.png\">"),
            attachments: [attachment]
        )

        let mime = encoder.encode(email, hostname: "test.local")
        XCTAssertTrue(mime.contains("Content-Type: multipart/related; boundary=\"related_"))
        XCTAssertTrue(mime.contains("Content-Disposition: inline; filename=\"logo.png\""))
        XCTAssertTrue(mime.contains("Content-ID: <logo.png>"))
        XCTAssertFalse(mime.contains("Content-Type: multipart/mixed"))
    }

    func testMimeEncoderMixedAndInlineAttachments() {
        let encoder = EmailMimeEncoder()
        let imgData = Data([0x89, 0x50, 0x4E, 0x47])
        let inlineAtt = EmailAttachment(
            filename: "logo.png",
            contentType: "image/png",
            data: imgData,
            contentID: "logo.png"
        )
        let fileAtt = EmailAttachment(
            filename: "report.pdf",
            contentType: "application/pdf",
            data: Data("PDF data".utf8)
        )

        let email = Email(
            from: "sender@example.com",
            to: "receiver@example.com",
            subject: "Mixed and Inline",
            body: .html("<h1>Report</h1><img src=\"cid:logo.png\">"),
            attachments: [inlineAtt, fileAtt]
        )

        let mime = encoder.encode(email, hostname: "test.local")
        XCTAssertTrue(mime.contains("Content-Type: multipart/mixed; boundary=\"mixed_"))
        XCTAssertTrue(mime.contains("Content-Type: multipart/related; boundary=\"related_"))
        XCTAssertTrue(mime.contains("Content-ID: <logo.png>"))
        XCTAssertTrue(mime.contains("Content-Disposition: inline; filename=\"logo.png\""))
        XCTAssertTrue(mime.contains("Content-Disposition: attachment; filename=\"report.pdf\""))
    }

    func testMimeEncoderBccOmittedFromHeaders() {
        let encoder = EmailMimeEncoder()
        let email = Email(
            from: "sender@example.com",
            to: ["visible@example.com"],
            bcc: ["secret@example.com"],
            subject: "Secret BCC",
            body: .plain("Secret message")
        )

        let mime = encoder.encode(email, hostname: "test.local")
        XCTAssertTrue(mime.contains("To: visible@example.com"))
        // Bcc header MUST NOT be in the MIME message to prevent leaking recipients
        XCTAssertFalse(mime.contains("Bcc:"))
        XCTAssertFalse(mime.contains("secret@example.com"))
    }

    func testMimeEncoderNonAsciiSubjectEncoding() {
        let encoder = EmailMimeEncoder()
        let email = Email(
            from: "sender@example.com",
            to: "receiver@example.com",
            subject: "Willkommen bei FynnCloud! 🚀",
            text: "Welcome!"
        )

        let mime = encoder.encode(email, hostname: "test.local")
        XCTAssertTrue(mime.contains("Subject: =?UTF-8?B?"))
    }

    // MARK: - MemoryMailService Tests

    func testMemoryMailService() async throws {
        let service = MemoryMailService()
        XCTAssertEqual(service.sentEmails.count, 0)
        XCTAssertNil(service.last)

        let email1 = Email(to: "alice@example.com", subject: "First", text: "Text 1")
        let email2 = Email(to: "bob@example.com", subject: "Second", text: "Text 2")

        try await service.send(email1)
        XCTAssertEqual(service.sentEmails.count, 1)
        XCTAssertEqual(service.last?.subject, "First")

        try await service.send(email2)
        XCTAssertEqual(service.sentEmails.count, 2)
        XCTAssertEqual(service.last?.subject, "Second")

        let found = service.find { $0.to.contains("bob@example.com") }
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.subject, "Second")

        service.clear()
        XCTAssertEqual(service.sentEmails.count, 0)
        XCTAssertNil(service.last)
    }

    // MARK: - LogMailService Tests

    func testLogMailService() async throws {
        let logger = Logger(label: "test.mail")
        let service = LogMailService(logger: logger)
        let email = Email(
            from: "sender@example.com",
            to: "recipient@example.com",
            cc: ["cc@example.com"],
            bcc: ["bcc@example.com"],
            subject: "Log test",
            text: "Hello logger",
            attachments: [
                EmailAttachment(filename: "dummy.txt", contentType: "text/plain", data: Data("xyz".utf8))
            ]
        )

        // LogMailService should complete without throwing
        try await service.send(email)
    }

    // MARK: - Application & Request Dependency Injection Tests

    func testApplicationMailServiceDI() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }

        // Test configuring memory provider
        app.mail.use(.memory)

        let email = Email(to: "test@example.com", subject: "Testing DI", text: "DI message")
        try await app.mail.send(email)

        XCTAssertEqual(app.mail.memory.sentEmails.count, 1)
        XCTAssertEqual(app.mail.memory.sentEmails.first?.subject, "Testing DI")

        // Test configuring custom closure provider
        let customMemory = MemoryMailService()
        app.mail.use { _ in customMemory }

        let email2 = Email(to: "custom@example.com", subject: "Custom Provider", text: "Custom")
        try await app.mail.send(email2)

        XCTAssertEqual(customMemory.sentEmails.count, 1)
        XCTAssertEqual(customMemory.sentEmails.first?.subject, "Custom Provider")
    }

    func testSendEmailJobDequeue() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }

        app.mail.use(.memory)

        let email = Email(to: "queued@example.com", subject: "Queued Mail", text: "Queued body")

        // Dequeue via job
        let job = SendEmailJob()
        let context = QueueContext(
            queueName: .default,
            configuration: .init(),
            application: app,
            logger: app.logger,
            on: app.eventLoopGroup.next()
        )

        try await job.dequeue(context, email)

        XCTAssertEqual(app.mail.memory.sentEmails.count, 1)
        XCTAssertEqual(app.mail.memory.sentEmails.first?.to.first?.address, "queued@example.com")
        XCTAssertEqual(app.mail.memory.sentEmails.first?.subject, "Queued Mail")
    }

    func testDynamicMailServiceInTestingEnvironment() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }

        app.mail.use(.dynamic)

        let email = Email(to: "dynamic@example.com", subject: "Dynamic Test", text: "Testing dynamic")
        try await app.mail.send(email)

        XCTAssertEqual(app.mail.memory.sentEmails.count, 1)
        XCTAssertEqual(app.mail.memory.sentEmails.first?.to.first?.address, "dynamic@example.com")
        XCTAssertEqual(app.mail.memory.sentEmails.first?.subject, "Dynamic Test")
    }

    func testSMTPMailServiceValidationMissingSender() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }

        let config = SMTPConfiguration(host: "smtp.example.com", port: 587, defaultFrom: nil)
        let smtp = SMTPMailService(configuration: config, eventLoopGroup: app.eventLoopGroup, logger: app.logger)

        let email = Email(to: "dest@example.com", subject: "No sender", text: "Test")
        do {
            try await smtp.send(email)
            XCTFail("Expected missingSender error")
        } catch let error as SMTPError {
            if case .missingSender = error {
                // Expected
            } else {
                XCTFail("Expected .missingSender but got \(error)")
            }
        }
    }

    func testSMTPMailServiceValidationMissingRecipient() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }

        let config = SMTPConfiguration(host: "smtp.example.com", port: 587, defaultFrom: "sender@example.com")
        let smtp = SMTPMailService(configuration: config, eventLoopGroup: app.eventLoopGroup, logger: app.logger)

        let email = Email(from: "sender@example.com", to: [], subject: "No recipients", text: "Test")
        do {
            try await smtp.send(email)
            XCTFail("Expected missingRecipient error")
        } catch let error as SMTPError {
            if case .missingRecipient = error {
                // Expected
            } else {
                XCTFail("Expected .missingRecipient but got \(error)")
            }
        }
    }

    func testSMTPConfigurationProperties() {
        let config = SMTPConfiguration(
            host: "mail.fynncloud.test",
            port: 465,
            username: "admin",
            password: "secretpassword",
            encryption: .ssl,
            defaultFrom: "noreply@fynncloud.test",
            clientHostname: "fynncloud.internal",
            timeoutSeconds: 45
        )

        XCTAssertEqual(config.host, "mail.fynncloud.test")
        XCTAssertEqual(config.port, 465)
        XCTAssertEqual(config.username, "admin")
        XCTAssertEqual(config.password, "secretpassword")
        XCTAssertEqual(config.encryption, .ssl)
        XCTAssertEqual(config.defaultFrom?.address, "noreply@fynncloud.test")
        XCTAssertEqual(config.clientHostname, "fynncloud.internal")
        XCTAssertEqual(config.timeoutSeconds, 45)
    }
}

