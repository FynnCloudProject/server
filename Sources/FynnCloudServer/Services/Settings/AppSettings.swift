import Foundation
import Vapor

/// Registry of all dynamic application setting keys and lookup helper.
public enum AppSettings: CaseIterable {

    /// Logical grouping for related settings; mirrors the sections in the admin settings UI.
    public enum SettingGroup: String, CaseIterable, Codable, Sendable {
        case branding
        case documentEditing
        case access
        case storage
        case sso
        case ai
    }

    // MARK: - Branding

    public struct AppName: SettingKey {
        public static let key = "appName"
        public static let defaultValue = "FynnCloud"
        public static let envKey: String? = "APP_NAME"
    }

    public struct PrimaryColor: SettingKey {
        public static let key = "primaryColor"
        public static let defaultValue = "#007bff"
        public static let envKey: String? = "PRIMARY_COLOR"

        public static func validate(_ raw: String) throws -> String {
            let isPreset = ServerConfig.TailwindColor(rawValue: raw) != nil
            let isHex = raw.range(of: "^#?[0-9a-fA-F]{3,8}$", options: .regularExpression) != nil
            guard isPreset || isHex else {
                throw Abort(.badRequest, reason: "Invalid color: \(raw)")
            }
            return raw
        }
    }

    public struct CustomLogoUpdatedAt: SettingKey {
        public static let key = "customLogoUpdatedAt"
        public static let defaultValue = ""
        public static let envKey: String? = "CUSTOM_LOGO_UPDATED_AT"
    }

    public struct CustomLogoMimeType: SettingKey {
        public static let key = "customLogoMimeType"
        public static let defaultValue = ""
        public static let envKey: String? = "CUSTOM_LOGO_MIME_TYPE"
    }

    public struct CustomIconUpdatedAt: SettingKey {
        public static let key = "customIconUpdatedAt"
        public static let defaultValue = ""
        public static let envKey: String? = "CUSTOM_ICON_UPDATED_AT"
    }

    public struct CustomIconMimeType: SettingKey {
        public static let key = "customIconMimeType"
        public static let defaultValue = ""
        public static let envKey: String? = "CUSTOM_ICON_MIME_TYPE"
    }

    public struct ShowLogoAndName: SettingKey {
        public static let key = "showLogoAndName"
        public static let defaultValue = false
        public static let envKey: String? = "SHOW_LOGO_AND_NAME"
    }

    public struct SvgColorMode: SettingKey {
        public enum Mode: String, Codable, Sendable, LosslessStringConvertible {
            case original
            case monochrome
            case tinted

            public init?(_ description: String) { self.init(rawValue: description) }
            public var description: String { rawValue }
        }

        public static let key = "svgColorMode"
        public static let defaultValue = Mode.monochrome
        public static let envKey: String? = "SVG_COLOR_MODE"
    }

    // MARK: - Document Editing

    /// In-browser editing backend. Being an enum, invalid values are rejected automatically.
    public enum OfficeProviderKind: String, Codable, Sendable, LosslessStringConvertible {
        case eurooffice
        case wopi

        public init?(_ description: String) { self.init(rawValue: description) }
        public var description: String { rawValue }
    }

    /// Base URL of the EuroOffice document server used for in-browser editing. Empty disables the feature.
    public struct DocumentServerURL: SettingKey {
        public static let key = "documentServerUrl"
        public static let defaultValue = ""
        public static let envKey: String? = "DOCUMENT_SERVER_URL"
    }

    /// Office provider for in-browser editing: `eurooffice` (native DocsAPI) or `wopi` (WOPI host protocol).
    public struct OfficeProvider: SettingKey {
        public static let key = "officeProvider"
        public static let defaultValue = OfficeProviderKind.eurooffice
        public static let envKey: String? = "OFFICE_PROVIDER"
    }

    /// Shared secret with the EuroOffice document server (signs the native config + verifies save
    /// callbacks). Deliberately kept out of `groups`/`all` so it is never returned by the settings API;
    /// it is still resolved via ENV > DB > default. Empty disables JWT signing.
    public struct EuroOfficeJwtSecret: SettingKey {
        public static let key = "euroOfficeJwtSecret"
        public static let defaultValue = ""
        public static let envKey: String? = "EUROOFFICE_JWT_SECRET"
    }

