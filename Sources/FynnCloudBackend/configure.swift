import Fluent
import FluentPostgresDriver
import FluentSQLiteDriver
import JWT
import Leaf
import NIOSSL
import SotoCore
import Vapor

public func configure(_ app: Application) async throws {
    // CORS configuration
    let corsConfiguration = CORSMiddleware.Configuration(
        // Load allowed origins from environment variable
        allowedOrigin: app.environment.isRelease
            ? .any([
                Environment.get("CORS_ALLOWED_ORIGINS") ?? "http://localhost:3000"
            ])
            : .all,
        allowedMethods: [.GET, .POST, .PUT, .OPTIONS, .DELETE, .PATCH],
        allowedHeaders: [
            .accept, .authorization, .contentType, .origin, .xRequestedWith, .userAgent,
            .accessControlAllowOrigin,
        ],
        allowCredentials: false
    )
    let cors = CORSMiddleware(configuration: corsConfiguration)
    app.middleware.use(cors, at: .beginning)

    // app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    // If database url is set use the provided database (duh), currently only postgres is supported
    if let databaseURL = Environment.get("DATABASE_URL"), let url = URL(string: databaseURL) {
        let databaseConfig = try SQLPostgresConfiguration.init(url: url)
        app.databases.use(.postgres(configuration: databaseConfig), as: .psql)
    } else {
        app.databases.use(.sqlite(.file("db.sqlite")), as: .sqlite)
    }

    // Setup AWS CLient with lifecycle handler
    let awsClient = AWSClient(
        credentialProvider: .static(
            accessKeyId: Environment.get("AWS_ACCESS_KEY_ID") ?? "",
            secretAccessKey: Environment.get("AWS_SECRET_ACCESS_KEY") ?? ""),
        retryPolicy: .default,
        options: .init(),
        logger: app.logger
    )
    app.services.awsClient.use { _ in awsClient }
    app.lifecycle.use(AWSLifecycleHandler())

    // Determine storage driver (Local vs S3)
    if let bucket = Environment.get("S3_BUCKET") {
        app.storageConfig = .init(driver: .s3(bucket: bucket))
    } else {
        app.storageConfig = .init(
            driver: .local(
                path: Environment.get("STORAGE_PATH") ?? app.directory.workingDirectory + "Storage/"
            ))
    }

    // Register migrations
    app.migrations.add(CreateInitialMigration())
    app.migrations.add(CreateSyncLog())
    app.migrations.add(CreateOAuthCode())
    app.migrations.add(AddClientIdAndStateToOAuthCode())
    app.migrations.add(CreateOAuthGrant())
    app.migrations.add(UpdateGrantForRotation())

    // Set max body size to 15gb, we should probably switch to chunked uploads
    // TODO: Switch to chunked uploads
    app.routes.defaultMaxBodySize = "15gb"
    try await app.autoMigrate()  // Auto migrate database

    // Generate random jwt secret if not set
    let jwtSecret = Environment.get("JWT_SECRET") ?? [UInt8].random(count: 32).base64
    await app.jwt.keys.add(hmac: HMACKey.init(from: jwtSecret), digestAlgorithm: .sha256)
    try routes(app)
}
