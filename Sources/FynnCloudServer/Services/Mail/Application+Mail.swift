import Foundation
import Queues
import Vapor

// MARK: - Application Mail Integration

extension Application {
    /// Entry point for application-level email configuration, dispatch, and provider selection.
    public var mail: Mail {
        .init(application: self)
    }

    public struct Mail {
        public let application: Application

        public struct Provider: Sendable {
            let run: @Sendable (Application) -> Void

            public init(run: @escaping @Sendable (Application) -> Void) {
                self.run = run
            }
        }

        final class Storage: @unchecked Sendable {
            var makeService: (@Sendable (Application) -> any MailService)?
            init() { }
        }

        struct Key: StorageKey {
            typealias Value = Storage
        }

        struct MemoryStorageKey: StorageKey {
            typealias Value = MemoryMailService
        }

        func initialize() {
            if self.application.storage[Key.self] == nil {
                self.application.storage[Key.self] = .init()
            }
        }

        /// Configures the application to use the specified mail provider.
        public func use(_ provider: Provider) {
            self.initialize()
            provider.run(self.application)
        }

        /// Configures a custom closure to manufacture the active `MailService`.
        public func use(_ makeService: @escaping @Sendable (Application) -> any MailService) {
            self.initialize()
            self.application.storage[Key.self]!.makeService = makeService
        }

        /// The active mail service.
        public var service: any MailService {
            guard let storage = self.application.storage[Key.self],
                  let makeService = storage.makeService else {
                fatalError("MailService not configured. Call app.mail.use(...) in configure.swift")
            }
            return makeService(self.application)
        }

        /// Sends an email immediately through the active mail service.
        public func send(_ email: Email) async throws {
            try await self.service.send(email)
        }

        /// Queues an email for asynchronous background delivery using Vapor Queues.
        public func queue(_ email: Email, queue: QueueName = .default) async throws {
            try await self.application.queues.queue(queue).dispatch(SendEmailJob.self, email)
        }

        /// Thread-safe in-memory mail store accessor for test assertions when using `.memory` or `.dynamic`.
        public var memory: MemoryMailService {
            guard let service = self.application.storage[MemoryStorageKey.self] else {
                fatalError("MemoryMailService not configured. Call app.mail.use(.memory)")
            }
            return service
        }

        var memoryStorage: MemoryMailService? {
            self.application.storage[MemoryStorageKey.self]
        }
    }
}

// MARK: - Built-in Providers

extension Application.Mail.Provider {
    /// In-memory provider that records sent emails in memory for unit and integration testing.
    public static var memory: Self {
        .init { app in
            let memory = MemoryMailService()
            app.storage[Application.Mail.MemoryStorageKey.self] = memory
            app.mail.use { _ in memory }
        }
    }

    /// Logging provider that writes outgoing emails to the application logger under the `.mail` subsystem.
    public static var log: Self {
        .init { app in
            app.mail.use { app in
                LogMailService(logger: app.logger(subsystem: .mail))
            }
        }
    }

    /// Dedicated SMTP provider configured with a static `SMTPConfiguration`.
    public static func smtp(_ config: SMTPConfiguration) -> Self {
        .init { app in
            app.mail.use { app in
                SMTPMailService(
                    configuration: config,
                    eventLoopGroup: app.eventLoopGroup,
                    logger: app.logger(subsystem: .mail)
                )
            }
        }
    }

    /// Dynamic provider that resolves configuration at runtime via `AppSettings` / ENV, falling
    /// back to in-memory recording in tests and logging in development/staging.
    public static var dynamic: Self {
        .init { app in
            let memory = MemoryMailService()
            app.storage[Application.Mail.MemoryStorageKey.self] = memory
            app.mail.use { app in
                DynamicMailService(application: app)
            }
        }
    }
}

// MARK: - Request Mail Integration

extension Request {
    /// Request-scoped mail access for sending and queuing emails.
    public var mail: RequestMail {
        .init(request: self)
    }

    public struct RequestMail {
        public let request: Request

        /// The active mail service configured on the application.
        public var service: any MailService {
            self.request.application.mail.service
        }

        /// Sends an email immediately.
        public func send(_ email: Email) async throws {
            try await self.service.send(email)
        }

        /// Queues an email for asynchronous background dispatch on the request's event loop / queue worker.
        public func queue(_ email: Email, queue: QueueName = .default) async throws {
            try await self.request.queues(queue, logger: nil).dispatch(SendEmailJob.self, email)
        }
    }
}
