import Vapor

struct TrustedHeaderConfig: Sendable {
    let enabled: Bool
    let emailHeader: String?
    let nameHeader: String?
    let groupsHeader: String?
    let roleHeader: String?
    let secret: String?
}

/// The effective SSO configuration, resolved from settings (ENV > DB > default) plus ENV-only secrets.
/// Rebuilt at boot and whenever an SSO setting changes, so admin edits take effect without a restart.
struct SSOConfig: Sendable {
    let ldap: LDAPProviderConfig
    let oidc: OIDCProviderConfig
    let trustedHeader: TrustedHeaderConfig
    let groupMap: [String: String]
    let groupImport: Bool
    let groupAutoMatch: Bool
    let groupPrefix: String
    let userSync: Bool
    let autoProvision: Bool

    static let disabled = SSOConfig(
        ldap: LDAPProviderConfig(
            enabled: false, host: "localhost", port: nil, useSSL: false, baseDN: "",
            bindDN: nil, bindPassword: nil, userFilter: "(uid={username})",
            groupBaseDN: nil, groupFilter: nil, treatEmailAsVerified: true, uuidAttribute: "auto"),
        oidc: OIDCProviderConfig(
            enabled: false, id: "oidc:main", displayName: "Single Sign-On", issuer: "",
            clientID: "", clientSecret: "", scopes: "openid email profile", redirectURI: "",
            groupsClaim: "groups"),
        trustedHeader: TrustedHeaderConfig(
            enabled: false, emailHeader: nil, nameHeader: nil, groupsHeader: nil,
            roleHeader: nil, secret: nil),
        groupMap: [:], groupImport: false, groupAutoMatch: false, groupPrefix: "", userSync: false,
        autoProvision: true)

    static func resolve(settings: SettingsService, frontendURL: String) async throws -> SSOConfig {
        func str(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        func envSecret(_ keys: String...) -> String? {
            for key in keys {
                if let value = Environment.get(key)?.trimmingCharacters(
                    in: .whitespacesAndNewlines),
                    !value.isEmpty
                {
                    return value
                }
            }
            return nil
        }

        let ldap = LDAPProviderConfig(
            enabled: try await settings.get(AppSettings.LdapEnabled.self),
            host: try await settings.get(AppSettings.LdapHost.self),
            port: str(try await settings.get(AppSettings.LdapPort.self)).flatMap(UInt16.init),
            useSSL: try await settings.get(AppSettings.LdapUseSSL.self),
            baseDN: try await settings.get(AppSettings.LdapBaseDN.self),
            bindDN: str(try await settings.get(AppSettings.LdapBindDN.self)),
            bindPassword: envSecret("LDAP_BIND_PASSWORD", "LDAP_PASSWORD"),
            userFilter: try await settings.get(AppSettings.LdapUserFilter.self),
            groupBaseDN: str(try await settings.get(AppSettings.LdapGroupBaseDN.self)),
            groupFilter: str(try await settings.get(AppSettings.LdapGroupFilter.self)),
            treatEmailAsVerified: try await settings.get(AppSettings.LdapTrustEmail.self),
            uuidAttribute: try await settings.get(AppSettings.LdapUuidAttribute.self)
        )

        let providerKey = try await settings.get(AppSettings.OidcProviderKey.self)
        let issuer = try await settings.get(AppSettings.OidcIssuerURL.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Callback is always derived from FRONTEND_URL + provider key (matches the registered route).
        let effectiveRedirect = "\(frontendURL)/api/auth/oidc/\(providerKey)/callback"

        let oidc = OIDCProviderConfig(
            enabled: try await settings.get(AppSettings.OidcEnabled.self),
            id: "oidc:\(providerKey)",
            displayName: try await settings.get(AppSettings.OidcDisplayName.self),
            issuer: issuer.hasSuffix("/") ? String(issuer.dropLast()) : issuer,
            clientID: try await settings.get(AppSettings.OidcClientID.self),
            clientSecret: envSecret("OIDC_CLIENT_SECRET") ?? "",
            scopes: try await settings.get(AppSettings.OidcScopes.self),
            redirectURI: effectiveRedirect,
            groupsClaim: try await settings.get(AppSettings.OidcGroupsClaim.self)
        )

        let trustedHeader = TrustedHeaderConfig(
            enabled: try await settings.get(AppSettings.TrustedHeaderEnabled.self),
            emailHeader: str(try await settings.get(AppSettings.TrustedEmailHeader.self)),
            nameHeader: str(try await settings.get(AppSettings.TrustedNameHeader.self)),
            groupsHeader: str(try await settings.get(AppSettings.TrustedGroupsHeader.self)),
            roleHeader: str(try await settings.get(AppSettings.TrustedRoleHeader.self)),
            secret: envSecret("TRUSTED_HEADER_SECRET", "AUTH_TRUSTED_HEADER_SECRET")
        )

        return SSOConfig(
            ldap: ldap,
            oidc: oidc,
            trustedHeader: trustedHeader,
            groupMap: parseGroupMap(
                try await settings.get(AppSettings.SsoGroupMap.self)),
            groupImport: try await settings.get(AppSettings.SsoGroupImport.self),
            groupAutoMatch: try await settings.get(AppSettings.SsoGroupAutoMatch.self),
            groupPrefix: try await settings.get(AppSettings.SsoGroupPrefix.self),
            userSync: try await settings.get(AppSettings.SsoUserSync.self),
            autoProvision: try await settings.get(AppSettings.SsoAutoProvision.self)
        )
    }

    /// Parses `SSO_GROUP_MAP` (`external->localKey` pairs, `;`/newline separated) into a lookup.
    /// `->` is the separator because LDAP DNs contain `=`.
    static func parseGroupMap(_ raw: String?) -> [String: String] {
        guard let raw, !raw.isEmpty else { return [:] }
        var map: [String: String] = [:]
        for entry in raw.split(whereSeparator: { $0 == ";" || $0 == "\n" }) {
            let parts = entry.components(separatedBy: "->")
            guard parts.count == 2 else { continue }
            let external = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let local = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !external.isEmpty && !local.isEmpty { map[external] = local }
        }
        return map
    }
}

/// Rebuilds `app.ssoConfig` and the provider registry from current settings.
func reloadSSOProviders(_ app: Application) async {
    do {
        let config = try await SSOConfig.resolve(
            settings: app.settings, frontendURL: app.config.frontendURL)
        app.ssoConfig = config

        var providers: [any IdentityProvider] = []
        if config.ldap.enabled {
            providers.append(LDAPIdentityProvider(id: "ldap", config: config.ldap))
        }
        if config.oidc.enabled {
            providers.append(OIDCIdentityProvider(id: config.oidc.id, config: config.oidc))
        }
        app.ssoProviders = SSOProviderRegistry(providers)
        app.logger(subsystem: .sso).info(
            "SSO providers reloaded",
            metadata: [
                "ldap": .stringConvertible(config.ldap.enabled),
                "oidc": .stringConvertible(config.oidc.enabled),
                "trustedHeader": .stringConvertible(config.trustedHeader.enabled),
            ]
        )
    } catch {
        app.logger(subsystem: .sso).error(
            "Failed to reload SSO providers",
            metadata: ["error": .string("\(error)")]
        )
    }
}

extension Application {
    private struct SSOConfigKey: StorageKey { typealias Value = SSOConfig }

    var ssoConfig: SSOConfig {
        get { storage[SSOConfigKey.self] ?? .disabled }
        set { storage[SSOConfigKey.self] = newValue }
    }
}

extension Request {
    var ssoConfig: SSOConfig { application.ssoConfig }
}
