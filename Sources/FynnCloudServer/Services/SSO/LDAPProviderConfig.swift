import Vapor

/// Configuration for the LDAP identity provider. Loaded from environment.
/// Password verification is performed by binding as the user's own DN, so no
/// long-lived service connection is kept open (unlike the previous implementation).
struct LDAPProviderConfig: Sendable {
    let enabled: Bool
    let host: String
    let port: UInt16?
    let useSSL: Bool
    let baseDN: String
    /// Optional service account used only to resolve `username -> DN`. If `nil`, an anonymous search is attempted.
    let bindDN: String?
    let bindPassword: String?
    /// Search filter template; `{username}` is replaced with the (escaped) login name. e.g. `(uid={username})`.
    let userFilter: String
    /// Optional base DN for group searches (defaults to `baseDN`). Used only in group-query mode.
    let groupBaseDN: String?
    /// Optional group search filter enabling Nextcloud-style group discovery instead of reading the
    /// user's `memberOf`. Placeholders: `{userDN}`, `{username}`. e.g. `(&(objectClass=groupOfNames)(member={userDN}))`.
    let groupFilter: String?
    /// Whether directory-provided emails are treated as verified (enables email-based account linking).
    /// Directories are org-controlled, so this defaults to `true`.
    let treatEmailAsVerified: Bool
    /// Attribute used as the stable, immutable subject id for identity linking. `"auto"` tries the
    /// common per-directory ids (OpenLDAP `entryUUID`, 389DS `nsuniqueid`, FreeIPA `ipaUniqueID`,
    /// AD `objectGUID`) in order. Set explicitly (e.g. `objectGUID`) to pin one.
    let uuidAttribute: String
}