    /// Public base URL where this FynnCloud server can be reached by the document server for WOPI callbacks.
    /// Deliberately kept out of `groups`/`all` if sensitive or included in documentEditing. Empty falls back to FRONTEND_URL.
    public struct WopiPublicURL: SettingKey {
        public static let key = "wopiPublicUrl"
        public static let defaultValue = ""
        public static let envKey: String? = "WOPI_PUBLIC_URL"
    }

    // MARK: - Access

    /// Whether new users may self-register via the public registration endpoint. The first-ever user
    /// (admin bootstrap) is always allowed regardless of this setting.
    public struct RegistrationEnabled: SettingKey {
        public static let key = "registrationEnabled"
        public static let defaultValue = true
        public static let envKey: String? = "REGISTRATION_ENABLED"
    }

    // MARK: - Storage

    /// Number of days a file stays in the trash before it is permanently deleted by the cleanup job.
    public struct TrashRetentionDays: RangedSettingKey {
        public static let key = "trashRetentionDays"
        public static let defaultValue = 30
        public static let envKey: String? = "TRASH_RETENTION_DAYS"
        public static let minValue: Int? = 1
        public static let maxValue: Int? = 3650
    }

    // MARK: - SSO (LDAP + OIDC)
    // Non-secret fields only. Secrets (LDAP bind password, OIDC client secret) are ENV-only and are
    // never exposed via the settings API - they are read directly from the environment at resolve time.

    public struct LdapEnabled: SettingKey {
        public static let key = "ldapEnabled"
        public static let defaultValue = false
        public static let envKey: String? = "LDAP_ENABLED"
    }
    public struct LdapHost: SettingKey {
        public static let key = "ldapHost"
        public static let defaultValue = "localhost"
        public static let envKey: String? = "LDAP_HOST"
    }
    public struct LdapPort: SettingKey {
        public static let key = "ldapPort"
        public static let defaultValue = ""
        public static let envKey: String? = "LDAP_PORT"
    }
    public struct LdapUseSSL: SettingKey {
        public static let key = "ldapUseSsl"
        public static let defaultValue = false
        public static let envKey: String? = "LDAP_USE_SSL"
    }
    public struct LdapBaseDN: SettingKey {
        public static let key = "ldapBaseDn"
        public static let defaultValue = ""
        public static let envKey: String? = "LDAP_BASE_DN"
    }
    public struct LdapBindDN: SettingKey {
        public static let key = "ldapBindDn"
        public static let defaultValue = ""
        public static let envKey: String? = "LDAP_BIND_DN"
    }
    public struct LdapUserFilter: SettingKey {
        public static let key = "ldapUserFilter"
        public static let defaultValue = "(uid={username})"
        public static let envKey: String? = "LDAP_USER_FILTER"
    }
    public struct LdapGroupBaseDN: SettingKey {
        public static let key = "ldapGroupBaseDn"
        public static let defaultValue = ""
        public static let envKey: String? = "LDAP_GROUP_BASE_DN"
    }
    public struct LdapGroupFilter: SettingKey {
        public static let key = "ldapGroupFilter"
        public static let defaultValue = ""
        public static let envKey: String? = "LDAP_GROUP_FILTER"
    }
    public struct LdapTrustEmail: SettingKey {
        public static let key = "ldapTrustEmail"
        public static let defaultValue = true
        public static let envKey: String? = "LDAP_TRUST_EMAIL"
    }
    public struct LdapUuidAttribute: SettingKey {
        public static let key = "ldapUuidAttribute"
        public static let defaultValue = "auto"
        public static let envKey: String? = "LDAP_UUID_ATTRIBUTE"
    }

    public struct OidcEnabled: SettingKey {
        public static let key = "oidcEnabled"
        public static let defaultValue = false
        public static let envKey: String? = "OIDC_ENABLED"
    }
    public struct OidcProviderKey: SettingKey {
        public static let key = "oidcProviderKey"
        public static let defaultValue = "main"
        public static let envKey: String? = "OIDC_PROVIDER_KEY"
    }
    public struct OidcDisplayName: SettingKey {
        public static let key = "oidcDisplayName"
        public static let defaultValue = "Single Sign-On"
        public static let envKey: String? = "OIDC_DISPLAY_NAME"
    }
    public struct OidcIssuerURL: SettingKey {
        public static let key = "oidcIssuerUrl"
        public static let defaultValue = ""
        public static let envKey: String? = "OIDC_ISSUER_URL"
    }
    public struct OidcClientID: SettingKey {
        public static let key = "oidcClientId"
        public static let defaultValue = ""
        public static let envKey: String? = "OIDC_CLIENT_ID"
    }
    public struct OidcScopes: SettingKey {
        public static let key = "oidcScopes"
        public static let defaultValue = "openid email profile"
        public static let envKey: String? = "OIDC_SCOPES"
    }
    public struct OidcGroupsClaim: SettingKey {
        public static let key = "oidcGroupsClaim"
        public static let defaultValue = "groups"
        public static let envKey: String? = "OIDC_GROUPS_CLAIM"
    }

