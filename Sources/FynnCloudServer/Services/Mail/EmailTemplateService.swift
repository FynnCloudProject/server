import Foundation
import NIOCore
import Queues
import Vapor

public struct EmailTemplateService: Sendable {
    public let application: Application

    public init(application: Application) {
        self.application = application
    }

    // MARK: - Resource Loading

    public static func getTemplateMarkdown(id: String) -> String {
        // 1. Check module bundle
        if let bundleURL = Bundle.module.url(forResource: id, withExtension: "md", subdirectory: "EmailTemplates") ??
                           Bundle.module.url(forResource: "\(id).md", withExtension: nil),
           let data = try? Data(contentsOf: bundleURL),
           let str = String(data: data, encoding: .utf8) {
            return str
        }

        // 2. Check filesystem candidate locations
        let candidates = [
            "Resources/EmailTemplates/\(id).md",
            "./Resources/EmailTemplates/\(id).md",
            "/app/Resources/EmailTemplates/\(id).md"
        ]
        for path in candidates {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
        }

        // 3. Fallback to hardcoded constants
        return EmailTemplates.fallback(for: id)
    }

    public static func getTemplateLayout() -> String {
        // 1. Check module bundle
        if let bundleURL = Bundle.module.url(forResource: "layout", withExtension: "html", subdirectory: "EmailTemplates") ??
                           Bundle.module.url(forResource: "layout.html", withExtension: nil),
           let data = try? Data(contentsOf: bundleURL),
           let str = String(data: data, encoding: .utf8) {
            return str
        }

        // 2. Check filesystem candidate locations
        let candidates = [
            "Resources/EmailTemplates/layout.html",
            "./Resources/EmailTemplates/layout.html",
            "/app/Resources/EmailTemplates/layout.html"
        ]
        for path in candidates {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
        }

        // 3. Fallback layout
        return """
        <div style="padding: 40px 20px; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;">
            <div style="max-width: 560px; margin: 0 auto; padding: 32px; background-color: #141416; border: 1px solid #232326; border-radius: 12px; color: #e4e4e7;">
                <table border="0" cellpadding="0" cellspacing="0" style="margin-bottom: 24px;">
                    <tr>
                        <td valign="middle" style="padding-right: 12px;">
                            {{LOGO}}
                        </td>
                        {{HEADER_NAME}}
                    </tr>
                </table>
                {{BODY}}
            </div>
        </div>
        """
    }

