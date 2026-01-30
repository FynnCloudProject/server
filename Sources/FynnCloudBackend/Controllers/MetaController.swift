import Vapor

struct ServerInfo: Content {
    let version: String
    let maxFileSize: Int64
    let environment: String

}
struct MetaController: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        let api = routes.grouped("api")
        api.get("info", use: info)
    }

    func info(req: Request) async throws -> ServerInfo {
        return ServerInfo(
            version: "1.0.0",
            maxFileSize: Int64(req.application.routes.defaultMaxBodySize.value),
            environment: req.application.environment.name,
        )
    }
}
