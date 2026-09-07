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
configureRequestLogging(app)
    configureCORS(app, config: config)
    configureErrorMiddleware(app)

    // Configure global JSON decoder/encoder date strategies for ISO8601 dates with/without fractional seconds
    let jsonDecoder = JSONDecoder()
    jsonDecoder.dateDecodingStrategy = .customISO8601
    ContentConfiguration.global.use(decoder: jsonDecoder, for: .json)

    let jsonEncoder = JSONEncoder()
    jsonEncoder.dateEncodingStrategy = .customISO8601
    ContentConfiguration.global.use(encoder: jsonEncoder, for: .json)

    // Increase HTTP client pool for embedding service requests
    app.http.client.configuration.connectionPool.concurrentHTTP1ConnectionsPerHostSoftLimit = 16
    app.http.client.configuration.timeout.connect = .seconds(10)
    app.http.client.configuration.timeout.read = .seconds(120)

    switch config.database {
    case .postgres(let pgConfig):
        app.databases.use(.postgres(configuration: pgConfig), as: .psql)
    case .sqlite(let filename):
        app.databases.use(.sqlite(.file(filename)), as: .sqlite)
    }

    switch config.storage {
    case .s3(let bucket):
        app.logger.info("Using S3 storage with bucket: \(bucket)]
        )
        var httpClientConfig = HTTPClient.Configuration()
        httpClientConfig.httpVersion = .http1Only
        let httpClient = HTTPClient(
            eventLoopGroupProvider: .shared(app.eventLoopGroup),
            configuration: httpClientConfig
        )
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

let subscriptionKeys = JWTKeyCollection()
    // Load ES256 subscription public key from bundled resources
    let pubKeyFilename = FileManager.default.fileExists(atPath: app.directory.resourcesDirectory + "subscription_pub.pem") 
        ? "subscription_pub.pem" 
        : "license_pub.pem"
    let subscriptionPubKeyPath = app.directory.resourcesDirectory + pubKeyFilename
    do {
        let pemString = try String(contentsOfFile: subscriptionPubKeyPath)
        let ecdsaKey = try ES256PublicKey(pem: pemString)
        await subscriptionKeys.add(ecdsa: ecdsaKey)
        app.logger(subsystem: .system).debug(
            "Loaded ES256 subscription public key",
            metadata: ["path": .string(subscriptionPubKeyPath)]
        )
    } catch {
        app.logger(subsystem: .system).error(
            "Failed to load ES256 subscription public key",
            metadata: [
                "path": .string(subscriptionPubKeyPath),
                "error": .string("\(error)"),
            ]
        )
        throw error
    }

    app.subscription = SubscriptionService(
        envSubscriptionKey: config.subscriptionKey, keys: subscriptionKeys, database: app.db)

    app.migrations.add(CreateInitialMigration())
app.migrations.add(AddDisplayNameToUsers())
    app.migrations.add(CreateSyncLog())
    app.migrations.add(CreateOAuthCode())
    app.migrations.add(AddClientIdAndStateToOAuthCode())
    app.migrations.add(CreateOAuthGrant())
    app.migrations.add(UpdateGrantForRotation())
app.migrations.add(AddGracePeriodToOAuthGrant())
    app.migrations.add(AddLastUsedAtToOAuthGrant())
    app.migrations.add(AddIPAddressToOAuthGrant())
    app.migrations.add(CreateMultipartUploadSessions())
    app.migrations.add(CreateGroups())
    app.migrations.add(CreateAppSettings())
    app.migrations.add(UpdateUnlimitedTier())
    app.migrations.add(AddIsAdminToGroups())
app.migrations.add(AddAvatarUpdatedAtToUsers())
    app.migrations.add(LowercaseUsernames())
    app.migrations.add(AddIndicesToFileMetadata())
    app.migrations.add(AddTrashGroupToFileMetadata())
app.migrations.add(RewriteSyncInfrastructure())
    app.migrations.add(CreateShareLinks())
    app.migrations.add(CreateFilenameSearchIndex())
    app.migrations.add(AddContentHashToFileMetadata())
    app.migrations.add(CreateFileEmbeddings())
    app.migrations.add(UpdateEmbeddingDimension())
    app.migrations.add(AddHasThumbnailToFileMetadata())
    app.migrations.add(CreateSubscriptions())
    app.migrations.add(AddLinkTypeAndRequiresAuthToShareLink())
    app.migrations.add(AddAncestorIDsToFileMetadata())
    app.migrations.add(FixUniqueIndexPartialSoftDelete())
    app.migrations.add(AddAllUsersGroup())
    app.migrations.add(RenameEuroOfficeUrlSetting())
    app.migrations.add(CreateUserIdentities())
    app.migrations.add(AddSSOManagedToGroups())
    app.migrations.add(AddSourceToUserGroups())
    app.migrations.add(CreateUserTOTP())
    app.migrations.add(CreateUserTOTPRecoveryCode())
    app.migrations.add(DropRecoveryCodesFromUserTOTP())
    app.migrations.add(AddSSOSourceToGroups())
    app.migrations.add(RenameSSOSourceToSourceOnGroups())
    app.migrations.add(AddUploadedAtToFileMetadata())
    app.migrations.add(OverhaulSyncInfrastructure())
    app.migrations.add(CreateInternalShares())
    app.migrations.add(DropOAuthCodes())
    app.migrations.add(CreateUserFavorites())
    app.migrations.add(DropMultipartUploadSessions())
    app.migrations.add(AddFavoritesAndSharesToSyncTriggers())
    app.migrations.add(DropSyncTriggersMigration())
    app.migrations.add(CreateUserPasskeys())
    if Environment.get("AUTO_MIGRATE") == "true" {
        try await app.autoMigrate()
    }

    let poolOptions = RedisConfiguration.PoolOptions(
        maximumConnectionCount: .maximumActiveConnections(20),
        minimumConnectionCount: 2,
        connectionRetryTimeout: .seconds(2)
    )
    let redisConfig = try RedisConfiguration(url: config.redisURL, pool: poolOptions)

    app.redis.configuration = redisConfig
    app.redis(.pubsub).configuration = redisConfig

    // Redis is a hard dependency: quota admission, OIDC flow state and OAuth code exchange are
    // only correct with it, so refuse to boot rather than degrade invisibly.
    app.lifecycle.use(RedisPingLifecycleHandler(redisURL: config.redisURL))

    app.settings = SettingsService(database: app.db, redis: app.redis, logger: app.logger)

    // Resolve SSO providers from settings (ENV > DB) now that settings are available.
    await reloadSSOProviders(app)

    app.queues.use(.redis(redisConfig))
    app.queues.add(ProcessFileEmbeddingJob())
    app.queues.add(GenerateThumbnailJob())

    app.commands.use(ReindexFilesCommand(), as: "reindex-files")
    app.commands.use(GenerateThumbnailsCommand(), as: "generate-thumbnails")

    try routes(app)

    // MARK: - Server Runtime Startup
    // Skip background services and network connections when running CLI commands (e.g. migrate)
    guard !app.isCLICommand else { return }

    do {
        let subscription = try await app.subscription.get()
        app.logger(subsystem: .system).info(
            "Server booted with valid subscription key",
            metadata: [
                "tier": .string(subscription.tier.capitalized),
                "subscription_id": .string(subscription.subscriptionID),
            ]
        )
    } catch {
        app.logger(subsystem: .system).warning(
            "No valid subscription key active on startup",
            metadata: ["error": .string(error.localizedDescription)]
        )
    }

    app.lifecycle.use(PubSubLifecycleHandler())

    try app.queues.startInProcessJobs(on: .default)
    app.queues.schedule(UploadCleanupJob())
        .hourly()
        .at(0)
    app.queues.schedule(QuotaRecalculationJob())
        .hourly()
        .at(30)
    app.queues.schedule(SessionLastAccessFlushJob())
        .minutely()
    app.queues.schedule(ExpiredTokenCleanupJob())
        .daily()
        .at(1, 0)
    app.queues.schedule(TrashCleanupJob())
        .daily()
        .at(2, 0)
    app.queues.schedule(LDAPDirectorySyncJob())
        .every(minutes: 15)
    app.queues.schedule(SyncLogPruneJob())
        .daily()
        .at(3, 0)
    try app.queues.startScheduledJobs()
}

