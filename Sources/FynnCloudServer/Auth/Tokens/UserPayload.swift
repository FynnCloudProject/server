import JWT
import Vapor

// MARK: - User JWT Payload

struct UserPayload: JWTPayload, Authenticatable {
    enum CodingKeys: String, CodingKey {
        case subject = "sub"
        case expiration = "exp"
        case grantID = "grant_id"
        case jti = "jti"
    }

    var subject: SubjectClaim
    var expiration: ExpirationClaim
    var grantID: UUID
    var jti: IDClaim

    func getID() throws -> UUID {
        guard let uuid = UUID(uuidString: subject.value) else {
            throw Abort(.badRequest, reason: "Invalid subject claim").localized(
                "error.unauthorized")
        }
        return uuid
    }

    func verify(using algorithm: some JWTAlgorithm) async throws {
        try self.expiration.verifyNotExpired()
    }
}
