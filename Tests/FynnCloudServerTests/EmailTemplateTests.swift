import XCTest
import NIOCore
import Vapor
import VaporTesting
@testable import FynnCloudServer

final class EmailTemplateTests: XCTestCase {

    // MARK: - MarkdownRenderer Tests

    func testMarkdownRendererButtons() {
        let markdown = "[Button: Get Started](https://fynncloud.ch/start)"
        let html = MarkdownRenderer.render(markdown)

        XCTAssertTrue(html.contains("<a href=\"https://fynncloud.ch/start\""))
        XCTAssertTrue(html.contains("Get Started"))
        XCTAssertTrue(html.contains("display: inline-block"))
        XCTAssertTrue(html.contains("border-radius: 8px"))
    }

    func testMarkdownRendererStandardLinks() {
        let markdown = "Visit [FynnCloud](https://fynncloud.ch) for docs."
        let html = MarkdownRenderer.render(markdown)

        XCTAssertTrue(html.contains("<a href=\"https://fynncloud.ch\""))
        XCTAssertTrue(html.contains("FynnCloud</a>"))
        XCTAssertFalse(html.contains("Button:"))
    }

    func testMarkdownRendererAlerts() {
        let noteMD = "> [!NOTE] This is an important note."
        let noteHTML = MarkdownRenderer.render(noteMD)
        XCTAssertTrue(noteHTML.contains("border-left: 4px solid #3b82f6"))
        XCTAssertTrue(noteHTML.contains("Note</strong>"))
        XCTAssertTrue(noteHTML.contains("This is an important note."))

        let warningMD = "> [!WARNING] This is a warning."
        let warningHTML = MarkdownRenderer.render(warningMD)
        XCTAssertTrue(warningHTML.contains("border-left: 4px solid #f59e0b"))
        XCTAssertTrue(warningHTML.contains("Warning</strong>"))
        XCTAssertTrue(warningHTML.contains("This is a warning."))

        let tipMD = "> [!TIP] This is a pro tip."
        let tipHTML = MarkdownRenderer.render(tipMD)
        XCTAssertTrue(tipHTML.contains("border-left: 4px solid #10b981"))
        XCTAssertTrue(tipHTML.contains("Tip</strong>"))
        XCTAssertTrue(tipHTML.contains("This is a pro tip."))

        let importantMD = "> [!IMPORTANT] Critical requirement."
        let importantHTML = MarkdownRenderer.render(importantMD)
        XCTAssertTrue(importantHTML.contains("Important</strong>"))
        XCTAssertTrue(importantHTML.contains("Critical requirement."))
    }

    func testMarkdownRendererCodeBlocks() {
        let markdown = """
        Here is some code:
        ```swift
        let x = 42
        ```
        And inline `let y = 10`.
        """
        let html = MarkdownRenderer.render(markdown)

        XCTAssertTrue(html.contains("<pre style=\"background-color: #0d0d0e;"))
        XCTAssertTrue(html.contains("<code style=\"background-color: #232326;"))
    }

    func testMarkdownRendererTables() {
        let markdown = """
        | Setting | Value |
        |---|---|
        | App Name | FynnCloud |
        | Storage | 50 GB |
        """
        let html = MarkdownRenderer.render(markdown)

        XCTAssertTrue(html.contains("<table style="))
        XCTAssertTrue(html.contains("<th style="))
        XCTAssertTrue(html.contains("App Name"))
        XCTAssertTrue(html.contains("50 GB"))
    }

    // MARK: - EmailTemplateService Rendering & Fallback Tests

    func testRenderTestEmailTemplate() {
        let fields = [
            "appName": "TestCloud",
            "recipient": "admin@example.com",
            "timestamp": "2026-09-09T23:00:00Z",
            "driver": "dynamic",
            "frontendURL": "https://testcloud.app"
        ]

        let (html, plainText) = EmailTemplateService.render(
            id: "test_email",
            fields: fields,
            appName: "TestCloud",
            frontendURL: "https://testcloud.app"
        )

        // Layout wrapping assertions
        XCTAssertTrue(html.contains("TestCloud"))
        XCTAssertTrue(html.contains("cid:logo-email.png"))
        XCTAssertTrue(html.contains("Mail Service Test"))
        XCTAssertTrue(html.contains("admin@example.com"))
        XCTAssertFalse(html.contains("&copy;"))

        // Plain text assertions
        XCTAssertFalse(plainText.contains("<div"))
        XCTAssertFalse(plainText.contains("<p"))
        XCTAssertTrue(plainText.contains("Mail Service Test"))
        XCTAssertTrue(plainText.contains("admin@example.com"))
    }

