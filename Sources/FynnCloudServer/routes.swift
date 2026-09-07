import Fluent
import Vapor

func routes(_ app: Application) throws {
    let authController = AuthController()
    let fileController = FileController()
    let metaController = MetaController()
    let settingsController = SettingsController()
    let adminController = AdminController()
    let syncController = SyncController()
    let userController = UserController()
    let shareController = ShareController()
    let debugController = DebugController()
    let subscriptionController = SubscriptionController()
    let wopiController = WopiController()
    let officeController = OfficeController()
    let webdavController = WebDAVController()
    let totpController = TOTPController()
    let passkeyController = PasskeyController()
    let aiController = AIController()

    let apiGroup = app.grouped(RateLimitMiddleware(category: .api))

    try apiGroup.register(collection: authController)
    try apiGroup.register(collection: fileController)
    try apiGroup.register(collection: metaController)
    try apiGroup.register(collection: settingsController)
    try apiGroup.register(collection: adminController)
    try apiGroup.register(collection: syncController)
    try apiGroup.register(collection: userController)
    try apiGroup.register(collection: shareController)
    try apiGroup.register(collection: subscriptionController)
    try apiGroup.register(collection: wopiController)
    try apiGroup.register(collection: officeController)
    try apiGroup.register(collection: totpController)
    try apiGroup.register(collection: passkeyController)
    try apiGroup.register(collection: aiController)
    if !app.environment.isRelease {
        try apiGroup.register(collection: debugController)
    }

    // WebDAV (Basic auth, own path space) - registered outside the API rate-limit group.
    try app.register(collection: webdavController)
}
