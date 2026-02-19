import Fluent
import FluentPostgresDriver
import FluentSQLiteDriver
import JWT
import SotoCore
import SotoS3
import Vapor

public func configure(_ app: Application) async throws {
    let config = AppConfig.load(for: app)
    app.config = config

    app.routes.defaultMaxBodySize = config.maxBodySize
    configureCORS(app, config: config)
    configureErrorMiddleware(app)

    switch config.database {
    case .postgres(let pgConfig):
        app.databases.use(.postgres(configuration: pgConfig), as: .psql)
    case .sqlite(let filename):
        app.databases.use(.sqlite(.file(filename)), as: .sqlite)
    }

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
        app.fileStorage = S3StorageProvider(
            s3: S3(
                client: awsClient, region: .init(awsRegionName: config.aws.region),
                endpoint: config.aws.endpoint), bucket: bucket)

    case .local(let path):
        app.logger.info("Using local storage with path: \(path)")
        app.fileStorage = LocalFileSystemProvider(storageDirectory: path)
    }

    if config.ldapEnabled {
        let ldapService = LDAPService(configuration: config.ldapConfig)
        app.services.ldap.use { _ in ldapService }
        app.lifecycle.use(LDAPLifecycleHandler())
        app.logger.info("Connecting to LDAP...")
        do {
            try await ldapService.connect()
            app.logger.info("✅ LDAP Connected Successfully")
        } catch {
            app.logger.error("❌ Failed to connect to LDAP: \(error)")
        }
    } else {
        app.logger.info("LDAP is disabled")
    }

    await app.jwt.keys.add(hmac: HMACKey(from: config.jwtSecret), digestAlgorithm: .sha256)

    app.migrations.add(CreateInitialMigration())
    app.migrations.add(CreateSyncLog())
    app.migrations.add(CreateOAuthCode())
    app.migrations.add(AddClientIdAndStateToOAuthCode())
    app.migrations.add(CreateOAuthGrant())
    app.migrations.add(UpdateGrantForRotation())
    app.migrations.add(CreateMultipartUploadSessions())
    app.migrations.add(CreateGroups())
    app.migrations.add(CreateAppSettings())
    app.migrations.add(UpdateUnlimitedTier())
    app.migrations.add(AddIsAdminToGroups())
    app.migrations.add(LowercaseUsernames())
    app.migrations.add(AddIndicesToFileMetadata())

    try await app.autoMigrate()

    app.settings = SettingsService(database: app.db)

    try routes(app)
}

// MARK: - Middleware

private func configureCORS(_ app: Application, config: AppConfig) {
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
}
private func configureErrorMiddleware(_ app: Application) {
    let environment = app.environment

    app.middleware.use(
        ErrorMiddleware { req, error in
            let status: HTTPResponseStatus
            let reason: String
            let source: ErrorSource
            var headers: HTTPHeaders
            let localizationKey: String?

            switch error {
            case let localizedError as LocalizedAbort:
                (reason, status, headers, source) = (
                    localizedError.reason, localizedError.status, localizedError.headers, .capture()
                )
                localizationKey = localizedError.localizationKey

            case let debugAbort as (any DebuggableError & AbortError):
                (reason, status, headers, source) = (
                    debugAbort.reason, debugAbort.status, debugAbort.headers,
                    debugAbort.source ?? .capture()
                )
                localizationKey = "error.generic"

            case let abort as any AbortError:
                (reason, status, headers, source) = (
                    abort.reason, abort.status, abort.headers, .capture()
                )
                localizationKey = "error.generic"

            case let debugErr as any DebuggableError:
                (reason, status, headers, source) = (
                    debugErr.reason, .internalServerError, [:], debugErr.source ?? .capture()
                )
                localizationKey = "error.generic"

            default:
                reason = environment.isRelease ? "Something went wrong." : String(describing: error)
                (status, headers, source) = (.internalServerError, [:], .capture())
                localizationKey = "error.generic"
            }

            req.logger.report(
                error: error,
                metadata: [
                    "method": "\(req.method.rawValue)",
                    "url": "\(req.url.string)",
                    "userAgent": .array(req.headers["User-Agent"].map { "\($0)" }),
                ],
                file: source.file,
                function: source.function,
                line: source.line)

            let body: Response.Body
            do {
                var errorBody: [String: String] = ["error": "true", "reason": reason]
                if let key = localizationKey { errorBody["localizationKey"] = key }

                let encoder = try ContentConfiguration.global.requireEncoder(for: .json)
                var byteBuffer = req.byteBufferAllocator.buffer(capacity: 0)
                try encoder.encode(errorBody, to: &byteBuffer, headers: &headers)

                body = .init(buffer: byteBuffer, byteBufferAllocator: req.byteBufferAllocator)
            } catch {
                body = .init(
                    string: "Oops: \(String(describing: error))\nWhile encoding error: \(reason)",
                    byteBufferAllocator: req.byteBufferAllocator)
                headers.contentType = .plainText
            }

            return Response(status: status, headers: headers, body: body)
        })
}