    public static func getTemplateLogo() -> String {
        if let bundleURL = Bundle.module.url(forResource: "logo", withExtension: "svg", subdirectory: "EmailTemplates") ??
                           Bundle.module.url(forResource: "logo.svg", withExtension: nil),
           let data = try? Data(contentsOf: bundleURL),
           let str = String(data: data, encoding: .utf8) {
            return str
        }

        let candidates = [
            "Resources/EmailTemplates/logo.svg",
            "./Resources/EmailTemplates/logo.svg",
            "/app/Resources/EmailTemplates/logo.svg"
        ]
        for path in candidates {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
        }

        return """
        <svg class="select-none" style="display: block; margin: 0; width: 48px; height: 32px;" viewBox="-5 -5 472 320" fill="none" xmlns="http://www.w3.org/2000/svg">
            <path d="M199 0C233.265 3.1559e-05 263.504 17.1479 281.524 43.2889C282.081 44.0977 283.136 44.3989 284.039 44.0123C293.075 40.1438 303.035 38 313.5 38C349.516 38 379.561 63.3851 386.493 97.1246C386.64 97.8415 387.158 98.4313 387.852 98.6643C430.959 113.135 462 153.709 462 201.5C462 261.423 413.199 310 353 310H88.5C39.6229 310 9.95335e-05 270.601 0 222C0 192.571 14.5282 166.515 36.8421 150.539C37.5228 150.051 37.84 149.199 37.6496 148.383C36.5707 143.764 36 138.948 36 134C36 99.2061 64.2061 71 99 71C99.8477 71 100.692 71.0168 101.531 71.05C102.463 71.0868 103.31 70.4967 103.591 69.6078C116.346 29.2612 154.239 0 199 0ZM354.812 113.441C338.958 113.441 324.62 117.321 311.802 125.08C298.983 132.839 288.864 143.381 281.442 156.705C274.021 170.03 270.31 184.872 270.31 201.232C270.31 217.593 274.021 232.52 281.442 246.014C289.032 259.507 299.32 270.133 312.308 277.892C325.464 285.65 340.054 289.53 356.077 289.53C368.39 289.53 379.859 287.169 390.485 282.446C400.529 277.982 409.292 271.785 416.774 263.855C417.505 263.081 417.472 261.869 416.719 261.116L413.757 258.154C412.938 257.335 411.599 257.382 410.812 258.232C404.174 265.396 396.218 271.021 386.943 275.108C377.161 279.494 366.619 281.686 355.318 281.687C340.982 281.687 327.994 278.144 316.356 271.061C304.718 263.977 295.526 254.363 288.779 242.219C282.201 229.906 278.912 216.244 278.912 201.232C278.912 186.39 282.201 172.897 288.779 160.753C295.526 148.44 304.633 138.826 316.103 131.911C327.741 124.827 340.645 121.285 354.812 121.285C365.944 121.285 376.317 123.478 385.931 127.863C395.047 131.95 402.919 137.502 409.545 144.518C410.335 145.354 411.662 145.394 412.475 144.581L415.44 141.616C416.199 140.858 416.226 139.635 415.482 138.863C407.996 131.097 399.158 124.984 388.967 120.525C378.341 115.803 366.956 113.441 354.812 113.441ZM143.288 115.972C142.184 115.972 141.288 116.867 141.288 117.972V285C141.288 286.105 142.184 287 143.288 287H147.384C148.488 287 149.384 286.105 149.384 285V207.787C149.384 206.683 150.279 205.787 151.384 205.787H240.235C241.34 205.787 242.235 204.892 242.235 203.787V200.45C242.235 199.346 241.34 198.45 240.235 198.45H151.384C150.279 198.45 149.384 197.555 149.384 196.45V125.309C149.384 124.204 150.279 123.309 151.384 123.309H244.536C245.641 123.309 246.536 122.413 246.536 121.309V117.972C246.536 116.867 245.641 115.972 244.536 115.972H143.288Z" fill="url(#paint_linear_logo_preview)" />
            <defs>
                <linearGradient id="paint_linear_logo_preview" x1="283.077" y1="-23.377" x2="282.928" y2="432.061" gradientUnits="userSpaceOnUse">
                    <stop stop-color="#60a5fa" />
                    <stop offset="1" stop-color="#1d4ed8" />
                </linearGradient>
            </defs>
        </svg>
        """
    }

    public static func getLogoAttachmentData() -> Data? {
        if let bundleURL = Bundle.module.url(forResource: "logo-email", withExtension: "png") ??
                           Bundle.module.url(forResource: "logo-email.png", withExtension: nil),
           let data = try? Data(contentsOf: bundleURL) {
            return data
        }

        let candidates = [
            "Public/logo-email.png",
            "./Public/logo-email.png",
            "/app/Public/logo-email.png",
            "Resources/EmailTemplates/logo-email.png"
        ]
        for path in candidates {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                return data
            }
        }

