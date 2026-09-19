import Foundation

/// Defines a service capable of delivering email messages.
public protocol MailService: Sendable {
    /// Sends an email message asynchronously.
    func send(_ email: Email) async throws
}
