import Foundation
import NIOCore
import NIOConcurrencyHelpers

/// An in-memory implementation of `MailService` designed for testing and development.
/// Retains sent emails in thread-safe memory storage for assertions.
public final class MemoryMailService: MailService, @unchecked Sendable {
    private let storage: NIOLockedValueBox<[Email]>

    public init(initialEmails: [Email] = []) {
        self.storage = NIOLockedValueBox(initialEmails)
    }

    /// All emails sent through this service instance, in chronological order.
    public var sentEmails: [Email] {
        storage.withLockedValue { $0 }
    }

    /// The most recently sent email, if any.
    public var last: Email? {
        storage.withLockedValue { $0.last }
    }

    /// Clears all recorded emails.
    public func clear() {
        storage.withLockedValue { $0.removeAll() }
    }

    /// Finds all sent emails matching a specific condition.
    public func find(where predicate: (Email) -> Bool) -> [Email] {
        storage.withLockedValue { $0.filter(predicate) }
    }

    /// Records the sent email in-memory.
    public func send(_ email: Email) async throws {
        storage.withLockedValue { $0.append(email) }
    }
}
