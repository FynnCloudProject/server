import Vapor

struct ServerInfo: Content {
    let appName: String
    let version: String
    let maxFileSize: Int64
    let environment: String
    let primaryColor: String
}

struct SettingsResponse: Content {
    let appName: String
    let primaryColor: String
}

struct UpdateSettingsRequest: Content {
    var appName: String?
    var primaryColor: String?
}

enum AlertSeverity: String, Content {
    case info
    case warning
    case critical
}

struct ServerAlert: Content {
    let key: String
    let severity: AlertSeverity
    let message: String
}

struct ServerAlertsResponse: Content {
    let alerts: [ServerAlert]
}

struct MetaController: RouteCollection {

    static let allowedKeys: Set<String> = ["appName", "primaryColor"]

    func boot(routes: any RoutesBuilder) throws {
        let api = routes.grouped("api")
        api.get("info", use: info)

        let adminProtected = api.grouped(
            UserPayloadAuthenticator(), UserPayload.guardMiddleware(), AdminMiddleware())
        adminProtected.get("alerts", use: alerts)
        adminProtected.get("settings", use: getSettings)
        adminProtected.put("settings", use: updateSettings)
    }

    func info(req: Request) async throws -> ServerInfo {
        let settings = req.application.settings
        let config = req.application.config

        let appName = try await settings.get("appName") ?? config.appName
        let primaryColor = try await settings.get("primaryColor") ?? config.primaryColor.rawValue

        return ServerInfo(
            appName: appName,
            version: config.appVersion,
            maxFileSize: Int64(req.application.routes.defaultMaxBodySize.value),
            environment: req.application.environment.name,
            primaryColor: primaryColor
        )
    }

    func getSettings(req: Request) async throws -> SettingsResponse {
        let settings = req.application.settings
        let config = req.application.config

        return SettingsResponse(
            appName: try await settings.get("appName") ?? config.appName,
            primaryColor: try await settings.get("primaryColor") ?? config.primaryColor.rawValue
        )
    }

    func updateSettings(req: Request) async throws -> SettingsResponse {
        let input = try req.content.decode(UpdateSettingsRequest.self)
        let settings = req.application.settings
        let config = req.application.config

        if let appName = input.appName {
            try await settings.set("appName", value: appName)
        }

        if let primaryColor = input.primaryColor {
            guard AppConfig.TailwindColor(rawValue: primaryColor) != nil else {
                throw Abort(.badRequest, reason: "Invalid color: \(primaryColor)")
            }
            try await settings.set("primaryColor", value: primaryColor)
        }

        return SettingsResponse(
            appName: try await settings.get("appName") ?? config.appName,
            primaryColor: try await settings.get("primaryColor") ?? config.primaryColor.rawValue
        )
    }

    func alerts(req: Request) async throws -> ServerAlertsResponse {
        let config = req.application.config
        let isProduction = req.application.environment == .production
        let isDevelopment = req.application.environment == .development
        var alerts: [ServerAlert] = []

        if config.isJwtSecretDefault {
            alerts.append(
                ServerAlert(
                    key: LocalizationKeys.Admin.Alerts.JwtSecretDefault,
                    severity: .critical,
                    message:
                        "JWT secret is volatile. Users will be logged out on every server restart. Set JWT_SECRET."
                ))
        }

        if config.ldapEnabled && config.ldapConfig.password == "JonSn0w" {
            alerts.append(
                ServerAlert(
                    key: LocalizationKeys.Admin.Alerts.LdapDefaultPassword,
                    severity: .critical,
                    message: "LDAP is using a default password. This is a high-security risk."
                ))
        }

        if isProduction || isDevelopment {
            if case .sqlite = config.database {
                alerts.append(
                    ServerAlert(
                        key: LocalizationKeys.Admin.Alerts.SqliteInProduction,
                        severity: .warning,
                        message:
                            "SQLite is active. For high-concurrency production use, PostgreSQL is recommended."
                    ))
            }

            if config.corsAllowedOrigins.isEmpty {
                alerts.append(
                    ServerAlert(
                        key: LocalizationKeys.Admin.Alerts.CorsAllowAll,
                        severity: .warning,
                        message: "CORS allows all origins. Restrict this to your front-end domain."
                    ))
            }

            if req.headers.first(name: "x-forwarded-proto") ?? req.url.scheme != "https" {
                alerts.append(
                    ServerAlert(
                        key: LocalizationKeys.Admin.Alerts.HttpNotHttps,
                        severity: .warning,
                        message:
                            "Insecure connection detected. Ensure your proxy or load balancer enforces HTTPS."
                    ))
            }
        }

        let effectiveAppName =
            (try? await req.application.settings.get("appName")) ?? config.appName
        if effectiveAppName == "FynnCloud" {
            alerts.append(
                ServerAlert(
                    key: LocalizationKeys.Admin.Alerts.AppNameDefault,
                    severity: .info,
                    message: "You are using the default branding ('FynnCloud')."
                ))
        }

        return ServerAlertsResponse(alerts: alerts)
    }
}
