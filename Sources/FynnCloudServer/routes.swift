import Fluent
import Vapor

func routes(_ app: Application) throws {
    let authController = AuthController()
    let fileController = FileController()
    let metaController = MetaController()
    let syncController = SyncController()
    let userController = UserController()
    let debugController = DebugController()

    try app.register(collection: authController)
    try app.register(collection: fileController)
    try app.register(collection: metaController)
    try app.register(collection: syncController)
    try app.register(collection: userController)
    if !app.environment.isRelease {
        try app.register(collection: debugController)
    }
}
