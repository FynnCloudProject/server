import Fluent
import Vapor

extension Request {
    func getFullUser() async throws -> User {
        let payload = try auth.require(UserPayload.self)
        let userID = try payload.getID()
        guard let user = try await User.find(userID, on: db) else {
            throw Abort(.notFound, reason: "User not found").localized("error.unauthorized")
        }
        return user
    }
}