    func testRenderCustomMarkdownEmail() {
        let rawMarkdown = """
        # Hello World

        This is a **custom** notification.

        [Button: Action](https://example.com)
        """
        let (html, plainText) = EmailTemplateService.render(
            id: "custom",
            fields: ["rawMarkdown": rawMarkdown],
            appName: "FynnCloud"
        )

        XCTAssertTrue(html.contains("Hello World"))
        XCTAssertTrue(html.contains("<strong style=\"font-weight: 600; color: #ffffff;\">custom</strong>"))
        XCTAssertTrue(html.contains("Action</a>"))
        XCTAssertTrue(plainText.contains("Hello World"))
        XCTAssertFalse(plainText.contains("<a href"))
    }

    func testRenderFileSharedTemplate() {
        let fields = [
            "appName": "FynnCloud",
            "sharerName": "Alice Developer",
            "fileName": "Project Roadmap.pdf",
            "itemType": "file",
            "itemTypeCap": "File",
            "role": "Editor",
            "itemURL": "https://fynncloud.ch/shared/with-me",
            "frontendURL": "https://fynncloud.ch"
        ]

        let (html, plainText) = EmailTemplateService.render(
            id: "file_shared",
            fields: fields,
            appName: "FynnCloud",
            frontendURL: "https://fynncloud.ch"
        )

        // HTML assertions
        XCTAssertTrue(html.contains("Alice Developer shared a file with you"))
        XCTAssertTrue(html.contains("Project Roadmap.pdf"))
        XCTAssertTrue(html.contains("Open File"))
        XCTAssertTrue(html.contains("https://fynncloud.ch/shared/with-me"))

        // Plaintext assertions
        XCTAssertTrue(plainText.contains("Alice Developer shared a file with you"))
        XCTAssertTrue(plainText.contains("Project Roadmap.pdf"))
    }

    func testTemplateFallback() {
        let fallback = EmailTemplates.fallback(for: "test_email")
        XCTAssertFalse(fallback.isEmpty)
        XCTAssertTrue(fallback.contains("Mail Service Test"))

        let fileSharedFallback = EmailTemplates.fallback(for: "file_shared")
        XCTAssertFalse(fileSharedFallback.isEmpty)
        XCTAssertTrue(fileSharedFallback.contains("shared a {{itemType}} with you"))

        let nonExistentFallback = EmailTemplates.fallback(for: "unknown_xyz")
        XCTAssertTrue(nonExistentFallback.isEmpty)
    }

    // MARK: - Custom Branding Logo Tests

    func testRenderWithCustomBrandingLogoURL() {
        let customLogo = "https://cloud.example.com/api/branding/logo?v=1725900000"

        // Case 1: Custom logo with showLogoAndName = false
        let (htmlNoName, _) = EmailTemplateService.render(
            id: "test_email",
            fields: ["recipient": "admin@example.com"],
            appName: "AcmeCloud",
            frontendURL: "https://cloud.example.com",
            customLogoURL: customLogo,
            showLogoAndName: false
        )

        XCTAssertTrue(htmlNoName.contains(customLogo))
        XCTAssertFalse(htmlNoName.contains("cid:logo-email.png"))
        // Instance name header column should NOT be present
        XCTAssertFalse(htmlNoName.contains("<td valign=\"middle\" style=\"font-size: 24px;"))

        // Case 2: Custom logo with showLogoAndName = true
        let (htmlWithName, _) = EmailTemplateService.render(
            id: "test_email",
            fields: ["recipient": "admin@example.com"],
            appName: "AcmeCloud",
            frontendURL: "https://cloud.example.com",
            customLogoURL: customLogo,
            showLogoAndName: true
        )

        XCTAssertTrue(htmlWithName.contains(customLogo))
        XCTAssertTrue(htmlWithName.contains("AcmeCloud"))
        XCTAssertTrue(htmlWithName.contains("<td valign=\"middle\" style=\"font-size: 24px;"))
    }

