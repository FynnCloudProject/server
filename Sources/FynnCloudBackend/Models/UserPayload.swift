import JWT
import Vapor

struct UserPayload: JWTPayload, Authenticatable {
    // Maps the longer Swift property names to the
    // shortened keys used in the JWT payload.
    enum CodingKeys: String, CodingKey {
        case subject = "sub"
        case expiration = "exp"
        case grantID = "grant_id"
        case jti = "jti"
    }

    // The "sub" (subject) claim identifies the principal that is the
    // subject of the JWT.
    var subject: SubjectClaim

    // The "exp" (expiration time) claim identifies the expiration time on
    // or after which the JWT MUST NOT be accepted for processing.
    var expiration: ExpirationClaim

    var grantID: UUID

    var jti: IDClaim

    // Run any additional verification logic beyond
    // signature verification here.
    // Since we have an ExpirationClaim, we will
    // call its verify method.

    func getID() throws -> UUID {
        guard let uuid = UUID(uuidString: subject.value) else {
            throw Abort(.badRequest, reason: "Invalid subject claim")
        }
        return uuid
    }

    func verify(using algorithm: some JWTAlgorithm) async throws {
        try self.expiration.verifyNotExpired()
    }

}
