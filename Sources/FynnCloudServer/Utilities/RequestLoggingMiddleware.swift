import Vapor

/// Logs one line per completed request (method, path, status, duration, client) - replaces
/// Vapor's default `RouteLoggingMiddleware`, which only logs the incoming request line and
/// gives no way to tell whether a request succeeded, how long it took, or who made it.
public struct RequestLoggingMiddleware: AsyncMiddleware {
    public init() {}

    public func respond(to req: Request, chainingTo next: any AsyncResponder) async throws
        -> Response
    {
        let start = Date()
        let response = try await next.respond(to: req)
        let durationMs = Date().timeIntervalSince(start) * 1000

        let path = req.url.path.removingPercentEncoding ?? req.url.path
        let metadata: Logger.Metadata = [
            "method": .string(req.method.rawValue),
            "path": .string(path),
            "status": .stringConvertible(response.status.code),
            "duration_ms": .stringConvertible((durationMs * 100).rounded() / 100),
            "client_ip": .string(req.clientIP),
        ]

        let logger = req.logger(subsystem: .http)
        let message = "\(req.method.rawValue) \(path) -> \(response.status.code)"
        switch response.status.code {
        case 500...:
            logger.error("\(message)", metadata: metadata)
        case 400..<500:
            logger.warning("\(message)", metadata: metadata)
        default:
            logger.info("\(message)", metadata: metadata)
        }

        return response
    }
}
