import Foundation
import Vapor

struct SubscriptionController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let adminProtected = routes.grouped("api", "admin").grouped(
            UserPayloadAuthenticator(), UserPayload.guardMiddleware(), AdminMiddleware())
        adminProtected.get("subscription", use: getSubscription)
        adminProtected.put("subscription", use: setSubscription)
    }

    /// Returns metadata about the active subscription. The full key is never exposed -
    /// only the last few characters are returned via `maskedKey`.
    func getSubscription(req: Request) async throws -> SubscriptionInfoResponse {
        let info = try await req.application.subscription.info()
        return Self.makeResponse(info)
    }

    /// Sets/replaces the subscription key. The token is cryptographically verified
    /// before it is persisted.
    func setSubscription(req: Request) async throws -> SubscriptionInfoResponse {
        let input = try req.content.decode(SetSubscriptionRequest.self)
        let token = input.token.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !token.isEmpty else {
            throw Abort(.badRequest, reason: "Subscription token must not be empty.")
        }

        try await req.application.subscription.update(
            token: token, redis: req.redis)

        let info = try await req.application.subscription.info()
        return Self.makeResponse(info)
    }

    private static func makeResponse(
        _ info: (payload: SubscriptionKey, token: String, managedByEnvironment: Bool)?
    ) -> SubscriptionInfoResponse {
        guard let info else {
            return SubscriptionInfoResponse(
                hasSubscription: false,
                managedByEnvironment: false,
                tier: nil,
                expiresAt: nil,
                maxUsers: nil,
                maskedKey: nil,
                isExpired: nil)
        }

        let expiresAt = info.payload.expiration.value
        return SubscriptionInfoResponse(
            hasSubscription: true,
            managedByEnvironment: info.managedByEnvironment,
            tier: info.payload.tier,
            expiresAt: ISO8601DateFormatter().string(from: expiresAt),
            maxUsers: info.payload.maxUsers,
            maskedKey: Self.maskToken(info.token),
            isExpired: expiresAt < Date())
    }

    /// Masks a token so only the last few characters remain visible.
    private static func maskToken(_ token: String, visible: Int = 10) -> String {
        let suffix = String(token.suffix(visible))
        return String(repeating: "\u{2022}", count: 8) + suffix
    }
}
