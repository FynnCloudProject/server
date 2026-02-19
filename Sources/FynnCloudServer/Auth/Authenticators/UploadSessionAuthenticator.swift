import JWT
import Vapor

// MARK: - Upload Session Authenticator

struct UploadSessionAuthenticator: AsyncBearerAuthenticator {
    func authenticate(bearer: BearerAuthorization, for request: Request) async throws {
        let token = try await request.jwt.verify(bearer.token, as: UploadSessionToken.self)
        request.auth.login(token)
    }
}
