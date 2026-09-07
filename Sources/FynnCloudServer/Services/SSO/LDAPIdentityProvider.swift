import Foundation
import Vapor

/// Authenticates users against an LDAP directory (OpenLDAP, Active Directory, FreeIPA, 389ds)
/// by binding as the user's own DN.
///
/// Flow per login (all synchronous LDAP work is offloaded to the app thread pool):
///  1. Service bind (or anonymous), then search `baseDN` with the configured filter to resolve the user DN and attributes.
///  2. Bind on a fresh connection as that user DN with the supplied password - this verifies credentials.
///  3. Map directory attributes into an `ExternalIdentity`.
struct LDAPIdentityProvider: CredentialsIdentityProvider {
    let id: String
    let config: LDAPProviderConfig

    var displayName: String { "LDAP" }

    func authenticate(username: String, password: String, on req: Request) async throws
        -> ExternalIdentity
    {
        // Reject empty passwords: LDAP treats an empty-credential bind as an anonymous bind,
        // which succeeds and would otherwise bypass authentication.
        guard !password.isEmpty else {
            throw Abort(.unauthorized, reason: "Invalid credentials").localized(
                LocalizationKeys.Error.Auth.Credentials)
        }

        let config = self.config
        let providerID = self.id
        let filter = config.userFilter.replacingOccurrences(
            of: "{username}", with: LDAPClient.escapeFilterValue(username))
        let fallbackUsername = username

        return try await req.application.threadPool.runIfActive(eventLoop: req.eventLoop) {
            try Self.performAuthentication(
                config: config,
                providerID: providerID,
                filter: filter,
                password: password,
                fallbackUsername: fallbackUsername
            )
        }.get()
    }

    // MARK: - Blocking LDAP work (runs off the event loop)

    private static func performAuthentication(
        config: LDAPProviderConfig,
        providerID: String,
        filter: String,
        password: String,
        fallbackUsername: String
    ) throws -> ExternalIdentity {
        // 1. Resolve user entry via service account search.
        let searchClient = try LDAPClient(config: config)
        defer { searchClient.close() }

        if let bindDN = config.bindDN, let bindPassword = config.bindPassword,
            !bindDN.isEmpty, !bindPassword.isEmpty
        {
            try searchClient.bind(dn: bindDN, password: bindPassword)
        } else {
            try searchClient.bind(dn: nil, password: nil)
        }

        let results = try searchClient.search(
            baseDN: config.baseDN,
            scope: .subtree,
            filter: filter
        )

        guard results.count == 1, let entry = results.first else {
            // Zero matches (unknown user) or multiple matches (ambiguous) -> treat as invalid.
            throw Abort(.unauthorized, reason: "Invalid credentials")
        }

        // 2. Verify the password by binding as the user on a fresh connection.
        let userClient = try LDAPClient(config: config)
        defer { userClient.close() }

        do {
            try userClient.bind(dn: entry.dn, password: password)
        } catch {
            throw Abort(.unauthorized, reason: "Invalid credentials")
        }

        // 3. Map attributes into an ExternalIdentity.
        return try makeIdentity(
            from: entry,
            providerID: providerID,
            config: config,
            client: searchClient,
            fallbackUsername: fallbackUsername
        )
    }

    // MARK: - Proactive enumeration (pre-sync)

    /// Enumerates all user entries for proactive pre-sync. Unlike login, this never binds as each
    /// user (no password available); it only reads directory attributes via the service account.
    static func enumerateIdentities(config: LDAPProviderConfig, providerID: String) throws
        -> [ExternalIdentity]
    {
        let client = try LDAPClient(config: config)
        defer { client.close() }

        if let bindDN = config.bindDN, let bindPassword = config.bindPassword,
            !bindDN.isEmpty, !bindPassword.isEmpty
        {
            try client.bind(dn: bindDN, password: bindPassword)
        } else {
            try client.bind(dn: nil, password: nil)
        }

        // Reuse the configured user filter, matching every user by expanding `{username}` to `*`.
        let filter = config.userFilter.replacingOccurrences(of: "{username}", with: "*")
        let results = try client.search(
            baseDN: config.baseDN,
            scope: .subtree,
            filter: filter
        )

        var identities: [ExternalIdentity] = []
        identities.reserveCapacity(results.count)
        for entry in results {
            let identity = try makeIdentity(
                from: entry,
                providerID: providerID,
                config: config,
                client: client,
                fallbackUsername: entry.resolveUsername()
            )
            identities.append(identity)
        }
        return identities
    }

    /// Maps a directory entry into a normalized `ExternalIdentity` (shared by login and enumeration).
    static func makeIdentity(
        from entry: LDAPEntry,
        providerID: String,
        config: LDAPProviderConfig,
        client: LDAPClient,
        fallbackUsername: String
    ) throws -> ExternalIdentity {
        let subject = entry.resolveSubject(config: config)
        let email = entry.resolveEmail()
        let username = entry.resolveUsername(fallback: fallbackUsername)
        let displayName = entry.resolveDisplayName(fallbackUsername: username)
        let groups = try resolveGroups(
            for: entry,
            username: username,
            config: config,
            client: client
        )

        return ExternalIdentity(
            provider: providerID,
            subject: subject,
            username: username,
            email: email,
            emailVerified: config.treatEmailAsVerified && email != nil,
            displayName: displayName,
            groups: groups
        )
    }

    /// Resolves the user's group names. In query mode (a `groupFilter` is set) it searches the group
    /// base with the admin-supplied filter; otherwise it reads the user's `memberOf`. Both yield the
    /// clean RDN value (e.g. `cn=admins,ou=groups,...` -> `admins`) for consistent mapping/import.
    private static func resolveGroups(
        for entry: LDAPEntry,
        username: String,
        config: LDAPProviderConfig,
        client: LDAPClient
    ) throws -> [String] {
        if let groupFilter = config.groupFilter, !groupFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let base = config.groupBaseDN ?? config.baseDN
            let filled = groupFilter
                .replacingOccurrences(
                    of: "{userDN}", with: LDAPClient.escapeFilterValue(entry.dn))
                .replacingOccurrences(
                    of: "{username}", with: LDAPClient.escapeFilterValue(username))
            let results = try client.search(
                baseDN: base,
                scope: .subtree,
                filter: filled
            )
            return results.compactMap { LDAPClient.groupName(fromDN: $0.dn) }
        }
        return entry.directGroupDNs().compactMap { LDAPClient.groupName(fromDN: $0) }
    }

    /// Extracts the leftmost RDN attribute value from a DN, e.g. `cn=admins,ou=g,dc=x` -> `admins`.
    static func groupName(fromDN dn: String) -> String? {
        LDAPClient.groupName(fromDN: dn)
    }

    /// Escapes RFC 4515 filter metacharacters to prevent LDAP filter injection.
    static func escapeFilterValue(_ value: String) -> String {
        LDAPClient.escapeFilterValue(value)
    }
}
