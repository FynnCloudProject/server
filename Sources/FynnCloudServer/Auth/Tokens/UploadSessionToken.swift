import JWT
import Vapor


struct UploadSessionToken: JWTPayload, Authenticatable {
    var exp: ExpirationClaim  // Expiration (24 hours)
    var iat: IssuedAtClaim  // Issued at

    var sessionID: UUID
    var fileID: UUID
    var uploadID: String

    var userID: UUID
    var filename: String
    var contentType: String
    var totalSize: Int64
    var maxChunkSize: Int64
    var parentID: UUID?
    var lastModified: Int64?
    var createdAt: Int64?
    var isUpdate: Bool?
    var reservationID: String?

    func verify(using algorithm: some JWTAlgorithm) async throws {
        try self.exp.verifyNotExpired()
    }
}
