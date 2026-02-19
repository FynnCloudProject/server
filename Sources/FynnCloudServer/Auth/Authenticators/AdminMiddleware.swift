import Fluent
import Vapor

struct AdminMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response
    {
        let user = try await request.getFullUser()
        guard user.isAdmin else {
            throw Abort(.forbidden, reason: "Administrator access required").localized(
                "error.forbidden")
        }
        return try await next.respond(to: request)
    }
}
