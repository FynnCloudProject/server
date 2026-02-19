import Fluent
import Vapor

struct SyncController: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        let api = routes.grouped("api", "sync")

        let protected = api.grouped(UserPayloadAuthenticator(), UserPayload.guardMiddleware())
        protected.get("logs", use: index)
    }

    struct SyncLogRequest: Content {
        let after: Int64
    }
    struct SyncLogsResponse: Content {
        let logs: [SyncLog]
    }

    func index(req: Request) async throws -> SyncLogsResponse {
        let userID = try req.auth.require(UserPayload.self).getID()
        let queryParams = try req.query.decode(SyncLogRequest.self)

        let logs = try await SyncLog.query(on: req.db)
            .filter(\.$user.$id == userID)
            .filter(\.$seq > queryParams.after)
            .sort(\.$seq, .ascending)
            .all()

        return SyncLogsResponse(logs: logs)
    }
}