        return nil
    }

    public static func getLogoAttachment() -> [EmailAttachment] {
        guard let data = getLogoAttachmentData() else {
            return []
        }
        return [
            EmailAttachment(
                filename: "logo-email.png",
                contentType: "image/png",
                data: data,
                contentID: "logo-email.png"
            )
        ]
    }

    // MARK: - Plaintext Extraction

    public static func extractPlainText(from htmlBody: String) -> String {
        return htmlBody
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "</p>", with: "\n\n")
            .replacingOccurrences(of: "<li>", with: "• ")
            .replacingOccurrences(of: "</li>", with: "\n")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func formatInlineSVG(_ svg: String) -> String {
        var str = svg.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = str.range(of: "<svg", options: .caseInsensitive) {
            str.insert(contentsOf: " height=\"32\" style=\"display: block; max-height: 32px; height: 32px; width: auto; margin: 0;\" ", at: match.upperBound)
        }
        return str
    }

    // MARK: - Rendering

    public static func render(
        id: String,
        fields: [String: String],
        appName: String = "FynnCloud",
        frontendURL: String = "http://localhost:3000",
        customLogoURL: String? = nil,
        customLogoCID: String? = nil,
        customLogoDataURI: String? = nil,
        customLogoSVG: String? = nil,
        showLogoAndName: Bool = false,
        isPreview: Bool = false
    ) -> (html: String, plainText: String) {
        var markdownTemplate: String
        if id == "custom" {
            markdownTemplate = fields["rawMarkdown"] ?? ""
        } else {
            markdownTemplate = getTemplateMarkdown(id: id)
        }

        // Automatic default fields if not provided
        var effectiveFields = fields
        if effectiveFields["appName"] == nil {
            effectiveFields["appName"] = appName
        }
        if effectiveFields["frontendURL"] == nil {
            effectiveFields["frontendURL"] = frontendURL
        }

        // Replace placeholders in markdown template
        var populatedMarkdown = markdownTemplate
        for (key, value) in effectiveFields {
            populatedMarkdown = populatedMarkdown.replacingOccurrences(of: "{{\(key)}}", with: value)
        }

        // Convert to styled HTML
        let bodyHTML = MarkdownRenderer.render(populatedMarkdown)

        // Logo and Header resolution:
        let hasCustomLogo = (customLogoCID != nil && !customLogoCID!.isEmpty)
            || (customLogoDataURI != nil && !customLogoDataURI!.isEmpty)
            || (customLogoSVG != nil && !customLogoSVG!.isEmpty)
            || (customLogoURL != nil && !customLogoURL!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let logoElement: String
        if let customLogoCID, !customLogoCID.isEmpty {
            logoElement = #"<img src="cid:\#(customLogoCID)" alt="\#(appName)" height="32" style="display: block; border: 0; max-height: 32px; width: auto;" />"#
        } else if let customLogoURL, !customLogoURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            logoElement = #"<img src="\#(customLogoURL)" alt="\#(appName)" height="32" style="display: block; border: 0; max-height: 32px; width: auto;" />"#
        } else if let customLogoDataURI, !customLogoDataURI.isEmpty {
            logoElement = #"<img src="\#(customLogoDataURI)" alt="\#(appName)" height="32" style="display: block; border: 0; max-height: 32px; width: auto;" />"#
        } else if let customLogoSVG, !customLogoSVG.isEmpty {
            logoElement = formatInlineSVG(customLogoSVG)
        } else if isPreview {
            logoElement = getTemplateLogo()
        } else {
            logoElement = #"<img src="cid:logo-email.png" alt="\#(appName)" width="48" height="32" style="display: block; border: 0;" />"#
        }

        let nameElement: String
        if !hasCustomLogo || showLogoAndName {
            nameElement = """
            <td valign="middle" style="font-size: 24px; font-weight: 200; color: #ffffff; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; line-height: 1;">
                \(appName)
            </td>
            """
        } else {
            nameElement = ""
        }

        let appDomain = URL(string: frontendURL)?.host ?? "fynncloud.ch"

        let layout = getTemplateLayout()
            .replacingOccurrences(of: "{{LOGO}}", with: logoElement)
            .replacingOccurrences(of: "{{HEADER_NAME}}", with: nameElement)
            .replacingOccurrences(of: "{{APP_NAME}}", with: appName)
            .replacingOccurrences(of: "{{APP_URL}}", with: frontendURL)
            .replacingOccurrences(of: "{{APP_DOMAIN}}", with: appDomain)
            .replacingOccurrences(of: "{{BODY}}", with: bodyHTML)

        // Extract clean plain text
        let plainText = extractPlainText(from: bodyHTML)

        return (html: layout, plainText: plainText)
    }

    // MARK: - Email Construction

    public func buildEmail(
        id: String,
        to: [EmailAddress],
        subject: String,
        fields: [String: String] = [:],
        from: EmailAddress? = nil
    ) async -> Email {
        let appName = (try? await application.optionalSettings?.get(AppSettings.AppName.self)) ?? AppSettings.AppName.defaultValue
        let frontendURL = (try? application.config.frontendURL) ?? Environment.first(matching: ["APP_FRONTEND_URL", "FRONTEND_URL"]) ?? "http://localhost:3000"

        let rawLogoUpdatedAt = (try? await application.optionalSettings?.get(AppSettings.CustomLogoUpdatedAt.self))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? AppSettings.CustomLogoUpdatedAt.envValue
            ?? ""
        let showLogoAndName = (try? await application.optionalSettings?.get(AppSettings.ShowLogoAndName.self))
            ?? AppSettings.ShowLogoAndName.envValue.flatMap(Bool.init)
            ?? AppSettings.ShowLogoAndName.defaultValue

        var customLogoCID: String? = nil
        var attachments: [EmailAttachment] = []

        if !rawLogoUpdatedAt.isEmpty, let provider = application.optionalFileStorage {
            let storage = StorageService(provider: provider)
            if (try? await storage.brandingAssetExists(.logo)) == true,
               let response = try? await storage.brandingAssetResponse(.logo),
               let buffer = try? await response.body.collectAsync() {
                let data = Data(buffer.readableBytesView)
                let rawMime = (try? await application.optionalSettings?.get(AppSettings.CustomLogoMimeType.self))
                    ?? AppSettings.CustomLogoMimeType.envValue
                    ?? ""
                let mimeType = rawMime.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "image/png" : rawMime

                let effectivePNGData: Data?
                if mimeType.contains("svg") {
                    effectivePNGData = SVGRasterizer.rasterizeToPNG(svgData: data)
                } else {
                    effectivePNGData = data
                }

                if let pngData = effectivePNGData {
                    let cid = "branding-logo.png"
                    customLogoCID = cid
                    attachments.append(
                        EmailAttachment(
                            filename: cid,
                            contentType: "image/png",
                            data: pngData,
                            contentID: cid
                        )
                    )
                }
            }
        }

        // If no custom logo was attached, attach default logo-email.png
        if customLogoCID == nil {
            attachments.append(contentsOf: Self.getLogoAttachment())
        }

        let rendered = Self.render(
            id: id,
            fields: fields,
            appName: appName,
            frontendURL: frontendURL,
            customLogoURL: nil,
            customLogoCID: customLogoCID,
            customLogoDataURI: nil,
            customLogoSVG: nil,
            showLogoAndName: showLogoAndName,
            isPreview: false
        )

        return Email(
            from: from,
            to: to,
            subject: subject,
            body: .both(plain: rendered.plainText, html: rendered.html),
            attachments: attachments
        )
    }

    public func buildEmail(
        id: String,
        to: EmailAddress,
        subject: String,
        fields: [String: String] = [:],
        from: EmailAddress? = nil
    ) async -> Email {
        await buildEmail(id: id, to: [to], subject: subject, fields: fields, from: from)
    }
}

