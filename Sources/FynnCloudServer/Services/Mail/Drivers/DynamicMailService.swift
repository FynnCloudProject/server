import Foundation
import Vapor

/// A dynamic `MailService` dispatcher that inspects application settings and the runtime environment
/// to choose the appropriate delivery driver (SMTP, in-memory, or logger).
public struct DynamicMailService: MailService, Sendable {
    public let application: Application

    public init(application: Application) {
        self.application = application
    }

    public func send(_ email: Email) async throws {
        // In testing environment without explicit SMTP configuration, record in memory
        if application.environment == .testing {
            if let memory = application.mail.memoryStorage {
                try await memory.send(email)
                return
            }
        }

        // Resolve runtime SMTP settings
        let host = (try? await application.settings.get(AppSettings.SmtpHost.self)) ?? AppSettings.SmtpHost.defaultValue
        let port = (try? await application.settings.get(AppSettings.SmtpPort.self)) ?? AppSettings.SmtpPort.defaultValue
        let username = (try? await application.settings.get(AppSettings.SmtpUsername.self)) ?? AppSettings.SmtpUsername.defaultValue
        let password = (try? await application.settings.get(AppSettings.SmtpPassword.self)) ?? AppSettings.SmtpPassword.defaultValue
        let encryptionSetting = (try? await application.settings.get(AppSettings.SmtpEncryption.self)) ?? AppSettings.SmtpEncryption.defaultValue
        let fromAddress = (try? await application.settings.get(AppSettings.MailFromAddress.self)) ?? AppSettings.MailFromAddress.defaultValue
        let fromName = (try? await application.settings.get(AppSettings.MailFromName.self)) ?? AppSettings.MailFromName.defaultValue

        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            let logger = application.logger(subsystem: .mail)
            logger.warning(
                "SMTP is not configured (smtpHost is empty). Outgoing email '\(email.subject)' to \(email.to.map(\.description).joined(separator: ", ")) was logged instead of sent."
            )
            let logService = LogMailService(logger: logger)
            try await logService.send(email)
            return
        }

        let encryption: SMTPConfiguration.Encryption
        switch encryptionSetting {
        case .none:
            encryption = .none
        case .ssl:
            encryption = .ssl
        case .starttls:
            encryption = .starttls
        }

        let defaultFrom: EmailAddress?
        if !fromAddress.isEmpty {
            defaultFrom = EmailAddress(address: fromAddress, name: fromName.isEmpty ? nil : fromName)
        } else {
            defaultFrom = nil
        }

        let config = SMTPConfiguration(
            host: trimmedHost,
            port: port,
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password,
            encryption: encryption,
            defaultFrom: defaultFrom,
            clientHostname: ProcessInfo.processInfo.hostName
        )

        let smtpService = SMTPMailService(
            configuration: config,
            eventLoopGroup: application.eventLoopGroup,
            logger: application.logger(subsystem: .mail)
        )

        try await smtpService.send(email)
    }
}
