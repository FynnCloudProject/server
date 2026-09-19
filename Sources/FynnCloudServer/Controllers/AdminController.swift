import Fluent
import Queues
import Redis
import Vapor

/// Admin operational diagnostics: server health alerts and scheduled-job status.
struct AdminController: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        let admin = routes.grouped("api").grouped(
            UserPayloadAuthenticator(), UserPayload.guardMiddleware(), AdminMiddleware())
        admin.get("alerts", use: alerts)
        admin.get("scheduled-jobs", use: scheduledJobs)
        admin.post("scheduled-jobs", ":id", "trigger", use: triggerScheduledJob)
        admin.post("scheduled-jobs", ":id", "run", use: triggerScheduledJob)
        admin.post("sso", "sync-groups", use: syncSSOGroups)
        admin.post("sso", "sync-users", use: syncSSOUsers)
        admin.post("ai", "test", use: testAIConnection)
        admin.post("ai", "test-embedding", use: testEmbeddingConnection)
        admin.post("ai", "reindex", use: reindexEmbeddings)
        admin.post("mail", "test", use: testMailConnection)
    }

    func scheduledJobs(req: Request) async throws -> ScheduledJobsResponse {
        // Best-effort: a missing marker only means "last run unknown".
        let uploadCleanupLastRun = try? await req.redis.get(
            "scheduled_job:upload_cleanup:last_run", as: String.self
        ).get()
        let quotaRecalcLastRun = try? await req.redis.get(
            "scheduled_job:quota_recalculation:last_run", as: String.self
        ).get()
        let tokenCleanupLastRun = try? await req.redis.get(
            "scheduled_job:expired_token_cleanup:last_run", as: String.self
        ).get()
        let trashCleanupLastRun = try? await req.redis.get(
            "scheduled_job:trash_cleanup:last_run", as: String.self
        ).get()
        let ldapGroupSyncLastRun = try? await req.redis.get(
            "scheduled_job:ldap_group_sync:last_run", as: String.self
        ).get()
        let ldapUserSyncLastRun = try? await req.redis.get(
            "scheduled_job:ldap_user_sync:last_run", as: String.self
        ).get()
        let syncLogPruneLastRun = try? await req.redis.get(
            "scheduled_job:sync_log_prune:last_run", as: String.self
        ).get()

        let jobs = [
            ScheduledJobStatus(
                id: "upload_cleanup",
                name: "Upload Cleanup",
                schedule: "Hourly at :00",
                lastRun: uploadCleanupLastRun
            ),
            ScheduledJobStatus(
                id: "quota_recalculation",
                name: "Quota Recalculation",
                schedule: "Hourly at :30",
                lastRun: quotaRecalcLastRun
            ),
            ScheduledJobStatus(
                id: "expired_token_cleanup",
                name: "Expired Token Cleanup",
                schedule: "Daily at 01:00",
                lastRun: tokenCleanupLastRun
            ),
            ScheduledJobStatus(
                id: "trash_cleanup",
                name: "Trash Cleanup",
                schedule: "Daily at 02:00",
                lastRun: trashCleanupLastRun
            ),
            ScheduledJobStatus(
                id: "sync_log_prune",
                name: "Sync Log Prune",
                schedule: "Daily at 03:00",
                lastRun: syncLogPruneLastRun
            ),
            ScheduledJobStatus(
                id: "ldap_group_sync",
                name: "LDAP Group Sync",
                schedule: "Every 15 minutes",
                lastRun: ldapGroupSyncLastRun
            ),
            ScheduledJobStatus(
                id: "ldap_user_sync",
                name: "LDAP User Sync",
                schedule: "Every 15 minutes",
                lastRun: ldapUserSyncLastRun
            ),
        ]
        return ScheduledJobsResponse(jobs: jobs)
    }

    func triggerScheduledJob(req: Request) async throws -> HTTPStatus {
        guard let jobId = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing task ID")
        }

        let context = QueueContext(
            queueName: .default,
            configuration: req.application.queues.configuration,
            application: req.application,
            logger: req.logger,
            on: req.eventLoop
        )

        switch jobId {
        case "upload_cleanup":
            try await UploadCleanupJob().run(context: context)
        case "quota_recalculation":
            try await QuotaRecalculationJob().run(context: context)
        case "expired_token_cleanup":
            try await ExpiredTokenCleanupJob().run(context: context)
        case "trash_cleanup":
            try await TrashCleanupJob().run(context: context)
        case "sync_log_prune":
            try await SyncLogPruneJob().run(context: context)
        case "ldap_group_sync":
            try await LDAPGroupSyncJob().run(context: context)
        case "ldap_user_sync":
            try await LDAPUserSyncJob().run(context: context)
        default:
            throw Abort(.notFound, reason: "Task '\(jobId)' not found")
        }

        let adminID = try? req.auth.require(UserPayload.self).getID()
        req.logger(subsystem: .admin).info(
            "Admin manually triggered scheduled job",
            metadata: [
                "admin_user_id": .stringConvertible(adminID ?? UUID()),
                "job_id": .string(jobId),
            ]
        )

        return .ok
    }

    func syncSSOGroups(req: Request) async throws -> LDAPGroupCatalogSyncResult {
        let adminID = try? req.auth.require(UserPayload.self).getID()
        req.logger(subsystem: .admin).info(
            "Admin triggered SSO group catalog sync",
            metadata: ["admin_user_id": .stringConvertible(adminID ?? UUID())]
        )
        let service = LDAPGroupCatalogSyncService(
            app: req.application, db: req.db, logger: req.logger)
        return try await service.run()
    }

    func syncSSOUsers(req: Request) async throws -> LDAPUserCatalogSyncResult {
        let adminID = try? req.auth.require(UserPayload.self).getID()
        req.logger(subsystem: .admin).info(
            "Admin triggered SSO user catalog sync",
            metadata: ["admin_user_id": .stringConvertible(adminID ?? UUID())]
        )
        let service = LDAPUserCatalogSyncService(
            app: req.application, db: req.db, logger: req.logger)
        return try await service.run()
    }

    func alerts(req: Request) async throws -> ServerAlertsResponse {
        let config = req.application.config
        let isProduction = req.application.environment == .production
        var alerts: [ServerAlert] = []

        if config.isJwtSecretDefault {
            alerts.append(
                ServerAlert(
                    key: LocalizationKeys.Admin.Alerts.JwtSecretDefault,
                    severity: .critical,
                    message:
                        "No JWT secret is set, so a new random one is used on every restart - this signs out all users whenever the server restarts. Set a fixed JWT_SECRET."
                ))
        }

        let ldap = req.application.ssoConfig.ldap
        if ldap.enabled, let bindDN = ldap.bindDN, !bindDN.isEmpty,
            (ldap.bindPassword ?? "").isEmpty
        {
            alerts.append(
                ServerAlert(
                    key: LocalizationKeys.Admin.Alerts.LdapDefaultPassword,
                    severity: .critical,
                    message:
                        "LDAP is configured with a Bind DN but no Bind Password. Set LDAP_BIND_PASSWORD to a strong, unique value."
                ))
        }

        if case .s3(_, let aws) = config.storage, aws.accessKey.isEmpty || aws.secretKey.isEmpty {
            alerts.append(
                ServerAlert(
                    key: LocalizationKeys.Admin.Alerts.S3CredentialsMissing,
                    severity: .critical,
                    message:
                        "Object storage is enabled but its credentials are missing. Set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY so file storage keeps working."
                ))
        }

        if (try? await req.redis.ping().get()) == nil {
            alerts.append(
                ServerAlert(
                    key: LocalizationKeys.Admin.Alerts.RedisUnreachable,
                    severity: .warning,
                    message:
                        "Redis isn't responding. Sessions, rate limiting and scheduled-job tracking may not work correctly. Check REDIS_URL and that Redis is running."
                ))
        }

        // SSO Configuration Checks
        let oidcEnabled = (try? await req.application.settings.get(AppSettings.OidcEnabled.self)) ?? AppSettings.OidcEnabled.defaultValue
        if oidcEnabled {
            let issuer = ((try? await req.application.settings.get(AppSettings.OidcIssuerURL.self)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let clientID = ((try? await req.application.settings.get(AppSettings.OidcClientID.self)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if issuer.isEmpty || clientID.isEmpty {
                alerts.append(
                    ServerAlert(
                        key: LocalizationKeys.Admin.Alerts.OidcMisconfigured,
                        severity: .warning,
                        message:
                            "Single Sign-On (OIDC) is enabled but missing required configuration (Issuer URL or Client ID)."
                    ))
            }
        }

        let ldapEnabled = (try? await req.application.settings.get(AppSettings.LdapEnabled.self)) ?? AppSettings.LdapEnabled.defaultValue
        if ldapEnabled {
            let host = ((try? await req.application.settings.get(AppSettings.LdapHost.self)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let baseDN = ((try? await req.application.settings.get(AppSettings.LdapBaseDN.self)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if host.isEmpty || baseDN.isEmpty {
                alerts.append(
                    ServerAlert(
                        key: LocalizationKeys.Admin.Alerts.LdapMisconfigured,
                        severity: .warning,
                        message:
                            "LDAP authentication is enabled but missing required connection settings (Host or Base DN)."
                    ))
            }
        }

        // AI & Embeddings Configuration Checks
        let aiEnabled = (try? await req.application.settings.get(AppSettings.AiEnabled.self)) ?? AppSettings.AiEnabled.defaultValue
        if aiEnabled {
            let aiUrl = ((try? await req.application.settings.get(AppSettings.AiApiUrl.self)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let aiKey = ((try? await req.application.settings.get(AppSettings.AiApiKey.self)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let isOpenAI = aiUrl.contains("openai.com")
            if aiUrl.isEmpty || (isOpenAI && aiKey.isEmpty) {
                alerts.append(
                    ServerAlert(
                        key: LocalizationKeys.Admin.Alerts.AiMisconfigured,
                        severity: .warning,
                        message:
                            "AI assistant is enabled but missing required configuration (API key or URL). Configure your provider in AI Settings."
                    ))
            }
        }

        let embeddingEnabled = (try? await req.application.settings.get(AppSettings.EmbeddingEnabled.self)) ?? AppSettings.EmbeddingEnabled.defaultValue
        if embeddingEnabled {
            let embUrl = ((try? await req.application.settings.get(AppSettings.EmbeddingUrl.self)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if embUrl.isEmpty {
                alerts.append(
                    ServerAlert(
                        key: LocalizationKeys.Admin.Alerts.EmbeddingsMisconfigured,
                        severity: .warning,
                        message:
                            "Vector embeddings are enabled, but the embedding runner URL is empty. Semantic search may be unavailable."
                    ))
            }
        }

        // Production-specific checks
        if isProduction {
            if case .sqlite = config.database {
                alerts.append(
                    ServerAlert(
                        key: LocalizationKeys.Admin.Alerts.SqliteInProduction,
                        severity: .warning,
                        message:
                            "SQLite is in use. For production traffic, switch to PostgreSQL for better reliability under load."
                    ))
            }

            if case .local = config.storage {
                alerts.append(
                    ServerAlert(
                        key: LocalizationKeys.Admin.Alerts.LocalStorageInProduction,
                        severity: .info,
                        message:
                            "Files are stored on the local disk. For production deployments, S3-compatible object storage is recommended."
                    ))
            }

            if config.corsAllowedOrigins.isEmpty {
                alerts.append(
                    ServerAlert(
                        key: LocalizationKeys.Admin.Alerts.CorsAllowAll,
                        severity: .warning,
                        message:
                            "CORS currently allows requests from any origin. Limit CORS_ALLOWED_ORIGINS to the domains you trust."
                    ))
            }

            if req.headers.first(name: "x-forwarded-proto") ?? req.url.scheme != "https" {
                alerts.append(
                    ServerAlert(
                        key: LocalizationKeys.Admin.Alerts.HttpNotHttps,
                        severity: .warning,
                        message:
                            "The instance isn't being served over HTTPS. Enable HTTPS so traffic stays encrypted in transit."
                    ))
            }

            if !config.rateLimitEnabled {
                alerts.append(
                    ServerAlert(
                        key: LocalizationKeys.Admin.Alerts.RateLimitDisabled,
                        severity: .warning,
                        message:
                            "Rate limiting is turned off. Enable RATE_LIMIT_ENABLED to help protect against brute-force and abuse."
                    ))
            }

            if config.frontendURL.contains("localhost") {
                alerts.append(
                    ServerAlert(
                        key: LocalizationKeys.Admin.Alerts.FrontendUrlLocalhost,
                        severity: .warning,
                        message:
                            "FRONTEND_URL is still set to localhost. Set it to your public address so email links, sharing and CORS work correctly."
                    ))
            }

            let registrationEnabled = (try? await req.application.settings.get(AppSettings.RegistrationEnabled.self)) ?? AppSettings.RegistrationEnabled.defaultValue
            if registrationEnabled {
                alerts.append(
                    ServerAlert(
                        key: LocalizationKeys.Admin.Alerts.OpenRegistrationInProduction,
                        severity: .info,
                        message:
                            "Public user registration is enabled on this production instance. Anyone with network access can register an account."
                    ))
            }
        }

        let effectiveAppName =
            (try? await req.application.settings.get(AppSettings.AppName.self))
            ?? AppSettings.AppName.defaultValue
        if effectiveAppName == "FynnCloud" {
            alerts.append(
                ServerAlert(
                    key: LocalizationKeys.Admin.Alerts.InstanceNameDefault,
                    severity: .info,
                    message:
                        "You're still using the default instance name, 'FynnCloud'. You can customize your instance name and branding in Admin Settings."
                ))
        }

        if let subInfo = try? await req.application.subscription.info() {
            let now = Date()
            let expDate = subInfo.payload.expiration.value
            if now > expDate {
                alerts.append(
                    ServerAlert(
                        key: LocalizationKeys.Admin.Alerts.SubscriptionInGracePeriod,
                        severity: .warning,
                        message:
                            "Your subscription has expired and is currently in its 7-day grace period. Renew your subscription to prevent service interruption."
                    ))
            }
        }

        if let maxUsers = await req.application.subscription.effectiveMaxUsers() {
            let userCount = try await User.query(on: req.db).count()
            if userCount >= maxUsers {
                let hasSub = await req.application.subscription.hasSubscription()
                let msg =
                    hasSub
                    ? "You've reached the maximum number of users (\(userCount)/\(maxUsers)). Upgrade your subscription to add more."
                    : "You've reached the free user limit (\(userCount)/\(maxUsers)). Add a subscription key to register more."
                alerts.append(
                    ServerAlert(
                        key: LocalizationKeys.Admin.Alerts.UserLimitReached,
                        severity: .warning,
                        message: msg
                    ))
            }
        }

        return ServerAlertsResponse(alerts: alerts)
    }

    // MARK: - AI & Embeddings Operations

    struct TestAIResponse: Content {
        let success: Bool
        let latencyMs: Int?
        let model: String?
        let message: String?
        let error: String?
    }

    func testAIConnection(req: Request) async throws -> TestAIResponse {
        let settings = req.application.settings
        let url = try await settings.get(AppSettings.AiApiUrl.self)
        let apiKey = try await settings.get(AppSettings.AiApiKey.self)
        let model = try await settings.get(AppSettings.AiModel.self)

        guard !url.isEmpty else {
            return TestAIResponse(
                success: false,
                latencyMs: 0,
                model: model,
                message: nil,
                error: "AI API URL is required."
            )
        }

        let endpoint = AIService.resolveChatEndpoint(for: url)

        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/json")
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            headers.bearerAuthorization = BearerAuthorization(token: key)
        }

        struct MiniMessage: Content {
            let role: String
            let content: String
        }
        struct MiniChatRequest: Content {
            let model: String
            let messages: [MiniMessage]
            let max_tokens: Int
        }

        let testBody = MiniChatRequest(
            model: model,
            messages: [MiniMessage(role: "user", content: "ping")],
            max_tokens: 5
        )

        let start = Date()
        do {
            let res = try await req.client.post(endpoint, headers: headers) { clientReq in
                try clientReq.content.encode(testBody)
            }
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)

            if res.status == .ok {
                return TestAIResponse(
                    success: true,
                    latencyMs: elapsedMs,
                    model: model,
                    message: "Connection successful (\(elapsedMs)ms)",
                    error: nil
                )
            } else {
                let responseBody = res.body.map { String(buffer: $0) } ?? ""
                let errorMsg =
                    !responseBody.isEmpty
                    ? "HTTP \(res.status.code): \(responseBody.prefix(300))"
                    : "Server returned HTTP \(res.status.code) (\(res.status.reasonPhrase))"
                return TestAIResponse(
                    success: false,
                    latencyMs: elapsedMs,
                    model: model,
                    message: nil,
                    error: errorMsg
                )
            }
        } catch {
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            return TestAIResponse(
                success: false,
                latencyMs: elapsedMs,
                model: model,
                message: nil,
                error: "\(error)"
            )
        }
    }

    struct TestEmbeddingResponse: Content {
        let success: Bool
        let latencyMs: Int?
        let dimensions: Int?
        let model: String?
        let message: String?
        let error: String?
    }

    func testEmbeddingConnection(req: Request) async throws -> TestEmbeddingResponse {
        let settings = req.application.settings
        let url = try await settings.get(AppSettings.EmbeddingUrl.self)
        let apiKey = try await settings.get(AppSettings.EmbeddingApiKey.self)
        let model = try await settings.get(AppSettings.EmbeddingModel.self)

        guard !url.isEmpty else {
            return TestEmbeddingResponse(
                success: false,
                latencyMs: 0,
                dimensions: nil,
                model: model,
                message: nil,
                error: "Embedding service URL is required."
            )
        }

        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let service = EmbeddingService(
            client: req.client,
            url: url,
            apiKey: key.isEmpty ? nil : key,
            model: model,
            logger: req.logger
        )

        let start = Date()
        do {
            let vector = try await service.getTextEmbedding(
                for: "test query", promptName: "query", timeout: 15)
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            return TestEmbeddingResponse(
                success: true,
                latencyMs: elapsedMs,
                dimensions: vector.count,
                model: model,
                message:
                    "Successfully generated \(vector.count)-dimensional vector (\(elapsedMs)ms)",
                error: nil
            )
        } catch {
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            return TestEmbeddingResponse(
                success: false,
                latencyMs: elapsedMs,
                dimensions: nil,
                model: model,
                message: nil,
                error: "\(error)"
            )
        }
    }

    struct ReindexEmbeddingsResponse: Content {
        let queued: Int
        let message: String
    }

    func reindexEmbeddings(req: Request) async throws -> ReindexEmbeddingsResponse {
        let isEnabled = try await req.application.settings.get(AppSettings.EmbeddingEnabled.self)
        guard isEnabled else {
            throw Abort(.badRequest, reason: "Embeddings are currently disabled.")
        }

        let files = try await FileMetadata.query(on: req.db)
            .filter(\.$deletedAt == nil)
            .all()

        for file in files {
            guard let fileID = file.id else { continue }
            try await req.application.queues.queue.dispatch(
                ProcessFileEmbeddingJob.self,
                FileEmbeddingPayload(fileID: fileID)
            )
        }

        let adminID = try? req.auth.require(UserPayload.self).getID()
        req.logger(subsystem: .admin).info(
            "Admin triggered bulk file reindexing",
            metadata: [
                "admin_user_id": .stringConvertible(adminID ?? UUID()),
                "count": .stringConvertible(files.count),
            ]
        )

        return ReindexEmbeddingsResponse(
            queued: files.count,
            message: "Queued \(files.count) files for embedding generation"
        )
    }

    struct TestMailRequest: Content {
        let recipient: String?
    }

    struct TestMailResponse: Content {
        let success: Bool
        let message: String
    }

    func testMailConnection(req: Request) async throws -> TestMailResponse {
        let payload = try? req.content.decode(TestMailRequest.self)
        let adminID = try req.auth.require(UserPayload.self).getID()
        let admin = try await User.find(adminID, on: req.db)

        let recipientStr: String
        if let custom = payload?.recipient?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            recipientStr = custom
        } else if let email = admin?.email, !email.isEmpty {
            recipientStr = email
        } else {
            throw Abort(.badRequest, reason: "No recipient email provided and logged-in admin user has no email address.")
        }

        let appName = (try? await req.application.settings.get(AppSettings.AppName.self)) ?? AppSettings.AppName.defaultValue

        let fields = [
            "recipient": recipientStr,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "driver": Environment.get("MAIL_DRIVER") ?? "default",
            "appName": appName
        ]

        do {
            try await req.mail.sendTemplate(
                id: "test_email",
                to: EmailAddress(address: recipientStr, name: admin?.displayName ?? admin?.username),
                subject: "Test Email from \(appName)",
                fields: fields
            )
            req.logger(subsystem: .admin).info("Admin triggered test email successfully sent to \(recipientStr)")
            return TestMailResponse(success: true, message: "Test email successfully sent to \(recipientStr)")
        } catch {
            req.logger(subsystem: .admin).error("Failed to send test email to \(recipientStr): \(error)")
            throw Abort(.internalServerError, reason: "Failed to send test email: \(error)")
        }
    }
}