    // MARK: - Email Building & MIME Integration

    func testBuildEmailAndMimeEncoding() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }

        let templateService = EmailTemplateService(application: app)
        let email = await templateService.buildEmail(
            id: "test_email",
            to: "user@example.com",
            subject: "Mail Test",
            fields: [
                "recipient": "user@example.com",
                "timestamp": "2026-09-09T23:00:00Z",
                "driver": "dynamic"
            ]
        )

        XCTAssertEqual(email.to.first?.address, "user@example.com")
        XCTAssertEqual(email.subject, "Mail Test")

        // Should have both plain and html bodies
        guard case .both(let plain, let html) = email.body else {
            XCTFail("Expected .both email body")
            return
        }
        XCTAssertFalse(plain.isEmpty)
        XCTAssertFalse(html.isEmpty)
        XCTAssertTrue(html.contains("Mail Service Test"))

        // With default branding, logo is attached as inline CID
        if EmailTemplateService.getLogoAttachmentData() != nil {
            XCTAssertEqual(email.attachments.count, 1)
            XCTAssertTrue(html.contains("cid:logo-email.png"))
        }

        // Encode through EmailMimeEncoder
        let encoder = EmailMimeEncoder()
        let mime = encoder.encode(email, hostname: "fynncloud.ch")

        XCTAssertTrue(mime.contains("To: user@example.com"))
        XCTAssertTrue(mime.contains("Subject: Mail Test"))
        XCTAssertTrue(mime.contains("text/plain"))
        XCTAssertTrue(mime.contains("text/html"))
        if !email.attachments.isEmpty {
            XCTAssertTrue(mime.contains("Content-Type: multipart/related"))
            XCTAssertTrue(mime.contains("filename=\"logo-email.png\""))
        }
    }

    func testBuildEmailWithCustomBrandingSettings() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        app.fileStorage = TestStorage.createLocalProvider()

        setenv("CUSTOM_LOGO_UPDATED_AT", "1725900000", 1)
        setenv("CUSTOM_LOGO_MIME_TYPE", "image/svg+xml", 1)
        setenv("APP_NAME", "CustomBrandedCloud", 1)
        defer {
            unsetenv("CUSTOM_LOGO_UPDATED_AT")
            unsetenv("CUSTOM_LOGO_MIME_TYPE")
            unsetenv("APP_NAME")
        }

        let storage = StorageService(provider: app.fileStorage)
        let svgContent = "<svg viewBox=\"0 0 100 100\"><circle cx=\"50\" cy=\"50\" r=\"40\"/></svg>"
        var buffer = ByteBufferAllocator().buffer(capacity: svgContent.utf8.count)
        buffer.writeString(svgContent)
        try await storage.storeBrandingAsset(.logo, buffer: buffer, contentType: "image/svg+xml")

        let templateService = EmailTemplateService(application: app)
        let email = await templateService.buildEmail(
            id: "test_email",
            to: "user@example.com",
            subject: "Custom Brand Mail"
        )

        // Custom SVG logo should be automatically rasterized to PNG and attached as inline CID
        XCTAssertEqual(email.attachments.count, 1)
        XCTAssertEqual(email.attachments.first?.contentType, "image/png")
        XCTAssertEqual(email.attachments.first?.contentID, "branding-logo.png")

        guard case .both(_, let html) = email.body else {
            XCTFail("Expected .both email body")
            return
        }
        XCTAssertTrue(html.contains("cid:branding-logo.png"))
        XCTAssertFalse(html.contains("/api/branding/logo"))

        // Verify MIME encoding: inline disposition without filename parameter
        let encoder = EmailMimeEncoder()
        let mime = encoder.encode(email, hostname: "fynncloud.ch")
        XCTAssertTrue(mime.contains("Content-Type: multipart/related"))
        XCTAssertTrue(mime.contains("Content-ID: <branding-logo.png>"))
        XCTAssertTrue(mime.contains("Content-Disposition: inline; filename=\"branding-logo.png\""))
    }
}
