import Vapor

struct UserController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let api = routes.grouped("api", "user")
        let protected = api.grouped(UserPayloadAuthenticator(), UserPayload.guardMiddleware())
        protected.get("me", use: me)
        protected.get("quotas", use: apiQuotas)
    }

    func me(req: Request) async throws -> User.Public {
        let user = try await req.getFullUser()
        return try user.toPublic()
    }

    func apiQuotas(req: Request) async throws -> QuotaDTO {
        let user = try await req.getFullUser()
        let tier = try await StorageTier.find(user.$tier.id, on: req.db)
        return QuotaDTO(
            used: user.currentStorageUsage, limit: tier?.limitBytes ?? 0,
            tierName: tier?.name ?? "No Tier")
    }
}
