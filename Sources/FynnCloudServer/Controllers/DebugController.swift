import Vapor

struct DebugController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let api = routes.grouped("api", "debug")
        let protected = api.grouped(UserPayloadAuthenticator(), UserPayload.guardMiddleware())

        protected.get(use: index)
        protected.get("reset-quota", use: resetQuota)
    }

    func index(req: Request) -> String {
        return "Debug"
    }

    func resetQuota(req: Request) async throws -> String {
        let user = try await req.getFullUser()
        user.currentStorageUsage = 0
        try await user.save(on: req.db)
        return "Quota reset"
    }
}
