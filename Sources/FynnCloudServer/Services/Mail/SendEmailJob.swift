import Foundation
import Queues
import Vapor

/// Background job for asynchronously dispatching emails via Vapor Queues.
public struct SendEmailJob: AsyncJob {
    public typealias Payload = Email

    public init() { }

    public func dequeue(_ context: QueueContext, _ payload: Email) async throws {
        let app = context.application
        let logger = context.logger.scoped(to: .mail)

        logger.info(
            "Dequeuing background email '\(payload.subject)' to \(payload.to.map(\.description).joined(separator: ", "))",
            metadata: ["email_id": .string(payload.id.uuidString)]
        )

        try await app.mail.send(payload)
    }

    public func error(_ context: QueueContext, _ error: any Error, _ payload: Email) async throws {
        context.logger.scoped(to: .mail).error(
            "Failed to send background email '\(payload.subject)': \(error)",
            metadata: [
                "email_id": .string(payload.id.uuidString),
                "error": .string("\(error)")
            ]
        )
    }
}
