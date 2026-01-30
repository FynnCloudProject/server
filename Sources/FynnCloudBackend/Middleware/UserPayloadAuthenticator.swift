import Fluent
import JWT
import Vapor

struct UserPayloadAuthenticator: AsyncRequestAuthenticator {
    func authenticate(request: Request) async throws {
        // 1. Extract token from Bearer header, Cookie, or Query param
        let token =
            request.headers.bearerAuthorization?.token
            ?? request.cookies["accessToken"]?.string
            ?? request.query[String.self, at: "accessToken"]

        guard let token = token else {
            request.logger.debug("No token found in headers, cookies, or query")
            return
        }

        do {
            // Verify the JWT signature and expiration
            let payload = try await request.jwt.verify(token, as: UserPayload.self)

            // REVOCATION CHECK: Verify the Grant still exists in the database
            let grantExists =
                try await OAuthGrant.query(on: request.db)
                .filter(\.$id == payload.grantID)
                .first() != nil

            guard grantExists else {
                request.logger.warning("Token valid, but Grant \(payload.grantID) was revoked")
                return
            }

            // 4. Success: "Login" the payload
            request.auth.login(payload)
            request.logger.debug(
                "User authenticated successfully via Grant",
                metadata: [
                    "userID": .string(payload.subject.value),
                    "grantID": .string(payload.grantID.uuidString),
                ]
            )
        } catch {
            request.logger.warning("Token verification failed: \(error)")
        }
    }
}