    public struct SsoGroupImport: SettingKey {
        public static let key = "ssoGroupImport"
        public static let defaultValue = false
        public static let envKey: String? = "SSO_GROUP_IMPORT"
    }
    public struct SsoGroupAutoMatch: SettingKey {
        public static let key = "ssoGroupAutoMatch"
        public static let defaultValue = false
        public static let envKey: String? = "SSO_GROUP_AUTO_MATCH"
    }
    public struct SsoGroupPrefix: SettingKey {
        public static let key = "ssoGroupPrefix"
        public static let defaultValue = ""
        public static let envKey: String? = "SSO_GROUP_PREFIX"
    }
    public struct SsoGroupMap: SettingKey {
        public static let key = "ssoGroupMap"
        public static let defaultValue = ""
        public static let envKey: String? = "SSO_GROUP_MAP"
    }
    public struct SsoUserSync: SettingKey {
        public static let key = "ssoUserSync"
        public static let defaultValue = false
        public static let envKey: String? = "SSO_USER_SYNC"
    }
    public struct SsoAutoProvision: SettingKey {
        public static let key = "ssoAutoProvision"
        public static let defaultValue = true
        public static let envKey: String? = "SSO_AUTO_PROVISION"
    }

    public struct TrustedHeaderEnabled: SettingKey {
        public static let key = "trustedHeaderEnabled"
        public static let defaultValue = false
        public static let envKey: String? = "TRUSTED_HEADER_ENABLED"
    }
    public struct TrustedEmailHeader: SettingKey {
        public static let key = "trustedEmailHeader"
        public static let defaultValue = ""
        public static let envKey: String? = "TRUSTED_EMAIL_HEADER"
    }
    public struct TrustedNameHeader: SettingKey {
        public static let key = "trustedNameHeader"
        public static let defaultValue = ""
        public static let envKey: String? = "TRUSTED_NAME_HEADER"
    }
    public struct TrustedGroupsHeader: SettingKey {
        public static let key = "trustedGroupsHeader"
        public static let defaultValue = ""
        public static let envKey: String? = "TRUSTED_GROUPS_HEADER"
    }
    public struct TrustedRoleHeader: SettingKey {
        public static let key = "trustedRoleHeader"
        public static let defaultValue = ""
        public static let envKey: String? = "TRUSTED_ROLE_HEADER"
    }

    // MARK: - AI Assistant & Vector Embeddings

    public struct AiEnabled: SettingKey {
        public static let key = "aiEnabled"
        public static let defaultValue = true
        public static let envKey: String? = "AI_ENABLED"
    }

    public struct AiApiUrl: SettingKey {
        public static let key = "aiApiUrl"
        public static let defaultValue = "https://api.openai.com/v1/chat/completions"
        public static let envKey: String? = "AI_URL"

        public static var envValue: String? {
            if let val = Environment.get("AI_URL")?.trimmingCharacters(in: .whitespacesAndNewlines), !val.isEmpty {
                return val
            }
            if let val = Environment.get("OPENAI_BASE_URL")?.trimmingCharacters(in: .whitespacesAndNewlines), !val.isEmpty {
                return val
            }
            return nil
        }
    }

    public struct AiApiKey: SettingKey {
        public static let key = "aiApiKey"
        public static let defaultValue = ""
        public static let envKey: String? = "AI_API_KEY"

        public static var envValue: String? {
            if let val = Environment.get("AI_API_KEY")?.trimmingCharacters(in: .whitespacesAndNewlines), !val.isEmpty {
                return val
            }
            if let val = Environment.get("OPENAI_API_KEY")?.trimmingCharacters(in: .whitespacesAndNewlines), !val.isEmpty {
                return val
            }
            return nil
        }
    }

    public struct AiModel: SettingKey {
        public static let key = "aiModel"
        public static let defaultValue = "gpt-4o-mini"
        public static let envKey: String? = "AI_MODEL"
    }

