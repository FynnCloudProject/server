import Fluent
import Vapor

struct ActivityController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let activities = routes.grouped("api", "activities")
            .grouped(UserPayloadAuthenticator(), UserPayload.guardMiddleware())

        activities.get(use: getUserTimeline)

        let fileActivities = routes.grouped("api", "files", ":fileID", "activity")
            .grouped(UserPayloadAuthenticator(), UserPayload.guardMiddleware())

        fileActivities.get(use: getFileActivity)
    }

    func getUserTimeline(req: Request) async throws -> ActivityResponse {
        let userID = try req.auth.require(UserPayload.self).getID()

        let page = req.query[Int.self, at: "page"] ?? 1
        let limit = req.query[Int.self, at: "limit"] ?? 50

        return try await req.activityService.fetchUserTimeline(
            on: req.db,
            userID: userID,
            page: page,
            limit: limit
        )
    }

    func getFileActivity(req: Request) async throws -> ActivityResponse {
        let userID = try req.auth.require(UserPayload.self).getID()

        guard let fileIDString = req.parameters.get("fileID"),
              let fileID = UUID(uuidString: fileIDString) else {
            throw Abort(.badRequest, reason: "Invalid file ID")
        }

        // Validate that user has at least read access to the file
        _ = try await req.fileAccess.validateAccess(fileID: fileID, userID: userID, required: .read)

        let page = req.query[Int.self, at: "page"] ?? 1
        let limit = req.query[Int.self, at: "limit"] ?? 50

        return try await req.activityService.fetchFileActivity(
            on: req.db,
            fileID: fileID,
            page: page,
            limit: limit
        )
    }
}