// MARK: - Request & Application Mail Extensions

extension Request {
    public var emailTemplateService: EmailTemplateService {
        .init(application: self.application)
    }
}

extension Request.RequestMail {
    public func sendTemplate(
        id: String,
        to: EmailAddress,
        subject: String,
        fields: [String: String] = [:],
        from: EmailAddress? = nil
    ) async throws {
        let service = EmailTemplateService(application: self.request.application)
        let email = await service.buildEmail(id: id, to: to, subject: subject, fields: fields, from: from)
        try await self.send(email)
    }

    public func queueTemplate(
        id: String,
        to: EmailAddress,
        subject: String,
        fields: [String: String] = [:],
        from: EmailAddress? = nil,
        queue: QueueName = .default
    ) async throws {
        let service = EmailTemplateService(application: self.request.application)
        let email = await service.buildEmail(id: id, to: to, subject: subject, fields: fields, from: from)
        try await self.queue(email, queue: queue)
    }
}

extension Application.Mail {
    public func sendTemplate(
        id: String,
        to: EmailAddress,
        subject: String,
        fields: [String: String] = [:],
        from: EmailAddress? = nil
    ) async throws {
        let service = EmailTemplateService(application: self.application)
        let email = await service.buildEmail(id: id, to: to, subject: subject, fields: fields, from: from)
        try await self.send(email)
    }

    public func queueTemplate(
        id: String,
        to: EmailAddress,
        subject: String,
        fields: [String: String] = [:],
        from: EmailAddress? = nil,
        queue: QueueName = .default
    ) async throws {
        let service = EmailTemplateService(application: self.application)
        let email = await service.buildEmail(id: id, to: to, subject: subject, fields: fields, from: from)
        try await self.queue(email, queue: queue)
    }
}