    public struct AiMaxToolIterations: RangedSettingKey {
        public static let key = "aiMaxToolIterations"
        public static let defaultValue = 12
        public static let envKey: String? = "AI_MAX_TOOL_ITERATIONS"
        public static let minValue: Int? = 1
        public static let maxValue: Int? = 50
    }

    public struct RateLimitAi: RangedSettingKey {
        public static let key = "rateLimitAi"
        public static let defaultValue = 20
        public static let envKey: String? = "RATE_LIMIT_AI"
        public static let minValue: Int? = 1
        public static let maxValue: Int? = 1000
    }

    public struct EmbeddingEnabled: SettingKey {
        public static let key = "embeddingEnabled"
        public static let defaultValue = true
        public static let envKey: String? = "EMBEDDING_ENABLED"
    }

    public struct EmbeddingUrl: SettingKey {
        public static let key = "embeddingUrl"
        public static let defaultValue = "http://localhost:8000"
        public static let envKey: String? = "EMBEDDING_URL"
    }

    public struct EmbeddingApiKey: SettingKey {
        public static let key = "embeddingApiKey"
        public static let defaultValue = ""
        public static let envKey: String? = "EMBEDDING_API_KEY"
    }

    public struct EmbeddingModel: SettingKey {
        public static let key = "embeddingModel"
        public static let defaultValue = "jinaai/jina-clip-v2"
        public static let envKey: String? = "EMBEDDING_MODEL"
    }

    public struct SemanticSearchThreshold: RangedSettingKey {
        public static let key = "semanticSearchThreshold"
        public static let defaultValue = 0.75
        public static let envKey: String? = "SEMANTIC_SEARCH_THRESHOLD"
        public static let minValue: Double? = 0.0
        public static let maxValue: Double? = 1.0
    }

    // MARK: - Registry

    /// Public settings grouped by domain. This is the single source of truth for registration;
    /// `all` is derived from it. Hidden keys (e.g. secrets) are intentionally omitted.
    public static let groups: [(group: SettingGroup, keys: [any AnySettingKey.Type])] = [
        (
            .branding,
            [
                AppName.self, PrimaryColor.self, ShowLogoAndName.self, SvgColorMode.self,
                CustomLogoUpdatedAt.self, CustomLogoMimeType.self,
                CustomIconUpdatedAt.self, CustomIconMimeType.self,
            ]
        ),
        (.documentEditing, [DocumentServerURL.self, OfficeProvider.self, WopiPublicURL.self]),
        (.access, [RegistrationEnabled.self]),
        (.storage, [TrashRetentionDays.self]),
        (
            .sso,
            [
                LdapEnabled.self, LdapHost.self, LdapPort.self, LdapUseSSL.self, LdapBaseDN.self,
                LdapBindDN.self, LdapUserFilter.self, LdapGroupBaseDN.self, LdapGroupFilter.self,
                LdapTrustEmail.self, LdapUuidAttribute.self,
                OidcEnabled.self, OidcProviderKey.self, OidcDisplayName.self, OidcIssuerURL.self,
                OidcClientID.self, OidcScopes.self, OidcGroupsClaim.self,
                TrustedHeaderEnabled.self, TrustedEmailHeader.self, TrustedNameHeader.self,
                TrustedGroupsHeader.self, TrustedRoleHeader.self,
                SsoGroupImport.self, SsoGroupAutoMatch.self, SsoGroupPrefix.self, SsoGroupMap.self,
                SsoUserSync.self, SsoAutoProvision.self,
            ]
        ),
        (
            .ai,
            [
                AiEnabled.self, AiApiUrl.self, AiApiKey.self, AiModel.self,
                AiMaxToolIterations.self, RateLimitAi.self,
                EmbeddingEnabled.self, EmbeddingUrl.self, EmbeddingApiKey.self, EmbeddingModel.self,
                SemanticSearchThreshold.self,
            ]
        ),
    ]

    /// Flat list of all registered setting key types, derived from `groups`.
    public static let all: [any AnySettingKey.Type] = groups.flatMap(\.keys)

    /// Find registered setting key type by key string.
    public static func find(_ key: String) -> (any AnySettingKey.Type)? {
        all.first { $0.key == key }
    }

    /// Keys belonging to the SSO group - used to trigger a provider-registry reload after edits.
    public static let ssoKeys: Set<String> = Set(
        (groups.first { $0.group == .sso }?.keys ?? []).map { $0.key })
}
