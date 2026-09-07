import Vapor

/// Configuration for a single OIDC identity provider. Loaded from environment.
struct OIDCProviderConfig: Sendable {
    let enabled: Bool
    /// Stable provider id, e.g. `"oidc:main"`. The `:provider` route segment is the part after `oidc:`.
    let id: String
    /// Human-readable label for the login button.
    let displayName: String
    /// Issuer base URL; discovery is read from `{issuer}/.well-known/openid-configuration`.
    let issuer: String
    let clientID: String
    let clientSecret: String
    let scopes: String
    /// Exact redirect URI registered with the provider; must point at our callback route.
    let redirectURI: String
    /// Claim name that carries the user's groups/roles (mapped to local groups later).
    let groupsClaim: String
}