extension Application {
    /// Returns `true` if a CLI subcommand (like `migrate` or `reindex-files`) is being executed.
    var isCLICommand: Bool {
        guard let command = environment.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) else {
            return false
        }
        return command != "serve"
    }
}

// MARK: - Middleware

private func configureRequestLogging(_ app: Application) {
    // First access to app.middleware lazily adds Vapor's own RouteLoggingMiddleware (logs only
    // the incoming request line) + a default ErrorMiddleware; reset before that happens so
    // neither default gets registered, then add ours.
    app.middleware = .init()
    app.middleware.use(RequestLoggingMiddleware())
}

private func configureCORS(_ app: Application, config: ServerConfig) {
    let corsConfiguration = CORSMiddleware.Configuration(
        allowedOrigin: .any(config.corsAllowedOrigins),
        allowedMethods: [.GET, .POST, .PUT, .OPTIONS, .DELETE, .PATCH],
        allowedHeaders: [
            .accept, .authorization, .contentType, .origin, .xRequestedWith, .userAgent,
            .accessControlAllowOrigin,
        ],
        allowCredentials: true
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
let params: [String: String]?

            switch error {
            case let localizedError as LocalizedAbort:
                (reason, status, headers, source) = (
                    localizedError.reason, localizedError.status, localizedError.headers, .capture()
                )
                localizationKey = localizedError.localizationKey
params = localizedError.params

            case let debugAbort as (any DebuggableError & AbortError):
                (reason, status, headers, source) = (
                    debugAbort.reason, debugAbort.status, debugAbort.headers,
                    debugAbort.source ?? .capture()
                )
                localizationKey = nil
                params = nil

            case let abort as any AbortError:
                (reason, status, headers, source) = (
                    abort.reason, abort.status, abort.headers, .capture()
                )
                localizationKey = nil
                params = nil

            case let debugErr as any DebuggableError:
                (reason, status, headers, source) = (
                    debugErr.reason, .internalServerError, [:], debugErr.source ?? .capture()
                )
                localizationKey = nil
                params = nil

            default:
                reason = environment.isRelease ? "Something went wrong." : String(describing: error)
                (status, headers, source) = (.internalServerError, [:], .capture())
                localizationKey = nil
                params = nil
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
                struct ErrorBody: Encodable {
                    var error: Bool = true
                    var reason: String
                    var localizationKey: String?
                    var params: [String: String]?
                }
                let errorBody = ErrorBody(reason: reason, localizationKey: localizationKey, params: params)

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
