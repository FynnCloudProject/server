import Fluent
import FluentPostgresDriver
import FluentSQLiteDriver
import JWT
import NIOSSL
import SotoCore
import Vapor

public func configure(_ app: Application) async throws {
    // Load Global Configuration
    let config = AppConfig.load(for: app)
    app.config = config

    // CORS Configuration
    let corsConfiguration = CORSMiddleware.Configuration(
        allowedOrigin: app.environment == .production
            ? .any(config.corsAllowedOrigins)
            : .all,
        allowedMethods: [.GET, .POST, .PUT, .OPTIONS, .DELETE, .PATCH],
        allowedHeaders: [
            .accept, .authorization, .contentType, .origin, .xRequestedWith, .userAgent,
            .accessControlAllowOrigin,
        ],
        allowCredentials: false
    )
    app.middleware.use(CORSMiddleware(configuration: corsConfiguration), at: .beginning)

    // Database Selection (Postgres vs SQLite)
    switch config.database {
    case .postgres(let pgConfig):
        app.databases.use(.postgres(configuration: pgConfig), as: .psql)
    case .sqlite(let filename):
        app.databases.use(.sqlite(.file(filename)), as: .sqlite)
    }

    // Storage Driver Selection (Local vs S3)
    switch config.storage {
    case .s3(let bucket):
        app.logger.info("Using S3 storage with bucket: \(bucket)")
        let awsClient = AWSClient(
            credentialProvider: .static(
                accessKeyId: config.aws.accessKey,
                secretAccessKey: config.aws.secretKey
            ),
            retryPolicy: .default,
            options: .init(),
            logger: app.logger
        )
        app.services.awsClient.use { _ in awsClient }
        app.lifecycle.use(AWSLifecycleHandler())
        app.storageConfig = .init(driver: .s3(bucket: bucket))
    case .local(let path):
        app.logger.info("Using local storage with path: \(path)")
        app.storageConfig = .init(driver: .local(path: path))
    }

    // Limits
    app.routes.defaultMaxBodySize = config.maxBodySize

    // Error Middleware
    app.middleware.use(
        ErrorMiddleware { req, error in
            let status: HTTPResponseStatus
            let reason: String
            let headers: HTTPHeaders
            let localizationKey: String?

            if let localizedError = error as? LocalizedAbort {
                status = localizedError.status
                reason = localizedError.reason
                headers = localizedError.headers
                localizationKey = localizedError.localizationKey
            } else if let abort = error as? (any AbortError) {
                status = abort.status
                reason = abort.reason
                headers = abort.headers
                localizationKey = "error.generic"
            } else {
                status = .internalServerError
                reason =
                    req.application.environment == .production
                    ? "An unexpected error occurred."
                    : String(reflecting: error)
                headers = [:]
                localizationKey = "error.generic"
            }

            let response = Response(status: status, headers: headers)
            var body: [String: String] = ["error": "true", "reason": reason]
            if let key = localizationKey { body["localizationKey"] = key }
            try? response.content.encode(body)
            return response
        })

    // JWT Configuration
    await app.jwt.keys.add(hmac: HMACKey(from: config.jwtSecret), digestAlgorithm: .sha256)

    // Migrations
    app.migrations.add(CreateInitialMigration())
    app.migrations.add(CreateSyncLog())
    app.migrations.add(CreateOAuthCode())
    app.migrations.add(AddClientIdAndStateToOAuthCode())
    app.migrations.add(CreateOAuthGrant())
    app.migrations.add(UpdateGrantForRotation())
    app.migrations.add(CreateMultipartUploadSessions())

    // Auto Migrate & register Routes
    try await app.autoMigrate()
    try routes(app)
}
