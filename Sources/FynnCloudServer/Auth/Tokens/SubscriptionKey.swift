import JWT
import Vapor

struct SubscriptionKey: JWTPayload {
    enum CodingKeys: String, CodingKey {
        case subject = "sub"
        case issuer = "iss"
        case issuedAt = "iat"
        case expiration = "exp"
        case subscriptionID = "sid"
        case customerID = "cid"
        case tier = "tier"
        case licenseID = "lid"
        case maxUsers = "max_users"
    }

    var subject: SubjectClaim
    var issuer: IssuerClaim
    var issuedAt: IssuedAtClaim
    var expiration: ExpirationClaim
    var subscriptionID: String
    var customerID: String
    var tier: String
    var licenseID: String
    var maxUsers: Int?

    func verify(using algorithm: some JWTAlgorithm) async throws {
        // Expiration is checked explicitly with a grace period leeway in SubscriptionService.get
    }
}
