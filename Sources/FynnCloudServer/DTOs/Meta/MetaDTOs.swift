import Vapor

// MARK: - Meta DTOs

struct ServerInfo: Content {
    let appName: String
    let version: String
    let maxFileSize: Int64
    let environment: String
    let primaryColor: String
    let officeEnabled: Bool
    let aiEnabled: Bool
    let registrationEnabled: Bool
    let ssoProviders: [SSOProviderInfo]
    let isSetupRequired: Bool
    let logoUpdatedAt: String?
    let iconUpdatedAt: String?
    let showLogoAndName: Bool
    let svgColorMode: String
    let hostname: String
    let nodeName: String?
}

/// Public metadata for an SSO login option shown on the login screen.
struct SSOProviderInfo: Content {
    /// `"ldap"` (username/password form) or `"oidc:<key>"` (redirect button).
    let id: String
    let kind: String
    let displayName: String
    /// For redirect providers: the URL the login button should navigate to (start endpoint).
    let startPath: String?
}

typealias SettingsResponse = [String: ManagedSetting<String>]

struct UploadBrandingLogoRequest: Content {
    var logo: File
}

struct UploadBrandingIconRequest: Content {
    var icon: File
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

struct ScheduledJobStatus: Content {
    let id: String
    let name: String
    let schedule: String
    let lastRun: String?
}

struct ScheduledJobsResponse: Content {
    let jobs: [ScheduledJobStatus]
}
