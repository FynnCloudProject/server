import Vapor

// Abstraction for file storage to make it easy to switch between different storage providers
protocol FileStorageProvider: Sendable {
    func save(stream: Request.Body, id: UUID, size: Int64, on eventLoop: any EventLoop) async throws
    func getResponse(for id: UUID, on eventLoop: any EventLoop) async throws -> Response
    func delete(id: UUID) async throws
    func exists(id: UUID) async throws -> Bool
}
