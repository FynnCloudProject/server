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
                    severity: .critical,
                    message:
                        "JWT secret is volatile. Users will be logged out on every server restart. Set JWT_SECRET."
                ))
        }

        if config.ldapEnabled && config.ldapConfig.password == "JonSn0w" {
            alerts.append(
                ServerAlert(
                    key: "ldapDefaultPassword",
                    severity: .critical,
                    message: "LDAP is using a default password. This is a high-security risk."
                ))
        }

        if isProduction {
            if case .sqlite = config.database {
                alerts.append(
                    ServerAlert(
                        key: "sqliteInProduction",
                        severity: .warning,
                        message:
                            "SQLite is active. For high-concurrency production use, PostgreSQL is recommended."
                    ))
            }

            if config.corsAllowedOrigins.isEmpty {
                alerts.append(
                    ServerAlert(
                        key: "corsAllowAll",
                        severity: .warning,
                        message: "CORS allows all origins. Restrict this to your front-end domain."
                    ))
            }

            if req.headers.first(name: "x-forwarded-proto") ?? req.url.scheme != "https" {
                alerts.append(
                    ServerAlert(
                        key: "httpNotHttps",
                        severity: .warning,
                        message:
                            "Insecure connection detected. Ensure your proxy or load balancer enforces HTTPS."
                    ))
            }
        }

        if config.appName == "FynnCloud" {
            alerts.append(
                ServerAlert(
                    key: "appNameDefault",
                    severity: .info,
                    message: "You are using the default branding ('FynnCloud')."
                ))
        }

        return ServerAlertsResponse(alerts: alerts)
    }
}
