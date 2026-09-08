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
    let isAppNameManagedByEnv: Bool
    let isPrimaryColorManagedByEnv: Bool

    init(
        appName: String,
        version: String,
        maxFileSize: Int64,
        environment: String,
        primaryColor: String,
        officeEnabled: Bool,
        aiEnabled: Bool,
        registrationEnabled: Bool,
        ssoProviders: [SSOProviderInfo],
        isSetupRequired: Bool,
        logoUpdatedAt: String?,
        iconUpdatedAt: String?,
        showLogoAndName: Bool,
        svgColorMode: String,
        hostname: String,
        nodeName: String?,
        isAppNameManagedByEnv: Bool = false,
        isPrimaryColorManagedByEnv: Bool = false
    ) {
        self.appName = appName
        self.version = version
        self.maxFileSize = maxFileSize
        self.environment = environment
        self.primaryColor = primaryColor
        self.officeEnabled = officeEnabled
        self.aiEnabled = aiEnabled
        self.registrationEnabled = registrationEnabled
        self.ssoProviders = ssoProviders
        self.isSetupRequired = isSetupRequired
        self.logoUpdatedAt = logoUpdatedAt
        self.iconUpdatedAt = iconUpdatedAt
        self.showLogoAndName = showLogoAndName
        self.svgColorMode = svgColorMode
        self.hostname = hostname
        self.nodeName = nodeName
        self.isAppNameManagedByEnv = isAppNameManagedByEnv
        self.isPrimaryColorManagedByEnv = isPrimaryColorManagedByEnv
    }

    enum CodingKeys: String, CodingKey {
        case appName, version, maxFileSize, environment, primaryColor
        case officeEnabled, aiEnabled, registrationEnabled, ssoProviders
        case isSetupRequired, logoUpdatedAt, iconUpdatedAt, showLogoAndName
        case svgColorMode, hostname, nodeName
        case isAppNameManagedByEnv, isPrimaryColorManagedByEnv
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appName = try container.decode(String.self, forKey: .appName)
        version = try container.decode(String.self, forKey: .version)
        maxFileSize = try container.decode(Int64.self, forKey: .maxFileSize)
        environment = try container.decode(String.self, forKey: .environment)
        primaryColor = try container.decode(String.self, forKey: .primaryColor)
        officeEnabled = try container.decode(Bool.self, forKey: .officeEnabled)
        aiEnabled = try container.decode(Bool.self, forKey: .aiEnabled)
        registrationEnabled = try container.decode(Bool.self, forKey: .registrationEnabled)
        ssoProviders = try container.decode([SSOProviderInfo].self, forKey: .ssoProviders)
        isSetupRequired = try container.decode(Bool.self, forKey: .isSetupRequired)
        logoUpdatedAt = try container.decodeIfPresent(String.self, forKey: .logoUpdatedAt)
        iconUpdatedAt = try container.decodeIfPresent(String.self, forKey: .iconUpdatedAt)
        showLogoAndName = try container.decode(Bool.self, forKey: .showLogoAndName)
        svgColorMode = try container.decode(String.self, forKey: .svgColorMode)
        hostname = try container.decode(String.self, forKey: .hostname)
        nodeName = try container.decodeIfPresent(String.self, forKey: .nodeName)
        isAppNameManagedByEnv = try container.decodeIfPresent(Bool.self, forKey: .isAppNameManagedByEnv) ?? false
        isPrimaryColorManagedByEnv = try container.decodeIfPresent(Bool.self, forKey: .isPrimaryColorManagedByEnv) ?? false
    }
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
