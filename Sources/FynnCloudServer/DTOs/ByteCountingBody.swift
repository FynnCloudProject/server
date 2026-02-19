import Atomics
import NIOCore
import Vapor

/// Wraps a Request.Body to count actual bytes streamed
/// This prevents users from spoofing upload sizes via Content-Length header
final class ByteCountingBody: Sendable {
    private let wrappedBody: Request.Body
    private let maxAllowedSize: Int64
    private let actualByteCount: ManagedAtomic<Int64>

    init(wrappedBody: Request.Body, maxAllowedSize: Int64) {
        self.wrappedBody = wrappedBody
        self.maxAllowedSize = maxAllowedSize
        self.actualByteCount = ManagedAtomic(0)
    }

    /// Get the actual number of bytes streamed so far
    var bytesReceived: Int64 {
        actualByteCount.load(ordering: .acquiring)
    }

    /// Stream the body while counting bytes and enforcing size limits
    func drain(
        on eventLoop: any EventLoop,
        _ handler: @escaping (BodyStreamResult) -> EventLoopFuture<Void>
    ) {
        wrappedBody.drain { [actualByteCount, maxAllowedSize] part in
            switch part {
            case .buffer(let buffer):
                let newTotal =
                    actualByteCount.loadThenWrappingIncrement(
                        by: Int64(buffer.readableBytes),
                        ordering: .acquiringAndReleasing
                    ) + Int64(buffer.readableBytes)

                // Enforce size limit
                if newTotal > maxAllowedSize {
                    let error = Abort(
                        .payloadTooLarge,
                        reason: """
                            Upload exceeded maximum size. \
                            Received \(newTotal) bytes, maximum allowed is \(maxAllowedSize) bytes.
                            """
                    )
                    return eventLoop.makeFailedFuture(error)
                }

                return handler(part)

            case .error, .end:
                return handler(part)
            }
        }
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        let body: Request.Body
        let actualByteCount: ManagedAtomic<Int64>
        let maxAllowedSize: Int64
        private var iterator: Request.Body.AsyncIterator?

        init(
            body: Request.Body,
            actualByteCount: ManagedAtomic<Int64>,
            maxAllowedSize: Int64
        ) {
            self.body = body
            self.actualByteCount = actualByteCount
            self.maxAllowedSize = maxAllowedSize
            self.iterator = body.makeAsyncIterator()
        }

        mutating func next() async throws -> ByteBuffer? {
            guard let buffer = try await iterator?.next() else {
                return nil
            }

            let newTotal =
                actualByteCount.loadThenWrappingIncrement(
                    by: Int64(buffer.readableBytes),
                    ordering: .acquiringAndReleasing
                ) + Int64(buffer.readableBytes)

            if newTotal > maxAllowedSize {
                throw Abort(
                    .payloadTooLarge,
                    reason: """
                        Upload exceeded maximum size. \
                        Received \(newTotal) bytes, maximum allowed is \(maxAllowedSize) bytes.
                        """
                )
            }

            return buffer
        }
    }
}

// Make it conformable to AsyncSequence for easy iteration
extension ByteCountingBody: AsyncSequence {
    typealias Element = ByteBuffer

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(
            body: wrappedBody,
            actualByteCount: actualByteCount,
            maxAllowedSize: maxAllowedSize
        )
    }
}
