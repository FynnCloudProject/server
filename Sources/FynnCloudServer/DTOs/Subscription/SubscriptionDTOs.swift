import Vapor

// MARK: - Subscription DTOs

struct SubscriptionInfoResponse: Content {
    let hasSubscription: Bool
    let managedByEnvironment: Bool
    let tier: String?
    let expiresAt: String?
    let maxUsers: Int?
    let maskedKey: String?
    let isExpired: Bool?
}

struct SetSubscriptionRequest: Content {
    let token: String
}
