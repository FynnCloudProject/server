import Crypto
import Foundation
import Vapor

/// A verified identity returned by an external SSO source (LDAP entry or OIDC subject).
/// Providers normalize their raw attributes/claims into this shape; everything downstream
/// (`SSOService`, provisioning, group mapping) only ever sees this type.
struct ExternalIdentity: Sendable {
    /// Stable provider key, e.g. `"ldap"` or `"oidc:main"`. Stored on `UserIdentity.provider`.
    let provider: String
    /// Stable, immutable unique id for the subject within the provider
    /// (LDAP `entryUUID`, OIDC `sub`). Stored on `UserIdentity.subject`.
    let subject: String
    let username: String
    let email: String?
    /// Whether the provider asserts the email is verified. Email-based account linking
    /// is only performed when this is `true` (guards against account takeover).
    let emailVerified: Bool
    let displayName: String?
    /// Raw provider group names / role claims, mapped to local `Group`s later.
    let groups: [String]

    init(
        provider: String,
        subject: String,
        username: String,
        email: String? = nil,
        emailVerified: Bool = false,
        displayName: String? = nil,
        groups: [String] = []
    ) {
        self.provider = provider
        self.subject = subject
        self.username = username
        self.email = email
        self.emailVerified = emailVerified
        self.displayName = displayName
        self.groups = groups
    }
}

enum ProviderKind: Sendable {
    /// Verifies a username + password directly (LDAP): behaves like local login.
    case credentials
    /// Browser redirect + callback flow (OIDC).
    case redirect
}

/// Common surface for any external identity source.
protocol IdentityProvider: Sendable {
    /// Stable key persisted on `UserIdentity.provider` (e.g. `"ldap"`, `"oidc:main"`).
    var id: String { get }
    var kind: ProviderKind { get }
    /// Human-readable label for the login UI.
    var displayName: String { get }
}

/// An identity source that authenticates a username/password pair directly (LDAP).
protocol CredentialsIdentityProvider: IdentityProvider {
    func authenticate(username: String, password: String, on req: Request) async throws
        -> ExternalIdentity
}

extension CredentialsIdentityProvider {
    var kind: ProviderKind { .credentials }
}

/// PKCE material for an OIDC authorization-code flow.
struct PKCE: Sendable {
    let verifier: String
    let challenge: String

    /// Generates a fresh PKCE pair (S256): a high-entropy verifier and its SHA-256 challenge.
    static func generate() -> PKCE {
        let verifier = SSOToken.random(byteCount: 32)
        let challenge = SHA256.hash(data: Data(verifier.utf8)).base64URLEncoded()
        return PKCE(verifier: verifier, challenge: challenge)
    }
}

/// Cryptographically-random, URL-safe tokens for `state`, `nonce`, and PKCE verifiers.
enum SSOToken {
    static func random(byteCount: Int = 32) -> String {
        [UInt8].random(count: byteCount).base64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// An identity source that uses a browser redirect + callback (OIDC).
protocol RedirectIdentityProvider: IdentityProvider {
    /// Build the provider authorization URL to redirect the browser to.
    func authorizationURL(state: String, nonce: String, pkce: PKCE, on req: Request) async throws
        -> String
    /// Exchange the returned authorization `code` for a verified identity.
    /// Implementations MUST validate the ID token signature, `iss`, `aud`, `exp` and `nonce`.
    func exchange(code: String, pkce: PKCE, expectedNonce: String, on req: Request) async throws
        -> ExternalIdentity
}

extension RedirectIdentityProvider {
    var kind: ProviderKind { .redirect }
}
