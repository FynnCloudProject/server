import Fluent
import Vapor

extension Request {
    func getFullUser() async throws -> User {
        let payload = try auth.require(UserPayload.self)
        let userID = try payload.getID()
        guard
            let user = try await User.query(on: db)
                .filter(\.$id == userID)
                .with(\.$groups)
                .first()
        else {
            throw Abort(.notFound, reason: "User not found").localized("error.unauthorized")
        }
        return user
    }
}
