import Vapor

struct ServerInfo: Content {
    let appName: String
    let version: String
    let maxFileSize: Int64
    let environment: String
    let primaryColor: String

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

    func boot(routes: any RoutesBuilder) throws {
        let api = routes.grouped("api")
        api.get("info", use: info)

        let protected = api.grouped(UserPayloadAuthenticator(), UserPayload.guardMiddleware())
        protected.get("alerts", use: alerts)
    }

    func info(req: Request) async throws -> ServerInfo {
        return ServerInfo(
            appName: req.application.config.appName,
            version: req.application.config.appVersion,
            maxFileSize: Int64(req.application.routes.defaultMaxBodySize.value),
            environment: req.application.environment.name,
            primaryColor: req.application.config.primaryColor.rawValue
        )
    }

    func alerts(req: Request) async throws -> ServerAlertsResponse {
        let config = req.application.config
        let isProduction = req.application.environment == .production
        var alerts: [ServerAlert] = []

        if config.isJwtSecretDefault {
            alerts.append(
                ServerAlert(
                    key: "jwtSecretDefault",
                    severity: .warning,
                    message:
                        "JWT secret is using a random default — tokens will be invalidated on every server restart. Set the JWT_SECRET environment variable."
                ))
        }

        if isProduction || true {
            if case .sqlite = config.database {
                alerts.append(
                    ServerAlert(
                        key: "sqliteInProduction",
                        severity: .critical,
                        message:
                            "SQLite is being used in a production environment. Consider switching to PostgreSQL."
                    ))
            }

            if config.corsAllowedOrigins.isEmpty {
                alerts.append(
                    ServerAlert(
                        key: "corsAllowAll",
                        severity: .warning,
                        message:
                            "CORS is configured to allow all origins in production. Restrict allowed origins."
                    ))
            }
        }

        if config.ldapEnabled && config.ldapConfig.password == "JonSn0w" {
            alerts.append(
                ServerAlert(
                    key: "ldapDefaultPassword",
                    severity: .warning,
                    message:
                        "LDAP is configured with the default bind password. Change LDAP_PASSWORD."
                ))
        }

        if config.appName == "FynnCloud" {
            alerts.append(
                ServerAlert(
                    key: "appNameDefault",
                    severity: .info,
                    message:
                        "App name is using the default value 'FynnCloud'. Set APP_NAME to customize."
                ))
        }

        // If http not https
        if req.version != .http2 {
            alerts.append(
                ServerAlert(
                    key: "httpNotHttps",
                    severity: .warning,
                    message:
                        "HTTP is not recommended for production. Consider using HTTPS."
                ))
        }

        return ServerAlertsResponse(
            alerts: alerts)
    }
}
