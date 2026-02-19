import JWT
import Vapor

// MARK: - Upload Session JWT Payload

struct UploadSessionToken: JWTPayload, Authenticatable {
    // JWT Standard Claims
    var exp: ExpirationClaim  // Expiration (24 hours)
    var iat: IssuedAtClaim  // Issued at

    // Session & file identification
    var sessionID: UUID
    var fileID: UUID
    var uploadID: String

    // Authorization & metadata (needed for stateless completion)
    var userID: UUID
    var filename: String
    var contentType: String
    var totalSize: Int64
    var maxChunkSize: Int64
    var parentID: UUID?
    var lastModified: Int64?

    func verify(using algorithm: some JWTAlgorithm) async throws {
        try self.exp.verifyNotExpired()
    }
}
