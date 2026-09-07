import JWT
import Vapor


/// Authenticates WOPI requests via the `access_token` query parameter (WOPI passes the token in the URL,
/// not as a bearer header). The token is a short-lived JWT signed by this host.
struct WopiTokenAuthenticator: AsyncRequestAuthenticator {
    func authenticate(request: Request) async throws {
        guard let token = try? request.query.get(String.self, at: "access_token"), !token.isEmpty else {
            return
        }
        guard let payload = try? await request.jwt.verify(token, as: WopiAccessToken.self) else {
            return
        }
        request.auth.login(payload)
    }
}
